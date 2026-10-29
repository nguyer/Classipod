import 'package:classipod/core/extensions/build_context_extensions.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> showDownloadDialog(BuildContext context, MusicMetadata song) =>
    showCupertinoDialog<void>(
      context: context,
      builder: (_) => _DownloadDialog(song: song),
    );

class _DownloadDialog extends ConsumerStatefulWidget {
  const _DownloadDialog({required this.song});
  final MusicMetadata song;
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
    return CupertinoAlertDialog(
      title: Text(context.localization.offlineAudioTitle),
      content: Text(
        _busy
            ? context.localization.offlineAudioSaving
            : _message ??
                  (store.hasError
                      ? context.localization.offlineAudioStorageError
                      : context.localization.offlineAudioPrompt),
      ),
      actions: [
        for (final quality in DownloadQuality.values)
          CupertinoDialogAction(
            isDefaultAction: store.value?.quality == quality,
            onPressed: _busy || !store.hasValue
                ? null
                : () => _run(
                    () => ref
                        .read(subsonicControllerProvider.notifier)
                        .download(widget.song, quality),
                  ),
            child: Text(switch (quality) {
              DownloadQuality.original =>
                context.localization.offlineAudioOriginal,
              DownloadQuality.high => context.localization.offlineAudioHigh,
              DownloadQuality.medium => context.localization.offlineAudioMedium,
              DownloadQuality.low => context.localization.offlineAudioLow,
            }),
          ),
        CupertinoDialogAction(
          onPressed: _busy || !store.hasValue
              ? null
              : () => _run(() async {
                  await store.value!.remove(widget.song);
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
