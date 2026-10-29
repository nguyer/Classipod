import 'dart:io';
import 'dart:ui' as ui;

import 'package:classipod/core/sonos/sonos_client.dart';
import 'package:classipod/core/sonos/sonos_controller.dart';
import 'package:classipod/features/settings/screens/sonos_screen.dart';
import 'package:classipod/l10n/generated/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SonosRoom room(String id, {String? coordinator, bool visible = true}) =>
    SonosRoom(
      id: id,
      name: id,
      coordinatorId: coordinator ?? id,
      visible: visible,
      location: Uri.parse('http://192.168.1.2:1400/xml/device_description.xml'),
    );

class ScreenController extends SonosController {
  ScreenController(this.initial);
  final SonosState initial;
  String? selected;
  String? grouped;
  String? ungrouped;
  int searches = 0;
  @override
  SonosState build() => initial;
  @override
  Future<void> discover() async {
    searches++;
  }

  @override
  Future<void> selectRoom(SonosRoom? room) async {
    selected = room?.id ?? 'phone';
    state = state.copyWith(selectedId: room?.id, clearSelection: room == null);
  }

  @override
  Future<void> group(SonosRoom room) async {
    grouped = room.id;
  }

  @override
  Future<void> ungroup(SonosRoom room) async {
    ungrouped = room.id;
  }
}

void main() {
  Future<void> open(WidgetTester tester, ScreenController controller) async {
    const previewDirectory = String.fromEnvironment('SONOS_PREVIEW_DIRECTORY');
    if (previewDirectory.isNotEmpty) {
      await tester.runAsync(() async {
        final fonts = FontLoader('Helvetica')
          ..addFont(rootBundle.load('assets/fonts/Helvetica.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Helvetica-Bold.ttf'));
        await fonts.load();
      });
    }
    await tester.binding.setSurfaceSize(const Size(320, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sonosControllerProvider.overrideWith(() => controller)],
        child: const CupertinoApp(
          theme: CupertinoThemeData(
            textTheme: CupertinoTextThemeData(
              textStyle: TextStyle(fontFamily: 'Helvetica', fontSize: 17),
            ),
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: [Locale('en')],
          home: RepaintBoundary(
            key: ValueKey('sonos-preview'),
            child: SonosScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    const directory = String.fromEnvironment('SONOS_PREVIEW_DIRECTORY');
    if (directory.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('sonos-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$directory/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets(
    'shows rooms, hides bonded devices and confirms output selection',
    (tester) async {
      final controller = ScreenController(
        SonosState(
          rooms: [room('Kitchen'), room('Office'), room('Sub', visible: false)],
        ),
      );
      await open(tester, controller);
      await capture(tester, 'sonos-phone-output');
      expect(find.text('Sub'), findsNothing);
      expect(find.text('This phone'), findsWidgets);
      await tester.tap(find.text('Kitchen'));
      await tester.pumpAndSettle();
      expect(find.textContaining('replace this Sonos group'), findsOneWidget);
      expect(controller.selected, isNull);
      await confirm(tester);
      expect(controller.selected, 'Kitchen');
      await capture(tester, 'sonos-room-output');
      expect(find.text('Selected'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('group and ungroup require confirmation; wheel reveals bottom', (
    tester,
  ) async {
    final controller = ScreenController(
      SonosState(
        rooms: [
          room('Kitchen'),
          room('Office'),
          room('TV', coordinator: 'Kitchen'),
        ],
        selectedId: 'Kitchen',
        volume: 0.3,
      ),
    );
    await open(tester, controller);
    final dynamic screen = tester.state(find.byType(SonosScreen));
    for (var i = 0; i < 30; i++) {
      screen.scrollForward();
      await tester.pump();
    }
    final last = tester.getRect(find.text('About Sonos playback'));
    final list = tester.getRect(find.byType(ListView));
    expect(last.bottom, lessThanOrEqualTo(list.bottom));
    await tester.scrollUntilVisible(
      find.text('Group: Office'),
      -30,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Group: Office'));
    await tester.pumpAndSettle();
    expect(controller.grouped, isNull);
    await confirm(tester);
    expect(controller.grouped, 'Office');
    await tester.ensureVisible(find.text('Remove: TV'));
    await tester.tap(find.text('Remove: TV'));
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(controller.ungrouped, 'TV');
    await finish(tester);
  });

  testWidgets(
    'empty discovery and permission denial have actionable messages',
    (tester) async {
      final controller = ScreenController(
        const SonosState(error: 'permission'),
      );
      await open(tester, controller);
      expect(controller.searches, 1);
      expect(find.textContaining('Allow local network access'), findsOneWidget);
      expect(find.text('Add speaker by IP address'), findsOneWidget);
      await finish(tester);
    },
  );
}
