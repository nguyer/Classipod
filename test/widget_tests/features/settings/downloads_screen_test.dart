import 'dart:collection';
import 'dart:io';

import 'package:classipod/core/constants/constants.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/providers/filtered_audio_files_provider.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_client.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:classipod/core/subsonic/subsonic_download_queue.dart';
import 'package:classipod/core/subsonic/subsonic_downloads.dart';
import 'package:classipod/features/music/album/models/album_model.dart';
import 'package:classipod/features/music/album/screens/album_more_options_modal.dart';
import 'package:classipod/features/music/artists/providers/artist_names_provider.dart';
import 'package:classipod/features/music/artists/screens/artists_selection_screen.dart';
import 'package:classipod/features/music/playlist/models/playlist_model.dart';
import 'package:classipod/features/music/playlist/screens/playlists_screen.dart';
import 'package:classipod/features/settings/screens/downloaded_music_screen.dart';
import 'package:classipod/features/settings/screens/downloads_screen.dart';
import 'package:classipod/hive/hive_registrar.g.dart';
import 'package:classipod/l10n/generated/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = SubsonicConfig('https://music.test', 'u', enabled: true);

class _Controller extends SubsonicController {
  _Controller(this.queue, this.songs);
  final SubsonicDownloadQueue queue;
  final List<MusicMetadata> songs;
  List<MusicMetadata>? selected;
  DownloadQuality? quality;
  @override
  Future<SubsonicState> build() async =>
      SubsonicState(config: _config, songs: songs, signedIn: true);
  @override
  Future<void> enqueueDownloads(
    Iterable<MusicMetadata> songs,
    DownloadQuality quality, {
    bool replace = false,
  }) async {
    selected = songs.toList();
    this.quality = quality;
  }

  @override
  Future<void> setAutomaticDownloads(bool enabled) async {
    await queue.setAutoDownload(_config.id, enabled);
  }

  @override
  Future<void> pumpDownloads() async {}
}

void main() {
  late Directory root;
  late SubsonicDownloads store;
  late SubsonicDownloadQueue queue;
  late ProviderContainer container;
  late _Controller controller;
  late List<MusicMetadata> songs;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('downloads-ui-');
    Hive.init(root.path);
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapters();
    final box = await Hive.openBox<dynamic>('download-ui');
    final playlists = await Hive.openBox<PlaylistModel>(
      Constants.playlistBoxName,
    );
    songs = [
      for (final id in ['a', 'b'])
        MusicMetadata(
          songId: 'subsonic:${_config.id}:$id',
          serverId: _config.id,
          remoteSongId: id,
          trackName: id,
          trackArtistNames: ['Artist'],
          isOnDevice: false,
        ),
      MusicMetadata(filePath: '/local.mp3', trackArtistNames: ['Artist']),
    ];
    await playlists.add(PlaylistModel(name: 'My playlist', songs: songs));
    store = SubsonicDownloads(box, Directory('${root.path}/audio'));
    queue = SubsonicDownloadQueue(store);
    controller = _Controller(queue, songs);
    container = ProviderContainer(
      overrides: [
        subsonicControllerProvider.overrideWith(() => controller),
        subsonicDownloadsProvider.overrideWith((_) async => store),
        subsonicDownloadQueueProvider.overrideWith((_) async => queue),
        artistNamesProvider.overrideWithValue(['Artist']),
        filteredAudioFilesProvider.overrideWith(
          (_) async => UnmodifiableListView(songs),
        ),
      ],
    );
    await container.read(subsonicControllerProvider.future);
    await container.read(filteredAudioFilesProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await queue.close();
    await Hive.close();
    await root.delete(recursive: true);
  });
  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(320, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: const [Locale('en')],
          home: screen,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectQuality(WidgetTester tester) async {
    expect(find.textContaining('Add 2 server songs'), findsOneWidget);
    await tester.ensureVisible(find.text('Medium / 192 kbps MP3'));
    await tester.tap(find.text('Medium / 192 kbps MP3'));
    await tester.pumpAndSettle();
    expect(controller.selected!.map((song) => song.remoteSongId), ['a', 'b']);
    expect(controller.quality, DownloadQuality.medium);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'album Download queues the whole server album, ignoring phone files',
    (tester) async {
      await open(
        tester,
        AlbumMoreOptionsModal(
          routeName: 'album',
          albumDetail: AlbumModel(
            albumName: 'Album',
            albumArtistName: 'Artist',
            albumSongs: songs,
          ),
        ),
      );
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await selectQuality(tester);
    },
  );
  testWidgets('artist long press downloads all matching server songs', (
    tester,
  ) async {
    await open(tester, const ArtistsSelectionScreen());
    await tester.longPress(find.text('Artist'));
    await tester.pumpAndSettle();
    await selectQuality(tester);
  });
  testWidgets(
    'playlist long press downloads every server song in the playlist',
    (tester) async {
      await open(tester, const PlaylistsScreen());
      await tester.longPress(find.text('My playlist'));
      await tester.pumpAndSettle();
      await selectQuality(tester);
    },
  );
  testWidgets(
    'manager lists storage and pending songs, confirms removal, and disables auto mode',
    (tester) async {
      final client = SubsonicClient(
        _config,
        'secret',
        client: MockClient(
          (_) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'audio/mpeg'},
          ),
        ),
      );
      addTearDown(client.close);
      await tester.runAsync(() async {
        await store.download(client, songs.first);
        await queue.enqueue(
          [songs[1]],
          DownloadQuality.high,
          serverId: _config.id,
        );
        await queue.setAutoDownload(_config.id, true);
      });
      await open(tester, const DownloadsScreen());
      expect(find.textContaining('3 B'), findsOneWidget);
      expect(
        find.text('Make entire library available offline'),
        findsOneWidget,
      );
      expect(find.text('Download all music'), findsNothing);
      expect(find.text('Keep entire library offline'), findsNothing);
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsNothing);
      // The wheel must reveal the last row despite the storage/progress header.
      final dynamic screen = tester.state(find.byType(DownloadsScreen));
      for (var i = 0; i < 20; i++) {
        screen.scrollForward();
        await tester.pump();
      }
      final listRect = tester.getRect(find.byType(ListView));
      final lastRow = tester.getRect(find.text('Downloaded music'));
      expect(lastRow.bottom, lessThanOrEqualTo(listRect.bottom));
      expect(lastRow.top, greaterThanOrEqualTo(listRect.top));
      screen.scrollBackward();
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('Remove all downloads'));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your server music and playlists stay unchanged'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Remove download'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Remove download'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(store.songs(_config.id), isEmpty);
      expect(queue.jobs(_config.id), isEmpty);
      expect(queue.autoDownload(_config.id), isFalse);
      expect(find.textContaining('0 B'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );
  testWidgets(
    'downloaded music opens its own submenu with saved and queued songs',
    (tester) async {
      final client = SubsonicClient(
        _config,
        'secret',
        client: MockClient(
          (_) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'audio/mpeg'},
          ),
        ),
      );
      addTearDown(client.close);
      await tester.runAsync(() async {
        await store.download(client, songs.first);
        await queue.enqueue(
          [songs[1]],
          DownloadQuality.high,
          serverId: _config.id,
        );
      });
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const DownloadsScreen(),
            routes: [
              GoRoute(
                path: 'downloadedMusic',
                name: 'downloadedMusic',
                builder: (_, _) => const DownloadedMusicScreen(),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.binding.setSurfaceSize(const Size(320, 240));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: CupertinoApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: const [Locale('en')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Downloaded music'),
        80,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Downloaded music'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadedMusicScreen), findsOneWidget);
      expect(find.text('a'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
      expect(find.text('Downloaded'), findsOneWidget);
      expect(find.text('Queued'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsNothing);
      expect(find.text('Downloaded music'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('downloaded music submenu has an empty state', (tester) async {
    await open(tester, const DownloadedMusicScreen());
    expect(find.text('No downloaded or queued music'), findsOneWidget);
  });
}
