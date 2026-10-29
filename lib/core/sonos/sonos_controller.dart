import 'dart:async';
import 'dart:io';

import 'package:classipod/core/services/audio_player_service.dart';
import 'package:classipod/core/sonos/sonos_client.dart';
import 'package:classipod/core/sonos/sonos_output.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final sonosClientProvider = Provider<SonosClient>((ref) {
  final client = SonosClient();
  ref.onDispose(client.close);
  return client;
});
final sonosDiscoveryProvider = Provider<Future<List<Uri>> Function()>(
  (_) => discoverSonos,
);

class SonosNative {
  static const _channel = MethodChannel('classipod/sonos');
  Future<void> permission() async {
    if (kIsWeb) throw const SonosException('unsupported');
    if (Platform.isAndroid &&
        await _channel.invokeMethod<bool>('requestLocalNetwork') != true) {
      throw const SonosException('permission');
    }
  }

  Future<void> multicast(bool enabled) async {
    if (!kIsWeb && Platform.isAndroid) {
      await _channel.invokeMethod<void>(
        enabled ? 'acquireMulticast' : 'releaseMulticast',
      );
    }
  }
}

final sonosNativeProvider = Provider<SonosNative>((_) => SonosNative());

class SonosState {
  const SonosState({
    this.rooms = const [],
    this.selectedId,
    this.scanning = false,
    this.busy = false,
    this.error,
    this.volume = 0,
  });
  final List<SonosRoom> rooms;
  final String? selectedId;
  final bool scanning;
  final bool busy;
  final String? error;
  final double volume;
  SonosRoom? get selected =>
      rooms.where((room) => room.id == selectedId).firstOrNull;
  SonosRoom? get coordinator =>
      rooms.where((room) => room.id == selected?.coordinatorId).firstOrNull;
  SonosState copyWith({
    List<SonosRoom>? rooms,
    String? selectedId,
    bool clearSelection = false,
    bool? scanning,
    bool? busy,
    String? error,
    bool clearError = false,
    double? volume,
  }) => SonosState(
    rooms: rooms ?? this.rooms,
    selectedId: clearSelection ? null : selectedId ?? this.selectedId,
    scanning: scanning ?? this.scanning,
    busy: busy ?? this.busy,
    error: clearError ? null : error ?? this.error,
    volume: volume ?? this.volume,
  );
}

final sonosControllerProvider = NotifierProvider<SonosController, SonosState>(
  SonosController.new,
);

class SonosController extends Notifier<SonosState> {
  SonosOutput? _output;
  StreamSubscription<dynamic>? _subscription;
  @override
  SonosState build() {
    ref.onDispose(() {
      unawaited(_subscription?.cancel());
      unawaited(_output?.close());
    });
    return const SonosState();
  }

  Future<void> discover() async {
    if (state.busy || state.scanning) return;
    state = state.copyWith(scanning: true, clearError: true);
    final native = ref.read(sonosNativeProvider);
    try {
      await native.permission();
      await native.multicast(true);
      final locations = await ref.read(sonosDiscoveryProvider)();
      final discovered = <String, SonosRoom>{};
      for (final location in locations) {
        try {
          final seed = await ref.read(sonosClientProvider).describe(location);
          final rooms = await ref.read(sonosClientProvider).rooms(seed);
          for (final room in rooms) {
            discovered[room.id] = room;
          }
        } catch (_) {
          // One unreachable speaker should not hide the other rooms.
        }
      }
      if (!ref.mounted) return;
      if (discovered.isNotEmpty) {
        _setRooms(discovered.values.toList());
      } else {
        state = state.copyWith(error: 'notFound');
      }
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: _error(error));
    } finally {
      try {
        await native.multicast(false);
      } catch (_) {
        // Permission/disposal failures must not leave an unhandled UI future.
      }
      if (ref.mounted) state = state.copyWith(scanning: false);
    }
  }

  Future<void> addAddress(String address) async {
    await _guard(() async {
      await ref.read(sonosNativeProvider).permission();
      final parsed = InternetAddress.tryParse(address.trim());
      if (parsed == null ||
          parsed.type != InternetAddressType.IPv4 ||
          parsed.isLoopback ||
          parsed.isMulticast) {
        throw const SonosException('address');
      }
      final client = ref.read(sonosClientProvider);
      final seed = await client.describe(
        Uri.parse('http://${parsed.address}:1400/xml/device_description.xml'),
      );
      _setRooms(await client.rooms(seed));
    });
  }

  void _setRooms(List<SonosRoom> rooms) {
    if (!ref.mounted) return;
    final sorted = rooms.toList()..sort((a, b) => a.name.compareTo(b.name));
    state = state.copyWith(rooms: sorted, clearError: true);
    if (_output != null &&
        state.selected != null &&
        state.coordinator != null) {
      _output!.updateRooms(state.selected!, state.coordinator!);
    }
  }

  Future<void> refreshGroups() async {
    final seed = state.selected ?? state.rooms.firstOrNull;
    if (seed != null) {
      _setRooms(await ref.read(sonosClientProvider).rooms(seed));
    }
  }

  Future<void> selectRoom(SonosRoom? room) => _guard(() async {
    final handler = ref.read(libraryAudioHandlerProvider);
    if (room == null) {
      await handler.useRemoteOutput(null);
      await _subscription?.cancel();
      await _output?.close();
      _output = null;
      state = state.copyWith(clearSelection: true, clearError: true);
      return;
    }
    await ref.read(sonosNativeProvider).permission();
    final rooms = await ref.read(sonosClientProvider).rooms(room);
    final currentRoom = rooms.where((item) => item.id == room.id).firstOrNull;
    final coordinator = rooms
        .where((item) => item.id == currentRoom?.coordinatorId)
        .firstOrNull;
    if (currentRoom == null || coordinator == null || !currentRoom.visible) {
      throw const SonosException('notFound');
    }
    final output = SonosOutput(
      ref.read(sonosClientProvider),
      currentRoom,
      coordinator,
      refreshTopology: refreshGroups,
      resolve: (song) async {
        final uri = await ref
            .read(subsonicControllerProvider.notifier)
            .resolveUri(song, allowLocal: false);
        return uri.replace(
          queryParameters: {
            ...uri.queryParameters,
            'format': 'mp3',
            'maxBitRate': '320',
          },
        );
      },
    );
    try {
      await handler.useRemoteOutput(output);
    } catch (_) {
      await output.close();
      rethrow;
    }
    await _subscription?.cancel();
    await _output?.close();
    _output = output;
    state = state.copyWith(
      rooms: rooms,
      selectedId: currentRoom.id,
      clearError: true,
    );
    _subscription = output.changes.listen((value) {
      if (ref.mounted) {
        state = state.copyWith(
          volume: value.volume,
          error: value.error,
          clearError: value.error == null,
        );
      }
    });
    await output.refresh();
  });

  Future<void> group(SonosRoom room) => _guard(() async {
    await refreshGroups();
    final target = state.coordinator;
    if (target == null) throw const SonosException('notFound');
    final source = state.rooms.firstWhere((item) => item.id == room.id);
    await ref.read(sonosClientProvider).join(source, target);
    await refreshGroups();
  });

  Future<void> ungroup(SonosRoom room) => _guard(() async {
    await ref.read(sonosClientProvider).ungroup(room);
    await refreshGroups();
  });

  Future<void> setVolume(double volume) => _guard(() async {
    await ref.read(libraryAudioHandlerProvider).setRemoteVolume(volume);
  });

  String _error(Object error) =>
      error is SonosException ? error.code : 'connection';
  Future<void> _guard(Future<void> Function() operation) async {
    if (state.busy || state.scanning) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await operation();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: _error(error));
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }
}
