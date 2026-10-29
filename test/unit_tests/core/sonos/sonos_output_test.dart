import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/sonos/sonos_client.dart';
import 'package:classipod/core/sonos/sonos_output.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:xml/xml.dart';

class FakeSonos extends SonosClient {
  final calls = <({String room, String action, Map<String, Object> args})>[];
  int track = 1;
  String uri = '';
  bool playing = false;
  bool transitioning = false;
  List<String> queueUris = [];
  String? fail;
  String failureCode = 'connection';
  @override
  Future<Map<String, String>> action(
    SonosRoom room,
    String service,
    String command, [
    Map<String, Object> args = const {},
  ]) async {
    calls.add((room: room.id, action: command, args: args));
    if (command == fail) throw SonosException(failureCode);
    if (command == 'RemoveAllTracksFromQueue') queueUris = [];
    if (command == 'AddMultipleURIsToQueue') {
      queueUris.addAll(args['EnqueuedURIs'].toString().split(' '));
    }
    if (command == 'Seek' && args['Unit'] == 'TRACK_NR') {
      track = args['Target'] as int;
      uri = queueUris[track - 1];
    }
    if (command == 'Play') playing = true;
    if (command == 'Pause') playing = false;
    return switch (command) {
      'GetVolume' => {'CurrentVolume': '25'},
      'GetTransportInfo' => {
        'CurrentTransportState': transitioning
            ? 'TRANSITIONING'
            : playing
            ? 'PLAYING'
            : 'PAUSED_PLAYBACK',
      },
      'GetPositionInfo' => {
        'Track': '$track',
        'RelTime': '00:01:23',
        'TrackURI': uri,
      },
      _ => {},
    };
  }
}

SonosRoom testRoom(String id) => SonosRoom(
  id: id,
  name: id,
  location: Uri.parse('http://192.168.1.2:1400/xml/device_description.xml'),
  coordinatorId: id,
);
MusicMetadata remoteSong(String id) => MusicMetadata(
  songId: 'subsonic:server:$id',
  serverId: 'server',
  remoteSongId: id,
  trackName: 'Song & <$id>',
  trackArtistNames: ['Artist'],
  trackDuration: 180000,
);
Uri remoteUri(MusicMetadata song) => Uri.https('music.test', '/stream', {
  'id': song.remoteSongId!,
  't': 'secret',
});

void main() {
  late FakeSonos client;
  late SonosOutput output;
  setUp(() {
    client = FakeSonos();
    output = SonosOutput(
      client,
      testRoom('member'),
      testRoom('coordinator'),
      resolve: (song) async => remoteUri(song),
      pollInterval: const Duration(days: 1),
    );
  });
  tearDown(() async {
    await output.close();
    client.close();
  });

  test('configuring an output leaves the existing speaker queue untouched', () {
    output.configure([remoteSong('a')], [0], 0);
    expect(client.calls, isEmpty);
  });

  test('queues batches of 16, keeps order, skips local files and selects requested track', () async {
    final songs = [
      MusicMetadata(filePath: '/phone.mp3'),
      for (var i = 0; i < 18; i++) remoteSong('$i'),
    ];
    output.configure(songs, List.generate(19, (i) => i), 17);
    await output.select(17);
    final batches = client.calls
        .where((c) => c.action == 'AddMultipleURIsToQueue')
        .toList();
    expect(batches.map((c) => c.args['NumberOfURIs']), [16, 2]);
    expect(
      batches.first.args['EnqueuedURIs'].toString(),
      isNot(contains('file:')),
    );
    expect(
      client.calls.where((c) => c.action == 'Seek').single.args['Target'],
      17,
    );
    expect(client.calls.every((c) => c.room == 'coordinator'), isTrue);
    expect(output.current.index, 17);
    expect(output.current.playing, isTrue);
  });

  test(
    'local tracks and invalid server URLs fail before modifying the speaker',
    () async {
      output.configure([MusicMetadata(filePath: '/phone.mp3')], [0], 0);
      await expectLater(output.play(), throwsA(isA<SonosException>()));
      expect(client.calls, isEmpty);
      expect(output.current.error, 'serverTracksOnly');
      final invalid = SonosOutput(
        client,
        testRoom('a'),
        testRoom('a'),
        resolve: (_) async => Uri.parse('file:///private/audio.mp3'),
        pollInterval: const Duration(days: 1),
      );
      addTearDown(invalid.close);
      invalid.configure([remoteSong('a')], [0], 0);
      await expectLater(invalid.play(), throwsA(isA<SonosException>()));
      expect(client.calls, isEmpty);
    },
  );

  test(
    'pause resume seek repeat use coordinator; volume uses selected room',
    () async {
      output.configure([remoteSong('a')], [0], 0);
      await output.play();
      await output.pause();
      await output.seek(const Duration(seconds: 65));
      await output.setRepeat(LoopMode.all);
      await output.setVolume(1.5);
      expect(client.calls.last.room, 'member');
      expect(client.calls.last.args['DesiredVolume'], 100);
      expect(
        client.calls.where((c) => c.action == 'Seek').last.args['Target'],
        '00:01:05',
      );
      expect(
        client.calls
            .where((c) => c.action == 'SetPlayMode')
            .last
            .args['NewPlayMode'],
        'REPEAT_ALL',
      );
      await output.play();
      expect(
        client.calls.where((c) => c.action == 'RemoveAllTracksFromQueue'),
        hasLength(1),
      );
    },
  );

  test(
    'poll maps autonomous queue changes and position back to Classipod indices',
    () async {
      final songs = [remoteSong('a'), remoteSong('b')];
      output.configure(songs, [1, 0], 1);
      await output.play();
      client.track = 2;
      client.uri = remoteUri(songs[0]).toString();
      await output.refresh();
      expect(output.current.index, 0);
      expect(output.current.position.inSeconds, 83);
      expect(output.current.volume, 0.25);
      expect(output.current.playing, isTrue);
      client.uri = 'http://some-other-source/track';
      await output.refresh();
      expect(output.current.error, 'queueChanged');
      expect(output.current.playing, isFalse);
    },
  );

  test(
    'queue failures remain retryable and never start partial playback',
    () async {
      output.configure([remoteSong('a')], [0], 0);
      client.fail = 'AddMultipleURIsToQueue';
      await expectLater(output.play(), throwsA(isA<SonosException>()));
      expect(client.calls.where((c) => c.action == 'Play'), isEmpty);
      expect(output.current.error, 'connection');
      client.fail = null;
      await output.play();
      expect(output.current.playing, isTrue);
      expect(output.current.error, isNull);
    },
  );

  test('shuffled orders rebuild the queue while preserving position and playing state', () async {
    output.configure([remoteSong('a'), remoteSong('b')], [0, 1], 0);
    await output.play();
    await output.seek(const Duration(seconds: 10));
    await output.setOrder([1, 0]);
    expect(output.current.index, 0);
    expect(output.current.position.inSeconds, 10);
    expect(output.current.playing, isTrue);
    expect(
      client.calls.where((c) => c.action == 'RemoveAllTracksFromQueue'),
      hasLength(2),
    );
  });

  test(
    'DIDL metadata survives XML escaping with title, artist and stream URI',
    () {
      final song = remoteSong('a');
      final document = XmlDocument.parse(sonosMetadata(song, remoteUri(song)));
      expect(xmlText(document, 'title'), 'Song & <a>');
      expect(xmlText(document, 'artist'), 'Artist');
      expect(xmlText(document, 'res'), remoteUri(song).toString());
    },
  );
  test('slow transitions do not invalidate the owned queue', () async {
    output.configure([remoteSong('a')], [0], 0);
    await output.play();
    client.transitioning = true;
    client.track = 0;
    client.uri = '';
    await output.refresh();
    expect(output.current.loading, isTrue);
    expect(output.current.error, isNull);
    client.transitioning = false;
    client.track = 1;
    client.uri = remoteUri(remoteSong('a')).toString();
    await output.refresh();
    expect(output.current.playing, isTrue);
    expect(output.current.loading, isFalse);
  });
  test('an idle source rejecting Stop can still accept a new queue', () async {
    output.configure([remoteSong('a')], [0], 0);
    client.fail = 'Stop';
    client.failureCode = 'upnp:701';
    await output.play();
    expect(output.current.playing, isTrue);
    expect(client.calls.where((c) => c.action == 'Play'), hasLength(1));
  });
}
