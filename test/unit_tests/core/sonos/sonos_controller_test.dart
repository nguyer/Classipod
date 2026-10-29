import 'package:classipod/core/services/audio_player_service.dart';
import 'package:classipod/core/services/playback/library_audio_handler.dart';
import 'package:classipod/core/services/playback/remote_audio_output.dart';
import 'package:classipod/core/sonos/sonos_client.dart';
import 'package:classipod/core/sonos/sonos_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class Native extends SonosNative {
  bool denied = false;
  final multicastCalls = <bool>[];
  @override
  Future<void> permission() async {
    if (denied) throw const SonosException('permission');
  }

  @override
  Future<void> multicast(bool enabled) async {
    multicastCalls.add(enabled);
  }
}

class Handler extends Fake implements LibraryAudioHandler {
  RemoteAudioOutput? output;
  @override
  Future<void> useRemoteOutput(RemoteAudioOutput? value) async {
    output = value;
  }
}

class Client extends SonosClient {
  final calls = <String>[];
  final roomsList = [
    for (final id in ['Kitchen', 'TV'])
      SonosRoom(
        id: id,
        name: id,
        location: Uri.parse(
          'http://192.168.1.2:1400/xml/device_description.xml',
        ),
        coordinatorId: 'TV',
      ),
  ];
  @override
  Future<SonosRoom> describe(Uri location) async => roomsList.first;
  @override
  Future<List<SonosRoom>> rooms(SonosRoom seed) async => roomsList;
  @override
  Future<Map<String, String>> action(
    SonosRoom room,
    String service,
    String command, [
    Map<String, Object> args = const {},
  ]) async => {'CurrentVolume': '15'};
  @override
  Future<void> join(SonosRoom room, SonosRoom coordinator) async {
    calls.add('${room.id}->${coordinator.id}');
  }

  @override
  Future<void> ungroup(SonosRoom room) async {
    calls.add('ungroup:${room.id}');
  }
}

void main() {
  late ProviderContainer container;
  late Native native;
  late Client client;
  late Handler handler;
  late SonosController controller;
  setUp(() {
    native = Native();
    client = Client();
    handler = Handler();
    container = ProviderContainer(
      overrides: [
        sonosNativeProvider.overrideWithValue(native),
        sonosClientProvider.overrideWithValue(client),
        sonosDiscoveryProvider.overrideWithValue(
          () async => [client.roomsList.first.location],
        ),
        libraryAudioHandlerProvider.overrideWithValue(handler),
      ],
    );
    controller = container.read(sonosControllerProvider.notifier);
  });
  tearDown(() {
    container.dispose();
    client.close();
  });
  test('discovery reads topology and always releases multicast lock', () async {
    await controller.discover();
    final state = container.read(sonosControllerProvider);
    expect(state.rooms.map((r) => r.id), ['Kitchen', 'TV']);
    expect(state.scanning, isFalse);
    expect(native.multicastCalls, [true, false]);
  });
  test('denied permission is reported before attempting discovery', () async {
    native.denied = true;
    await controller.discover();
    expect(container.read(sonosControllerProvider).error, 'permission');
    expect(native.multicastCalls, [false]);
  });
  test(
    'selecting a grouped room resolves its coordinator and can return to phone',
    () async {
      await controller.selectRoom(client.roomsList.first);
      expect(container.read(sonosControllerProvider).selectedId, 'Kitchen');
      expect(container.read(sonosControllerProvider).coordinator!.id, 'TV');
      expect(handler.output, isNotNull);
      await controller.ungroup(client.roomsList.first);
      expect(client.calls, ['ungroup:Kitchen']);
      await controller.selectRoom(null);
      expect(handler.output, isNull);
      expect(container.read(sonosControllerProvider).selectedId, isNull);
    },
  );
  test(
    'manual address validation rejects URLs and loopback endpoints',
    () async {
      for (final value in ['https://example.com', '127.0.0.1', 'not-an-ip']) {
        await controller.addAddress(value);
        expect(container.read(sonosControllerProvider).error, 'address');
      }
      await controller.addAddress('192.168.1.2');
      expect(container.read(sonosControllerProvider).rooms, hasLength(2));
    },
  );
}
