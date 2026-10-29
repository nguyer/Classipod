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

typedef _DownloadRow = ({
  String title,
  String? value,
  Future<void> Function() action,
});

String downloadSize(int bytes) {
  if (bytes >= 1073741824) {
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});
  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen>
    with CustomScreen {
  List<_DownloadRow> _rows = [];
  bool _busy = false;
  @override
  String get routeName => Routes.downloads.name;
  @override
  List<_DownloadRow> get displayItems => _rows;
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
          title: context.localization.downloadsTitle,
          content: context.localization.offlineAudioError,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String message, {bool destructive = false}) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(context.localization.downloadsTitle),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.localization.cancelText),
            ),
            CupertinoDialogAction(
              isDestructiveAction: destructive,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                destructive
                    ? context.localization.offlineAudioRemove
                    : context.localization.offlineAudioTitle,
              ),
            ),
          ],
        ),
      ) ??
      false;
  void _pump() =>
      unawaited(ref.read(subsonicControllerProvider.notifier).pumpDownloads());
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
    final remote = ref.watch(subsonicControllerProvider).value;
    final id = remote?.config?.id;
    final queue = queueState.value;
    final l = context.localization;
    if (queue == null) {
      return Center(
        child: queueState.hasError
            ? Text(l.offlineAudioStorageError)
            : const CupertinoActivityIndicator(),
      );
    }
    if (id == null) return Center(child: Text(l.subsonicSignIn));
    final store = queue.downloads;
    final songs = store.songs(id);
    final jobs = queue.jobs(id);
    final bytes = songs.fold<int>(0, (total, song) {
      final record = store.box.get('download:${song.identity}') as Map;
      return total + (record['bytes'] as num).toInt();
    });
    String toggle(bool value) => value ? l.subsonicOn : l.subsonicOff;
    _rows = [
      (
        title: l.downloadQuality,
        value: downloadQualityLabel(context, store.quality),
        action: () async {
          final quality = await chooseDownloadQuality(context, store.quality);
          if (quality != null) await store.setQuality(quality);
        },
      ),
      (
        title: l.downloadWifiOnly,
        value: toggle(queue.wifiOnly(id)),
        action: () async {
          queue.interrupt();
          await queue.setWifiOnly(id, !queue.wifiOnly(id));
          _pump();
        },
      ),
      (
        title: l.downloadAllNow,
        value: null,
        action: () => showCollectionDownloadDialog(context, remote!.songs),
      ),
      (
        title: l.downloadKeepLibrary,
        value: toggle(queue.autoDownload(id)),
        action: () async {
          final enabled = !queue.autoDownload(id);
          if (enabled &&
              !await _confirm(
                l.downloadKeepLibraryPrompt(
                  remote!.songs.where((song) => song.isSubsonic).length,
                  downloadQualityLabel(context, store.quality),
                ),
              )) {
            return;
          }
          await ref
              .read(subsonicControllerProvider.notifier)
              .setAutomaticDownloads(enabled);
        },
      ),
      (
        title: queue.paused(id) ? l.downloadResume : l.downloadPause,
        value: null,
        action: () async {
          await queue.setPaused(id, !queue.paused(id));
          _pump();
        },
      ),
      (
        title: l.downloadRetryFailed,
        value: '${jobs.where((job) => job.failed).length}',
        action: () async {
          await queue.retry(id);
          _pump();
        },
      ),
      (
        title: l.downloadClearQueue,
        value: '${jobs.length}',
        action: () async {
          if (!await _confirm(l.downloadClearQueuePrompt, destructive: true)) {
            return;
          }
          await ref
              .read(subsonicControllerProvider.notifier)
              .setAutomaticDownloads(false);
          await queue.clear(id, removeFiles: false);
        },
      ),
      (
        title: l.downloadRemoveAll,
        value: null,
        action: () async {
          if (await _confirm(l.downloadRemoveAllPrompt, destructive: true)) {
            await queue.clear(id);
          }
        },
      ),
    ];
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
    if (selectedDisplayItem >= _rows.length) selectedDisplayItem = 0;
    return CupertinoPageScaffold(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              '${l.nSongs(songs.length)} • ${downloadSize(bytes)}',
              maxLines: 1,
            ),
          ),
          const _QueueProgress(),
          Expanded(
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
          ),
        ],
      ),
    );
  }
}

class _QueueProgress extends ConsumerWidget {
  const _QueueProgress();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(downloadQueueChangesProvider);
    final queue = ref.watch(subsonicDownloadQueueProvider).value;
    final id = ref.watch(subsonicControllerProvider).value?.config?.id;
    if (queue == null || id == null) return const SizedBox.shrink();
    final l = context.localization;
    final active = queue.active;
    if (active != null) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            Text(
              '${active.getTrackName} • ${downloadSize(queue.received)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (queue.total != null && queue.total! > 0)
              Text(
                '${(100 * queue.received / queue.total!).clamp(0, 100).round()}%',
              ),
          ],
        ),
      );
    }
    final label = queue.lastError(id) == 'storageFull'
        ? l.downloadStorageFull
        : queue.paused(id)
        ? l.downloadPaused
        : queue.waitingForNetwork
        ? (queue.wifiOnly(id)
              ? l.downloadWaitingWifi
              : l.downloadWaitingNetwork)
        : queue.jobs(id).isEmpty
        ? l.downloadQueueEmpty
        : l.downloadQueued;
    return Padding(padding: const EdgeInsets.all(4), child: Text(label));
  }
}
