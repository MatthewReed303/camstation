// A first-time user's journey through the app, on a phone-sized screen,
// with a screenshot per step (UX review). Fresh data dir, real camera:
//   CAMSTATION_CAM_IP=<ip> [CAMSTATION_SCAN=<cidr>] [CAMSTATION_JOURNEY_OUT=dir]
//   scripts/linux_env.sh flutter test integration_test/user_journey_test.dart -d linux
// On Android pass the same keys with --dart-define and use --no-uninstall.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camstation/app/app.dart';
import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera_repository.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/media/rtsp_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_env.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final camIp = testEnv('CAMSTATION_CAM_IP') ?? '';
  final scan =
      testEnv('CAMSTATION_SCAN') ??
      (camIp.isEmpty
          ? ''
          : '${camIp.substring(0, camIp.lastIndexOf('.'))}.0/24');
  final out = Directory(
    testEnv('CAMSTATION_JOURNEY_OUT') ??
        '${Directory.systemTemp.path}/camstation_journey',
  );

  testWidgets(
    'first-time user journey',
    (tester) async {
      RtspPlayer.registerBackend();
      await out.create(recursive: true);
      // Phone portrait: 1080x2340 @ 2.75 → 393x851 logical.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;

      final dataDir = await Directory.systemTemp.createTemp('cs_journey_');
      final engine = EngineManager(
        runtimeDir: Directory('${dataDir.path}/engine'),
        locate: testEngineLocator(),
      );
      final container = ProviderContainer(
        overrides: [
          supportDirProvider.overrideWithValue(dataDir),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          engineProvider.overrideWithValue(engine),
        ],
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: UncontrolledProviderScope(
            container: container,
            child: const CamStationApp(),
          ),
        ),
      );

      Future<void> wait(Duration d) async {
        final end = DateTime.now().add(d);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      Future<void> settle([int ms = 700]) => wait(Duration(milliseconds: ms));

      var n = 0;
      Future<void> shot(String name) async {
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(300);
        final b =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 1);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        final f = File(
          '${out.path}/${(++n).toString().padLeft(2, '0')}_$name.png',
        );
        await f.writeAsBytes(png!.buffer.asUint8List());
        // ignore: avoid_print
        print('JOURNEY ${f.path}');
      }

      Future<void> tap(Finder f, [int ms = 700]) async {
        await tester.ensureVisible(f.first);
        await tester.tap(f.first);
        await settle(ms);
      }

      Future<void> back() => tap(find.byType(BackButton));

      // 1. First launch: empty state.
      await settle(1500);
      await shot('first_launch');

      // 2. Add camera → scanner starts by itself.
      await tap(find.text('Add camera'), 4500);
      await shot('scan_own_network');

      // 3. Camera on another subnet: type it in and scan again.
      if (find.textContaining(camIp).evaluate().isEmpty && scan.isNotEmpty) {
        await tap(find.text('Camera on a different network?'), 600);
        await tester.enterText(
          find.widgetWithText(TextField, 'Also scan'),
          scan,
        );
        await tap(find.text('Scan network'), 5000);
      }
      await shot('scan_found');

      // 4. Pick it → form prefilled → Test (auto-detect) → name → Save.
      await tap(find.textContaining(camIp), 1000);
      await shot('add_prefilled');
      await tap(find.text('Test'), 25000);
      await shot('add_tested');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Front door',
      );
      await tap(find.text('Save'), 1500);
      await shot('list_one_camera');

      // 5. Watch it; switch to SD; mute; leave → thumbnail.
      await tap(find.text('Front door'), 6000);
      await shot('live_default');
      await tap(find.text('SD'), 5000);
      await tap(find.byTooltip('Mute'), 500);
      await shot('live_sd_muted');
      await tap(find.byTooltip('Close'));
      await settle(1500);
      await shot('list_thumbnail');

      // 6. Reopen: should come back on SD and muted (remembered).
      await tap(find.text('Front door'), 5000);
      await shot('live_reopened_remembers');

      // 6b. Full screen is remembered too: go full screen, leave with the
      // system Back gesture, reopen → straight back to full screen.
      await tap(find.byTooltip('Full screen'), 1500);
      await shot('live_fullscreen');
      await tester.binding.handlePopRoute();
      await settle(1200);
      await tap(find.text('Front door'), 5000);
      expect(
        find.byType(AppBar),
        findsNothing,
        reason: 'reopens in full screen',
      );
      await shot('live_reopened_fullscreen');
      await tap(find.byTooltip('Exit full screen'), 1500);
      await tap(find.byTooltip('Close'));

      // 7. Per-camera defaults in Edit.
      await tap(find.byType(PopupMenuButton<String>), 500);
      await tap(find.text('Edit'), 1000);
      await tap(find.text('When this camera opens'), 600);
      await shot('edit_defaults');
      await back();

      // 8. Add a second camera manually (same device, different name).
      await tap(find.text('Add camera'), 4500);
      await tap(find.text('Enter details manually'), 1000);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Driveway',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'IP address'),
        camIp,
      );
      await tap(find.text('Test'), 25000);
      await tap(find.text('Save'), 1500);
      await shot('list_two_cameras');

      // 9. Grid: default 2 columns, then 1, tile controls, pause, arrange.
      await tap(find.byTooltip('Grid'), 6000);
      await shot('grid_2_columns');
      await tap(find.byTooltip('Layout'), 500);
      await tap(find.text('1 column'), 5000);
      await shot('grid_1_column');
      await tester.tapAt(
        tester.getCenter(find.text('Driveway')) - const Offset(0, 60),
      );
      await settle(500);
      await shot('grid_tile_controls');
      await tap(find.byTooltip('Pause'), 2000);
      await shot('grid_paused_tile');
      await tap(find.byTooltip('Arrange cameras'), 800);
      await shot('grid_arrange_sheet');
      await tester.tapAt(const Offset(200, 120)); // dismiss sheet
      await settle(600);
      await back();

      // 10. Appearance: dark theme + accent.
      await tap(find.byTooltip('Settings'), 800);
      await tap(find.text('Dark'), 600);
      await shot('settings_dark');
      await back();
      await settle(800);
      await shot('list_dark');

      // 11. Camera settings from live view.
      await tap(find.text('Front door'), 4000);
      await tap(find.byTooltip('Camera settings'), 8000);
      await shot('camera_settings');

      await tester.pumpWidget(const SizedBox());
      await settle(1000);
      await engine.stop();
      container.dispose();
    },
    skip: camIp.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
