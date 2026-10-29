import 'dart:async';

import 'package:classipod/core/alerts/dialogs.dart';
import 'package:classipod/core/extensions/build_context_extensions.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/navigation/routes.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:classipod/core/subsonic/subsonic_download_queue.dart';
import 'package:classipod/features/custom_screen_elements/custom_screen.dart';
import 'package:classipod/features/settings/widgets/download_dialog.dart';
import 'package:classipod/features/settings/widgets/settings_list_tile.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DownloadedMusicScreen extends ConsumerStatefulWidget {
  const DownloadedMusicScreen({super.key});
  @override
  ConsumerState<DownloadedMusicScreen> createState() => _DownloadedMusicState();
}

class _DownloadedMusicState extends ConsumerState<DownloadedMusicScreen>
    with CustomScreen {
  List<({String title, String? value, Future<void> Function() action})> _rows =
      [];
  bool _busy = false;

  @override
  String get routeName => Routes.downloadedMusic.name;
  @override
  bool get useScrollViewport => true;
  @override
  List get displayItems => _rows;
  @override
  Future<void> onSelectPressed() => _select(selectedDisplayItem);
  Future<void> _select(int index) async {
    if (_busy || index >= _rows.length) return;
    final action = _rows[index].action;
    setState(() {
      selectedDisplayItem = index;
      _busy = true;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        await Dialogs.showInfoDialog(
          context: context,
          title: context.localization.downloadedMusicTitle,
          content: context.localization.offlineAudioError,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pump() =>
      unawaited(ref.read(subsonicControllerProvider.notifier).pumpDownloads());
  Future<bool> _confirm(String message, {bool destructive = false}) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(context.localization.downloadedMusicTitle),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.localization.cancelText),
            ),
            CupertinoDialogAction(
              isDestructiveAction: destructive,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.localization.offlineAudioRemove),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _songActions(
    SubsonicDownloadQueue queue,
    MusicMetadata song,
  ) async {
    final choice = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(song.getTrackName),
        content: Text('${song.getTrackArtistNames}\n${song.albumName ?? ''}'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop('download'),
            child: Text(context.localization.offlineAudioTitle),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop('remove'),
            child: Text(context.localization.offlineAudioRemove),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.localization.cancelText),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'download') {
      await showDownloadDialog(context, song);
    } else if (choice == 'remove' &&
        await _confirm(
          context.localization.downloadRemoveTrackPrompt,
          destructive: true,
        )) {
      await queue.remove(song);
      _pump();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(downloadRecordsChangesProvider);
    final queueState = ref.watch(subsonicDownloadQueueProvider);
    final queue = queueState.value;
    final id = ref.watch(subsonicControllerProvider).value?.config?.id;
    final l = context.localization;
    if (queue == null) {
      return Center(
        child: queueState.hasError
            ? Text(l.offlineAudioStorageError)
            : const CupertinoActivityIndicator(),
      );
    }
    if (id == null) return Center(child: Text(l.subsonicSignIn));
    final songs = queue.downloads.songs(id);
    final jobs = queue.jobs(id);
    _rows = [];
    final entries = <String, ({MusicMetadata song, String value})>{
      for (final song in songs)
        song.identity: (song: song, value: l.downloadCompleted),
      for (final job in jobs)
        job.song.identity: (
          song: job.song,
          value: job.failed ? l.downloadFailed : l.downloadQueued,
        ),
    };
    for (final entry in entries.values) {
      _rows.add((
        title: entry.song.getTrackName,
        value: entry.value,
        action: () => _songActions(queue, entry.song),
      ));
    }

    if (_rows.isEmpty) return Center(child: Text(l.downloadedMusicEmpty));
    if (selectedDisplayItem >= _rows.length) {
      selectedDisplayItem = _rows.length - 1;
    }
    return CupertinoPageScaffold(
      child: CupertinoScrollbar(
        controller: scrollController,
        child: ListView.builder(
          controller: scrollController,
          itemCount: _rows.length,
          itemExtent: displayTileHeight,
          itemBuilder: (context, index) => SettingsListTile(
            text: _rows[index].title,
            value: _rows[index].value,
            isSelected: selectedDisplayItem == index,
            onTap: () => _select(index),
          ),
        ),
      ),
    );
  }
}
