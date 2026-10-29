import 'dart:async';
import 'dart:io';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:classipod/core/subsonic/subsonic_downloads.dart';
import 'package:classipod/features/settings/widgets/download_dialog.dart';
import 'package:classipod/l10n/generated/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class DownloadDialogController extends SubsonicController {
  final Completer<void> completion = Completer<void>();
  DownloadQuality? selected;
  @override
  Future<SubsonicState> build() async => const SubsonicState();

  @override
  Future<void> download(MusicMetadata song, DownloadQuality quality) async {
    selected = quality;
    await completion.future;
  }
}

void main() {
  late Directory root;
  late Box<dynamic> box;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-dialog-');
    Hive.init(root.path);
    box = await Hive.openBox<dynamic>('dialog');
  });
  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });
  testWidgets('small screen quality picker blocks repeated taps and reports '
      'failure for retry', (tester) async {
    final controller = DownloadDialogController();
    await tester.binding.setSurfaceSize(const Size(320, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subsonicDownloadsProvider.overrideWith(
            (_) async => SubsonicDownloads(box, root),
          ),
          subsonicControllerProvider.overrideWith(() => controller),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: const [Locale('en')],
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: CupertinoButton(
                onPressed: () => showDownloadDialog(context, MusicMetadata()),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Original / raw'), findsOneWidget);
    expect(find.text('Medium / 192 kbps MP3'), findsOneWidget);
    expect(find.text('Low / 128 kbps MP3'), findsOneWidget);
    await tester.ensureVisible(find.text('High / 320 kbps MP3'));
    await tester.tap(find.text('High / 320 kbps MP3'));
    await tester.pump();
    expect(controller.selected, DownloadQuality.high);
    final buttons = tester.widgetList<CupertinoDialogAction>(
      find.byType(CupertinoDialogAction),
    );
    expect(buttons.every((button) => button.onPressed == null), isTrue);
    controller.completion.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Download failed.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
