import 'dart:async';
import 'dart:io';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_client.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:classipod/core/subsonic/subsonic_downloads.dart';
import 'package:classipod/core/subsonic/subsonic_repository.dart';
import 'package:classipod/hive/hive_registrar.g.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class OfflineController extends SubsonicController {
  OfflineController(this.config, this.song);
  final SubsonicConfig config;
  final MusicMetadata song;

  @override
  Future<SubsonicState> build() async =>
      SubsonicState(config: config.withEnabled(true), songs: [song]);
}

void main() {
  const config = SubsonicConfig('https://example.test', 'listener');
  late Directory root;
  late Box<dynamic> box;
  late SubsonicDownloads downloads;
  late MusicMetadata song;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('offline-audio-');
    Hive.init(root.path);
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapters();
    box = await Hive.openBox<dynamic>('offline');
    downloads = SubsonicDownloads(box, Directory('${root.path}/audio'));
    song = MusicMetadata(
      songId: 'subsonic:${config.id}:track',
      serverId: config.id,
      remoteSongId: 'track',
      trackName: 'Saved title',
      isOnDevice: false,
    );
  });
  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  SubsonicClient client(http.Client transport) {
    final result = SubsonicClient(config, 'secret', client: transport);
    addTearDown(result.close);
    return result;
  }

  test(
    'requests all quality mappings and persists credential-free records',
    () async {
      for (final quality in DownloadQuality.values) {
        final api = client(
          MockClient((request) async {
            expect(request.url.path, '/rest/stream.view');
            expect(request.url.queryParameters['id'], 'track');
            expect(
              request.url.queryParameters['format'],
              quality == DownloadQuality.original ? 'raw' : 'mp3',
            );
            expect(
              request.url.queryParameters['maxBitRate'],
              quality.bitrate?.toString(),
            );
            return http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {'content-type': 'audio/mpeg'},
            );
          }),
        );
        await downloads.setQuality(quality);
        await downloads.download(api, song);
        expect(await downloads.resolve(song), isNotNull);
        expect(downloads.directory.listSync(), hasLength(1));
      }
      await box.close();
      box = await Hive.openBox<dynamic>('offline');
      downloads = SubsonicDownloads(box, downloads.directory);
      expect(downloads.quality, DownloadQuality.low);
      expect(downloads.songs(config.id).single.trackName, 'Saved title');
      expect(await downloads.resolve(song), isNotNull);
      final record = box.get('download:${song.identity}') as Map;
      expect(record['quality'], 'low');
      expect(record.toString(), isNot(contains('secret')));
      expect(record.toString(), isNot(contains('https://')));
    },
  );

  test(
    'rejects HTTP, API errors and empty audio without publishing files',
    () async {
      for (final response in [
        http.Response('unauthorized', 401),
        http.Response('<error/>', 200, headers: {'content-type': 'text/xml'}),
        http.Response(
          '{"error":40}',
          200,
          headers: {'content-type': 'application/json'},
        ),
        http.Response.bytes([], 200, headers: {'content-type': 'audio/mpeg'}),
      ]) {
        final api = client(MockClient((_) async => response));
        await expectLater(downloads.download(api, song), throwsException);
        expect(await downloads.resolve(song), isNull);
        expect(downloads.directory.listSync(), isEmpty);
      }
    },
  );

  test(
    'failed replacement retains previous audio and removes partial file',
    () async {
      final good = client(
        MockClient(
          (_) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'audio/mpeg'},
          ),
        ),
      );
      await downloads.download(good, song);
      final previous = await downloads.resolve(song);
      final bad = client(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.error(StateError('offline')),
            200,
            headers: {'content-type': 'audio/mpeg'},
          ),
        ),
      );
      await expectLater(downloads.download(bad, song), throwsStateError);
      expect(await downloads.resolve(song), previous);
      expect(downloads.directory.listSync(), hasLength(1));
      await File.fromUri(previous!).writeAsBytes([1]);
      expect(await downloads.resolve(song), isNull);
    },
  );

  test('isolates accounts and removes downloads', () async {
    final api = client(
      MockClient(
        (_) async => http.Response.bytes(
          [1],
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      ),
    );
    final other = MusicMetadata(serverId: 'other', remoteSongId: 'track');
    await expectLater(downloads.download(api, other), throwsException);
    await downloads.download(api, song);
    final uri = await downloads.resolve(song);
    expect(downloads.songs('other'), isEmpty);
    await downloads.removeServer(config.id);
    expect(await downloads.resolve(song), isNull);
    expect(await File.fromUri(uri!).exists(), isFalse);
  });

  test('cached player resolves without credentials; remote output never uses '
      'private files; missing cache falls back to sign-in', () async {
    final api = client(
      MockClient(
        (_) async => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      ),
    );
    await downloads.download(api, song);
    final repository = SubsonicRepository(box);
    expect(repository.cached(config.id).single.identity, song.identity);
    final container = ProviderContainer(
      overrides: [
        subsonicDownloadsProvider.overrideWith((_) async => downloads),
        subsonicRepositoryProvider.overrideWith((_) async => repository),
        subsonicControllerProvider.overrideWith(
          () => OfflineController(config, song),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(subsonicControllerProvider.future);
    final controller = container.read(subsonicControllerProvider.notifier);
    final source = await controller.resolve(song);
    expect(source.uri.scheme, 'file');
    expect(source.tag.id, song.identity);
    await expectLater(
      controller.resolveUri(song, allowLocal: false),
      throwsA(
        isA<SubsonicException>().having(
          (error) => error.code,
          'code',
          'signin',
        ),
      ),
    );
    await File.fromUri(source.uri).delete();
    await expectLater(
      controller.resolve(song),
      throwsA(
        isA<SubsonicException>().having(
          (error) => error.code,
          'code',
          'signin',
        ),
      ),
    );
  });

  test(
    'cancellation and duplicate requests never publish a partial file',
    () async {
      final bytes = StreamController<List<int>>();
      final api = client(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            bytes.stream,
            200,
            headers: {'content-type': 'audio/mpeg'},
          ),
        ),
      );
      final task = downloads.download(api, song);
      final failure = expectLater(task, throwsA(isA<SubsonicException>()));
      await expectLater(
        downloads.download(api, song),
        throwsA(isA<SubsonicException>()),
      );
      downloads.cancel();
      bytes.add([1, 2, 3]);
      await bytes.close();
      await failure;
      expect(await downloads.resolve(song), isNull);
      expect(downloads.directory.listSync(), isEmpty);
    },
  );
}
