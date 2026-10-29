// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:classipod/core/providers/shared_preferences_with_cache_provider.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_client.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:classipod/core/subsonic/subsonic_credentials.dart';
import 'package:classipod/core/subsonic/subsonic_download_queue.dart';
import 'package:classipod/core/subsonic/subsonic_downloads.dart';
import 'package:classipod/core/subsonic/subsonic_repository.dart';
import 'package:classipod/hive/hive_registrar.g.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Credentials implements SubsonicCredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Box<dynamic> box;
  late SubsonicDownloads store;
  late ProviderContainer container;
  late SubsonicController controller;
  late SubsonicDownloadQueue queue;
  var tracks = <String>[];
  var requested = <String>[];
  var scans = 0;
  var allowed = true;
  var clock = DateTime.utc(2026, 10, 29);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('automatic-downloads-');
    Hive.init(root.path);
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapters();
    box = await Hive.openBox<dynamic>('automatic');
    store = SubsonicDownloads(box, Directory('${root.path}/audio'));
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    tracks = ['a'];
    requested = [];
    scans = 0;
    allowed = true;
    clock = DateTime.utc(2026, 10, 29);
    container = ProviderContainer(
      overrides: [
        subsonicRepositoryProvider.overrideWith(
          (_) async => SubsonicRepository(box),
        ),
        subsonicDownloadsProvider.overrideWith((_) async => store),
        subsonicCredentialsProvider.overrideWithValue(_Credentials()),
        downloadNetworkAllowedProvider.overrideWithValue((_) async => allowed),
        downloadClockProvider.overrideWithValue(() => clock),
        subsonicClientFactoryProvider.overrideWithValue(
          (config, password) => SubsonicClient(
            config,
            password,
            client: MockClient((request) async {
              final endpoint = request.url.path.split('/').last;
              if (endpoint == 'stream.view') {
                requested.add(request.url.queryParameters['id']!);
                return http.Response.bytes(
                  [1, 2, 3],
                  200,
                  headers: {'content-type': 'audio/mpeg'},
                );
              }
              final payload = <String, dynamic>{'status': 'ok'};
              if (endpoint == 'getAlbumList2.view') {
                if (request.url.queryParameters['offset'] == '0') scans++;
                payload['albumList2'] = {
                  'album': request.url.queryParameters['offset'] == '0'
                      ? [
                          {'id': 'album'},
                        ]
                      : [],
                };
              } else if (endpoint == 'getAlbum.view') {
                payload['album'] = {
                  'id': 'album',
                  'name': 'Album',
                  'artist': 'Artist',
                  'song': [
                    for (final id in tracks)
                      {'id': id, 'title': id, 'duration': 1},
                  ],
                };
              }
              return http.Response(
                jsonEncode({'subsonic-response': payload}),
                200,
              );
            }),
          ),
        ),
      ],
    );
    await container.read(sharedPreferencesWithCacheProvider.future);
    await container.read(subsonicControllerProvider.future);
    controller = container.read(subsonicControllerProvider.notifier);
    await controller.connect('https://music.test', 'u', 'secret');
    controller.setDownloadForeground(true);
    queue = await container.read(subsonicDownloadQueueProvider.future);
  });
  tearDown(() async {
    await controller.pumpDownloads();
    await queue.close();
    container.dispose();
    await Hive.close();
    await root.delete(recursive: true);
  });

  test(
    'entire-library setting scans on schedule and adds newly published songs',
    () async {
      await store.setQuality(DownloadQuality.high);
      await controller.setAutomaticDownloads(true);
      await controller.automaticDownloadTick();
      await controller.pumpDownloads();
      expect(requested, ['a']);
      final initialScans = scans;
      await controller.automaticDownloadTick();
      expect(scans, initialScans);
      tracks.add('b');
      clock = clock.add(const Duration(minutes: 6));
      await controller.automaticDownloadTick();
      await controller.pumpDownloads();
      expect(scans, initialScans + 1);
      expect(requested, ['a', 'b']);
      final id = container.read(subsonicControllerProvider).value!.config!.id;
      expect((box.get('download:subsonic:$id:b') as Map)['quality'], 'high');
      await queue.setPaused(id, true);
      tracks.add('c');
      clock = clock.add(const Duration(minutes: 6));
      await controller.automaticDownloadTick();
      expect(scans, initialScans + 1);
      await queue.setPaused(id, false);
      controller.setDownloadForeground(false);
      await controller.automaticDownloadTick();
      expect(scans, initialScans + 1);
      controller.setDownloadForeground(true);
      await controller.automaticDownloadTick();
      await controller.pumpDownloads();
      expect(requested, ['a', 'b', 'c']);
      await controller.setAutomaticDownloads(false);
      tracks.add('d');
      clock = clock.add(const Duration(minutes: 6));
      await controller.automaticDownloadTick();
      expect(scans, initialScans + 2);
      expect(requested, ['a', 'b', 'c']);
    },
  );

  test(
    'Wi-Fi policy defers automatic scan and resumes pending jobs on reconnect',
    () async {
      allowed = false;
      final before = scans;
      await controller.setAutomaticDownloads(true);
      await controller.automaticDownloadTick();
      await controller.pumpDownloads();
      expect(scans, before);
      expect(requested, isEmpty);
      expect(queue.waitingForNetwork, isTrue);
      tracks.add('b');
      allowed = true;
      await controller.automaticDownloadTick();
      await controller.pumpDownloads();
      expect(requested, ['a', 'b']);
      final a = container.read(subsonicControllerProvider).value!.songs.first;
      await queue.remove(a);
      clock = clock.add(const Duration(minutes: 6));
      await controller.automaticDownloadTick();
      await controller.pumpDownloads();
      expect(requested, ['a', 'b']);
      expect(await store.resolve(a), isNull);
      await controller.download(a, DownloadQuality.medium);
      await controller.pumpDownloads();
      expect(requested, ['a', 'b', 'a']);
    },
  );

  test(
    'removing the account clears automatic choices, audio and persistent queue',
    () async {
      await controller.setAutomaticDownloads(true);
      await controller.automaticDownloadTick();
      await controller.pumpDownloads();
      final id = container.read(subsonicControllerProvider).value!.config!.id;
      await controller.remove();
      expect(box.get('downloadAll:$id'), isNull);
      expect(queue.jobs(id), isEmpty);
      expect(store.songs(id), isEmpty);
    },
  );
}
