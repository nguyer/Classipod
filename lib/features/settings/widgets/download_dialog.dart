import 'package:classipod/core/extensions/build_context_extensions.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> showDownloadDialog(BuildContext context, MusicMetadata song) =>
    showCupertinoDialog<void>(
      context: context,
      builder: (_) => _DownloadDialog(songs: [song], single: true),
    );

Future<void> showCollectionDownloadDialog(
  BuildContext context,
  List<MusicMetadata> songs,
) => showCupertinoDialog<void>(
  context: context,
  builder: (_) =>
      _DownloadDialog(songs: songs.where((song) => song.isSubsonic).toList()),
);

String downloadQualityLabel(BuildContext context, DownloadQuality quality) =>
    switch (quality) {
      DownloadQuality.original => context.localization.offlineAudioOriginal,
      DownloadQuality.high => context.localization.offlineAudioHigh,
      DownloadQuality.medium => context.localization.offlineAudioMedium,
      DownloadQuality.low => context.localization.offlineAudioLow,
    };

Future<DownloadQuality?> chooseDownloadQuality(
  BuildContext context,
  DownloadQuality current,
) => showCupertinoDialog<DownloadQuality>(
  context: context,
  builder: (context) => CupertinoAlertDialog(
    title: Text(context.localization.downloadQuality),
    actions: [
      for (final quality in DownloadQuality.values)
        CupertinoDialogAction(
          isDefaultAction: quality == current,
          onPressed: () => Navigator.of(context).pop(quality),
          child: Text(downloadQualityLabel(context, quality)),
        ),
      CupertinoDialogAction(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.localization.cancelText),
      ),
    ],
  ),
);

class _DownloadDialog extends ConsumerStatefulWidget {
  const _DownloadDialog({required this.songs, this.single = false});
  final List<MusicMetadata> songs;
  final bool single;
  @override
  ConsumerState<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends ConsumerState<_DownloadDialog> {
  bool _busy = false;
  String? _message;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _message = context.localization.offlineAudioError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(subsonicDownloadsProvider);
    final serverId = ref.watch(subsonicControllerProvider).value?.config?.id;
    final eligible = widget.single
        ? widget.songs
        : widget.songs
              .where((song) => song.isSubsonic && song.serverId == serverId)
              .toList();
    return CupertinoAlertDialog(
      title: Text(context.localization.offlineAudioTitle),
      content: Text(
        _busy
            ? context.localization.offlineAudioSaving
            : _message ??
                  (store.hasError
                      ? context.localization.offlineAudioStorageError
                      : widget.single
                      ? context.localization.offlineAudioPrompt
                      : context.localization.downloadSelectionPrompt(
                          eligible.length,
                        )),
      ),
      actions: [
        for (final quality in DownloadQuality.values)
          CupertinoDialogAction(
            isDefaultAction: store.value?.quality == quality,
            onPressed: _busy || !store.hasValue || eligible.isEmpty
                ? null
                : () => _run(
                    () => widget.single
                        ? ref
                              .read(subsonicControllerProvider.notifier)
                              .download(widget.songs.single, quality)
                        : ref
                              .read(subsonicControllerProvider.notifier)
                              .enqueueDownloads(eligible, quality),
                  ),
            child: Text(downloadQualityLabel(context, quality)),
          ),
        if (widget.single)
          CupertinoDialogAction(
            onPressed: _busy || !store.hasValue
                ? null
                : () => _run(() async {
                    final queue = await ref.read(
                      subsonicDownloadQueueProvider.future,
                    );
                    await queue.remove(widget.songs.single);
                  }),
            child: Text(context.localization.offlineAudioRemove),
          ),
        CupertinoDialogAction(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(context.localization.cancelText),
        ),
      ],
    );
  }
}
