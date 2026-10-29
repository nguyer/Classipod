import 'dart:async';

import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Resumes queued transfers on foreground/network changes without scanning.
class ForegroundDownloadActivity extends ConsumerStatefulWidget {
  const ForegroundDownloadActivity({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<ForegroundDownloadActivity> createState() => _ActivityState();
}

class _ActivityState extends ConsumerState<ForegroundDownloadActivity> {
  AppLifecycleListener? _lifecycle;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    ref
        .read(subsonicControllerProvider.notifier)
        .setDownloadForeground(_foreground);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _foreground = state == AppLifecycleState.resumed;
        ref
            .read(subsonicControllerProvider.notifier)
            .setDownloadForeground(_foreground);
        if (_foreground) _resumeDownloads();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resumeDownloads();
    });
  }

  void _resumeDownloads() {
    if (!mounted || !_foreground) return;
    final controller = ref.read(subsonicControllerProvider.notifier);
    controller.setDownloadForeground(true);
    unawaited(controller.pumpDownloads().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        ref.watch(subsonicControllerProvider).value?.enabled == true;
    if (enabled) {
      ref.listen(downloadConnectivityProvider, (previous, next) {
        if (!_foreground) return;
        if (next.hasError ||
            (next.hasValue && previous != null && previous.hasValue)) {
          ref.read(subsonicDownloadQueueProvider).value?.interrupt();
        }
        _resumeDownloads();
      });
    }
    return widget.child;
  }
}
