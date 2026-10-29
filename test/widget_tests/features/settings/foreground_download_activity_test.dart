import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:classipod/features/settings/widgets/foreground_download_activity.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ForegroundController extends SubsonicController {
  int checks = 0;
  bool foreground = false;
  @override
  Future<SubsonicState> build() async => const SubsonicState();
  @override
  void setDownloadForeground(bool value) {
    foreground = value;
  }

  @override
  Future<void> pumpDownloads() async {
    checks++;
  }
}

void main() {
  testWidgets(
    'transfers resume on foreground changes without any timed checks',
    (tester) async {
      final controller = _ForegroundController();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subsonicControllerProvider.overrideWith(() => controller),
          ],
          child: const ForegroundDownloadActivity(child: SizedBox()),
        ),
      );
      await tester.pump();
      expect(controller.foreground, isTrue);
      final initial = controller.checks;
      await tester.pump(const Duration(hours: 1));
      expect(controller.checks, initial);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final before = controller.checks;
      expect(controller.foreground, isFalse);
      await tester.pump(const Duration(minutes: 6));
      expect(controller.checks, before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(controller.foreground, isTrue);
      expect(controller.checks, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
