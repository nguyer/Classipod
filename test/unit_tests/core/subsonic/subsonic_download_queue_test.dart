import 'dart:async';
import 'dart:io';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_client.dart';
import 'package:classipod/core/subsonic/subsonic_download_queue.dart';
import 'package:classipod/core/subsonic/subsonic_downloads.dart';
import 'package:classipod/hive/hive_registrar.g.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const config = SubsonicConfig(
    'https://music.test',
    'listener',
    enabled: true,
  );
  late Directory root;
  late Box<dynamic> box;
  late SubsonicDownloads store;
  late SubsonicDownloadQueue queue;
  late SubsonicClient client;
  var fail = <String>{};
  var requested = <String>[];
  MusicMetadata song(String id, {String? server}) => MusicMetadata(
    songId: 'subsonic:${server ?? config.id}:$id',
    remoteSongId: id,
    serverId: server ?? config.id,
    trackName: id,
    isOnDevice: false,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-queue-');
    Hive.init(root.path);
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapters();
    box = await Hive.openBox<dynamic>('queue');
    store = SubsonicDownloads(box, Directory('${root.path}/audio'));
    queue = SubsonicDownloadQueue(store);
    requested = [];
    fail = {};
    client = SubsonicClient(
      config,
      'secret',
      client: MockClient((request) async {
        final id = request.url.queryParameters['id']!;
        requested.add(id);
        if (fail.contains(id)) return http.Response('server unavailable', 503);
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      }),
    );
  });
  tearDown(() async {
    await queue.close();
    client.close();
    await Hive.close();
    await root.delete(recursive: true);
  });

  test(
    'collection queue deduplicates and excludes phone/other account tracks',
    () async {
      final a = song('a');
      await queue.enqueue(
        [
          a,
          a,
          song('b'),
          MusicMetadata(filePath: '/phone.mp3'),
          song('foreign', server: 'other'),
        ],
        DownloadQuality.high,
        serverId: config.id,
      );
      expect(queue.jobs(config.id), hasLength(2));
      await queue.run(client);
      expect(requested, ['a', 'b']);
      expect(store.songs(config.id), hasLength(2));
      expect(queue.jobs(config.id), isEmpty);
      await queue.enqueue(
        [a, song('b')],
        DownloadQuality.low,
        serverId: config.id,
      );
      expect(queue.jobs(config.id), isEmpty);
      expect(queue.received, 3);
    },
  );

  test(
    'queue, chosen quality and settings survive a process restart',
    () async {
      await queue.setAutoDownload(config.id, true);
      await queue.setWifiOnly(config.id, false);
      await queue.setPaused(config.id, true);
      await queue.enqueue(
        [song('a')],
        DownloadQuality.medium,
        serverId: config.id,
      );
      await queue.close();
      await box.close();
      box = await Hive.openBox<dynamic>('queue');
      store = SubsonicDownloads(box, store.directory);
      queue = SubsonicDownloadQueue(store);
      expect(queue.autoDownload(config.id), isTrue);
      expect(queue.wifiOnly(config.id), isFalse);
      expect(queue.paused(config.id), isTrue);
      expect(queue.jobs(config.id).single.quality, DownloadQuality.medium);
      await queue.run(client);
      expect(requested, isEmpty);
      await queue.setPaused(config.id, false);
      await queue.run(client);
      expect(requested, ['a']);
    },
  );

  test(
    'failure is retained while remaining songs continue; retry succeeds',
    () async {
      fail.add('a');
      await queue.enqueue(
        [song('a'), song('b')],
        DownloadQuality.original,
        serverId: config.id,
      );
      await queue.run(client);
      expect(requested, ['a', 'b']);
      expect(queue.jobs(config.id).single.failed, isTrue);
      expect(queue.jobs(config.id).single.error, 'download');
      expect(await store.resolve(song('b')), isNotNull);
      fail.clear();
      await queue.retry(config.id);
      await queue.run(client);
      expect(requested, ['a', 'b', 'a']);
      expect(queue.jobs(config.id), isEmpty);
    },
  );

  test(
    'Wi-Fi policy and foreground state gate transfers without losing jobs',
    () async {
      await queue.enqueue(
        [song('a')],
        DownloadQuality.original,
        serverId: config.id,
      );
      expect(queue.wifiOnly(config.id), isTrue);
      await queue.run(
        client,
        networkAllowed: (wifiOnly) async {
          expect(wifiOnly, isTrue);
          return false;
        },
      );
      expect(queue.waitingForNetwork, isTrue);
      expect(requested, isEmpty);
      queue.setForeground(false);
      await queue.run(client, networkAllowed: (_) async => true);
      expect(requested, isEmpty);
      queue.setForeground(true);
      await queue.run(client, networkAllowed: (_) async => true);
      expect(requested, ['a']);
      expect(queue.waitingForNetwork, isFalse);
    },
  );

  test(
    'pausing a live stream leaves it queued and cleans the partial file',
    () async {
      final bytes = StreamController<List<int>>();
      final started = Completer<void>();
      final slow = SubsonicClient(
        config,
        'secret',
        client: MockClient.streaming((_, _) async {
          started.complete();
          return http.StreamedResponse(
            bytes.stream,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }),
      );
      addTearDown(slow.close);
      await queue.enqueue(
        [song('a'), song('b')],
        DownloadQuality.original,
        serverId: config.id,
      );
      final running = queue.run(slow);
      await started.future;
      await queue.setPaused(config.id, true);
      bytes.add([1, 2, 3]);
      await bytes.close();
      await running;
      expect(queue.jobs(config.id), hasLength(2));
      expect(store.songs(config.id), isEmpty);
      expect(store.directory.listSync(), isEmpty);
      await queue.setPaused(config.id, false);
      await queue.run(client);
      expect(requested, ['a', 'b']);
    },
  );

  test('automatic refresh adds new music without refetching saved or excluded songs', () async {
    await queue.setAutoDownload(config.id, true);
    await queue.enqueue(
      [song('a')],
      DownloadQuality.high,
      serverId: config.id,
      automatic: true,
    );
    await queue.run(client);
    await queue.enqueue(
      [song('a'), song('b')],
      DownloadQuality.high,
      serverId: config.id,
      automatic: true,
    );
    await queue.run(client);
    expect(requested, ['a', 'b']);
    await queue.remove(song('a'));
    await queue.enqueue(
      [song('a'), song('b'), song('c')],
      DownloadQuality.high,
      serverId: config.id,
      automatic: true,
    );
    expect(queue.jobs(config.id).single.song.remoteSongId, 'c');
    await queue.enqueue([song('a')], DownloadQuality.low, serverId: config.id);
    await queue.run(client);
    expect(requested, ['a', 'b', 'c', 'a']);
  });

  test(
    'turning off automatic downloads removes its jobs, keeping manual choices',
    () async {
      await queue.enqueue(
        [song('auto')],
        DownloadQuality.original,
        serverId: config.id,
        automatic: true,
      );
      await queue.enqueue(
        [song('manual')],
        DownloadQuality.low,
        serverId: config.id,
      );
      await queue.setAutoDownload(config.id, false);
      await queue.stopAutomatic(config.id);
      expect(queue.jobs(config.id).single.song.remoteSongId, 'manual');
      await queue.run(client);
      expect(requested, ['manual']);
      await queue.setAutoDownload(config.id, true);
      await queue.clear(config.id);
      expect(queue.autoDownload(config.id), isFalse);
      expect(store.songs(config.id), isEmpty);
      expect(queue.jobs(config.id), isEmpty);
    },
  );
  test('concurrent collection additions keep selection order and clearing cancels pending additions', () async {
    await Future.wait([
      queue.enqueue(
        [song('z'), song('a')],
        DownloadQuality.high,
        serverId: config.id,
      ),
      queue.enqueue(
        [song('a'), song('m')],
        DownloadQuality.low,
        serverId: config.id,
      ),
    ]);
    await queue.run(client);
    expect(requested, ['z', 'a', 'm']);
    final addition = queue.enqueue(
      [song('never')],
      DownloadQuality.original,
      serverId: config.id,
    );
    await queue.clear(config.id, removeFiles: false);
    await addition;
    expect(queue.jobs(config.id), isEmpty);
  });

  test('storage exhaustion pauses the queue instead of attempting every remaining song', () async {
    final full = SubsonicClient(
      config,
      'secret',
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream<List<int>>.error(
            const FileSystemException(
              'Full',
              '/private/audio',
              OSError('No space', 28),
            ),
          ),
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      ),
    );
    addTearDown(full.close);
    await queue.enqueue(
      [song('a'), song('b')],
      DownloadQuality.original,
      serverId: config.id,
    );
    await queue.run(full);
    expect(queue.paused(config.id), isTrue);
    expect(queue.lastError(config.id), 'storageFull');
    expect(queue.jobs(config.id).where((job) => job.failed), hasLength(1));
    expect(queue.jobs(config.id).where((job) => !job.failed), hasLength(1));
    await queue.setPaused(config.id, false);
    await queue.retry(config.id);
    await queue.run(client);
    expect(requested, ['a', 'b']);
  });
}
