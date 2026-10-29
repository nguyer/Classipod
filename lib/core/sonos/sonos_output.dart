import 'dart:async';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/services/playback/remote_audio_output.dart';
import 'package:classipod/core/sonos/sonos_client.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:xml/xml.dart';

String sonosMetadata(MusicMetadata song, Uri uri) {
  final xml = XmlBuilder();
  xml.element(
    'DIDL-Lite',
    namespaceUris: {
      '': 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/',
      'dc': 'http://purl.org/dc/elements/1.1/',
      'upnp': 'urn:schemas-upnp-org:metadata-1-0/upnp/',
    },
    nest: () {
      xml.element(
        'item',
        attributes: {
          'id': song.identity,
          'parentID': '0',
          'restricted': 'true',
        },
        nest: () {
          xml.element('dc:title', nest: song.getTrackName);
          xml.element('dc:creator', nest: song.getTrackArtistNames);
          xml.element('upnp:artist', nest: song.getTrackArtistNames);
          xml.element('upnp:album', nest: song.albumName ?? '');
          xml.element('upnp:class', nest: 'object.item.audioItem.musicTrack');
          xml.element(
            'res',
            attributes: {'protocolInfo': 'http-get:*:audio/mpeg:*'},
            nest: uri.toString(),
          );
        },
      );
    },
  );
  return xml.buildDocument().toXmlString();
}

Duration sonosDuration(String? value) {
  final parts = value?.split(':');
  if (parts == null || parts.length != 3) return Duration.zero;
  return Duration(
    hours: int.tryParse(parts[0]) ?? 0,
    minutes: int.tryParse(parts[1]) ?? 0,
    seconds: double.tryParse(parts[2])?.floor() ?? 0,
  );
}

String sonosTime(Duration position) => [
  position.inHours,
  position.inMinutes % 60,
  position.inSeconds % 60,
].map((part) => part.toString().padLeft(2, '0')).join(':');

/// Sonos owns the complete queue, so playback can continue without the phone.
class SonosOutput implements RemoteAudioOutput {
  SonosOutput(
    this.client,
    this.room,
    this.coordinator, {
    required this.resolve,
    this.refreshTopology,
    Duration pollInterval = const Duration(seconds: 2),
  }) {
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }
  final SonosClient client;
  final Future<Uri> Function(MusicMetadata) resolve;
  final Future<void> Function()? refreshTopology;
  SonosRoom room;
  SonosRoom coordinator;
  final _events = StreamController<RemotePlaybackState>.broadcast();
  Timer? _timer;
  bool _closed = false;
  bool _dirty = true;
  bool _ownsQueue = false;
  bool _busy = false;
  Future<void>? _refreshing;
  Future<void> _pending = Future.value();
  List<MusicMetadata> _songs = [];
  List<int> _order = [];
  final Map<int, Uri> _uris = {};
  LoopMode _repeat = LoopMode.off;
  int _generation = 0;
  @override
  RemotePlaybackState current = const RemotePlaybackState();
  @override
  Stream<RemotePlaybackState> get changes => _events.stream;

  void _emit({
    int? index,
    Duration? position,
    bool? playing,
    bool loading = false,
    double? volume,
    String? error,
  }) {
    if (_closed) return;
    current = RemotePlaybackState(
      index: index ?? current.index,
      position: position ?? current.position,
      playing: playing ?? current.playing,
      loading: loading,
      volume: volume ?? current.volume,
      error: error,
    );
    _events.add(current);
  }

  void updateRooms(SonosRoom selected, SonosRoom target) {
    if (target.id != coordinator.id) {
      _generation++;
      _dirty = true;
      _ownsQueue = false;
      _emit(playing: false, error: 'queueChanged');
    }
    room = selected;
    coordinator = target;
  }

  @override
  void configure(List<MusicMetadata> songs, List<int> order, int index) {
    final remoteOrder = order.where((i) => songs[i].isSubsonic).toList();
    if (!listEquals(
          _songs.map((s) => s.identity).toList(),
          songs.map((s) => s.identity).toList(),
        ) ||
        !listEquals(_order, remoteOrder)) {
      _dirty = true;
      _ownsQueue = false;
      _songs = List.unmodifiable(songs);
      _order = remoteOrder;
    }
    _emit(index: index, position: Duration.zero, playing: false);
  }

  Future<void> _command(
    String action, [
    Map<String, Object> values = const {},
  ]) async {
    await client.action(coordinator, SonosClient.av, action, {
      'InstanceID': 0,
      ...values,
    });
  }

  Future<void> _run(Future<void> Function() operation) {
    final result = _pending.then((_) async {
      if (_closed) throw const SonosException('disconnected');
      _busy = true;
      _emit(loading: true);
      try {
        await operation();
        _emit();
      } catch (error) {
        _emit(
          playing: false,
          error: error is SonosException ? error.code : 'connection',
        );
        rethrow;
      } finally {
        _busy = false;
      }
    });
    _pending = result.catchError((Object _) {});
    return result;
  }

  Future<void> _prepareQueue(int index) async {
    if (index < 0 || index >= _songs.length || !_songs[index].isSubsonic) {
      throw const SonosException('serverTracksOnly');
    }
    if (!_dirty && _ownsQueue) {
      final position = await client.action(
        coordinator,
        SonosClient.av,
        'GetPositionInfo',
        {'InstanceID': 0},
      );
      final track = (int.tryParse(position['Track'] ?? '') ?? 0) - 1;
      if (track >= 0 &&
          track < _order.length &&
          position['TrackURI'] == _uris[_order[track]]?.toString()) {
        return;
      }
      _dirty = true;
      _ownsQueue = false;
    }
    final generation = _generation;
    void check() {
      if (_closed || generation != _generation) {
        throw const SonosException('cancelled');
      }
    }

    // Resolve every entry before changing the speaker, including sign-in failures.
    final uris = <int, Uri>{};
    for (final item in _order) {
      final uri = await resolve(_songs[item]);
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.host == 'localhost' ||
          uri.host == '127.0.0.1' ||
          uri.host == '::1') {
        throw const SonosException('serverAddress');
      }
      uris[item] = uri;
      check();
    }
    try {
      await _command('Stop');
    } on SonosException catch (error) {
      // Idle/TV sources can reject Stop while still accepting a new queue.
      if (error.code != 'upnp:701') rethrow;
    }
    check();
    await _command('RemoveAllTracksFromQueue');
    check();
    for (var offset = 0; offset < _order.length; offset += 16) {
      final chunk = _order.skip(offset).take(16).toList();
      await _command('AddMultipleURIsToQueue', {
        'UpdateID': 0,
        'NumberOfURIs': chunk.length,
        'EnqueuedURIs': chunk.map((i) => uris[i].toString()).join(' '),
        'EnqueuedURIsMetaData': chunk
            .map((i) => sonosMetadata(_songs[i], uris[i]!))
            .join(' '),
        'ContainerURI': '',
        'ContainerMetaData': '',
        'DesiredFirstTrackNumberEnqueued': 0,
        'EnqueueAsNext': 0,
      });
      check();
    }
    await _command('SetAVTransportURI', {
      'CurrentURI': 'x-rincon-queue:${coordinator.id}#0',
      'CurrentURIMetaData': '',
    });
    check();
    await _applyRepeat();
    _uris
      ..clear()
      ..addAll(uris);
    _ownsQueue = true;
    _dirty = false;
  }

  @override
  Future<void> select(int index, {bool play = true}) => _run(() async {
    await _prepareQueue(index);
    await _command('Seek', {
      'Unit': 'TRACK_NR',
      'Target': _order.indexOf(index) + 1,
    });
    if (play) await _command('Play', {'Speed': 1});
    _emit(index: index, position: Duration.zero, playing: play);
  });
  @override
  Future<void> play() => _run(() async {
    final dirty = _dirty || !_ownsQueue;
    await _prepareQueue(current.index);
    if (dirty) {
      await _command('Seek', {
        'Unit': 'TRACK_NR',
        'Target': _order.indexOf(current.index) + 1,
      });
      if (current.position > Duration.zero) {
        await _command('Seek', {
          'Unit': 'REL_TIME',
          'Target': sonosTime(current.position),
        });
      }
    }
    await _command('Play', {'Speed': 1});
    _emit(playing: true);
  });
  @override
  Future<void> pause() => _run(() async {
    if (_ownsQueue) await _command('Pause');
    _emit(playing: false);
  });
  @override
  Future<void> stop() => _run(() async {
    if (_ownsQueue) await _command('Stop');
    _emit(playing: false, position: Duration.zero);
  });
  @override
  Future<void> seek(Duration position) => _run(() async {
    final target = position < Duration.zero ? Duration.zero : position;
    if (_ownsQueue) {
      await _command('Seek', {'Unit': 'REL_TIME', 'Target': sonosTime(target)});
    }
    _emit(position: target);
  });

  @override
  Future<void> setOrder(List<int> order) => _run(() async {
    final next = order.where((i) => _songs[i].isSubsonic).toList();
    if (listEquals(next, _order)) return;
    final owned = _ownsQueue;
    final playing = current.playing;
    final position = current.position;
    _order = next;
    _dirty = true;
    if (owned) {
      await _prepareQueue(current.index);
      await _command('Seek', {
        'Unit': 'TRACK_NR',
        'Target': _order.indexOf(current.index) + 1,
      });
      await _command('Seek', {
        'Unit': 'REL_TIME',
        'Target': sonosTime(position),
      });
      if (playing) await _command('Play', {'Speed': 1});
      _emit(position: position, playing: playing);
    }
  });
  Future<void> _applyRepeat() => _command('SetPlayMode', {
    'NewPlayMode': switch (_repeat) {
      LoopMode.off => 'NORMAL',
      LoopMode.one => 'REPEAT_ONE',
      LoopMode.all => 'REPEAT_ALL',
    },
  });
  @override
  Future<void> setRepeat(LoopMode mode) => _run(() async {
    _repeat = mode;
    if (_ownsQueue) await _applyRepeat();
  });
  @override
  Future<void> setVolume(double volume) async {
    final target = (volume.clamp(0, 1) * 100).round();
    await client.action(room, SonosClient.rendering, 'SetVolume', {
      'InstanceID': 0,
      'Channel': 'Master',
      'DesiredVolume': target,
    });
    _emit(volume: target / 100);
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (_closed || _busy) return;
    final generation = _generation;
    try {
      await refreshTopology?.call();
      if (_closed || _busy || generation != _generation) return;
      final volume = await client.action(
        room,
        SonosClient.rendering,
        'GetVolume',
        {'InstanceID': 0, 'Channel': 'Master'},
      );
      if (_closed || _busy || generation != _generation) return;
      _emit(
        volume:
            (int.tryParse(volume['CurrentVolume'] ?? '') ?? 0).clamp(0, 100) /
            100,
      );
      if (!_ownsQueue) return;
      final transport = await client.action(
        coordinator,
        SonosClient.av,
        'GetTransportInfo',
        {'InstanceID': 0},
      );
      final position = await client.action(
        coordinator,
        SonosClient.av,
        'GetPositionInfo',
        {'InstanceID': 0},
      );
      if (_closed || _busy || generation != _generation) return;
      if (transport['CurrentTransportState'] == 'TRANSITIONING') {
        _emit(loading: true);
        return;
      }
      final track = (int.tryParse(position['Track'] ?? '') ?? 0) - 1;
      if (track < 0 ||
          track >= _order.length ||
          position['TrackURI'] != _uris[_order[track]]?.toString()) {
        _ownsQueue = false;
        _dirty = true;
        _emit(playing: false, error: 'queueChanged');
        return;
      }
      final status = transport['CurrentTransportState'];
      _emit(
        index: _order[track],
        position: sonosDuration(position['RelTime']),
        playing: status == 'PLAYING',
        loading: status == 'TRANSITIONING',
      );
    } catch (_) {
      if (!_closed && !_busy && generation == _generation) {
        _emit(playing: false, error: 'connection');
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _timer?.cancel();
    await _events.close();
  }
}
