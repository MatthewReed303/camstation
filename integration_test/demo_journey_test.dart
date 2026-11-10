// End-to-end walkthrough against the demo camera (tool/demo_camera.sh), with
// a screenshot per step — never a real camera. Covers adding cameras, live
// view exits, full screen, sleep/wake recovery, the grid and settings.
//   tool/demo_camera.sh &   # on the host
//   flutter test integration_test/demo_journey_test.dart -d <device> --no-uninstall \
//     [--dart-define=CAMSTATION_DEMO_URL=tcp://10.0.2.2:9100]
// Default URL: tcp://10.0.2.2:9100 on Android (emulator → host), else
// tcp://127.0.0.1:9100.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camstation/app/app.dart';
import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera_repository.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/media/rtsp_player.dart';
import 'package:camstation/media/webrtc_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_env.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const demoDefine = String.fromEnvironment('CAMSTATION_DEMO_URL');
  final demoUrl = demoDefine.isNotEmpty
      ? demoDefine
      : Platform.environment['CAMSTATION_DEMO_URL'] ??
            (Platform.isAndroid
                ? 'tcp://10.0.2.2:9100'
                : 'tcp://127.0.0.1:9100');
  final out = Directory(
    testEnv('CAMSTATION_JOURNEY_OUT') ??
        '${Directory.systemTemp.path}/camstation_demo',
  );

  testWidgets('demo journey', (tester) async {
    RtspPlayer.registerBackend();
    await WebRtcPlayer.configureAudio(); // as main() does
    await out.create(recursive: true);
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;

    final dataDir = await Directory.systemTemp.createTemp('cs_demo_');
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
      debugPrint('STEP shot $name');
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(300);
      final b =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage();
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      final f = File(
        '${out.path}/${(++n).toString().padLeft(2, '0')}_$name.png',
      );
      await f.writeAsBytes(png!.buffer.asUint8List());
      debugPrint('DEMO ${f.path}');
    }

    Future<void> tap(Finder f, [int ms = 700]) async {
      debugPrint('STEP tap $f');
      await tester.ensureVisible(f.first);
      await tester.tap(f.first);
      await settle(ms);
    }

    Future<void> addDemoCamera(String name, {bool shotForm = false}) async {
      await tap(find.text('Add camera'), 2500);
      await tap(find.text('Enter details manually'), 1000);
      await tap(find.text('Auto-detect (recommended)'), 600);
      await tap(find.textContaining('Other stream URL').last, 800);
      await tester.enterText(find.widgetWithText(TextFormField, 'Name'), name);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Main stream URL'),
        demoUrl,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        '',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(400);
      await tap(find.text('Test'), 8000);
      if (shotForm) await shot('add_camera');
      await tap(find.byTooltip('Save'), 1500);
    }

    // 1. Empty state.
    await settle(1500);
    await shot('empty');

    // 2. Two demo cameras added by URL.
    await addDemoCamera('Front door', shotForm: true);
    await addDemoCamera('Driveway');
    await settle(1000);
    await shot('list');
    // The demo stream has no talk channel; flag one so the mic control is
    // on screen (it is not pressed).
    final front = container
        .read(camerasProvider)
        .value!
        .firstWhere((c) => c.name == 'Front door');
    await container
        .read(camerasProvider.notifier)
        .save(front.copyWith(supportsTalk: true));
    await settle(300);

    // 3. Live view; full screen; the ✕ hides with the controls and returns.
    await tap(find.text('Front door'), 5000);
    await shot('live');
    expect(find.byTooltip('Close'), findsWidgets);
    expect(find.byKey(const ValueKey('talk')), findsOneWidget);
    await tap(find.byTooltip('Full screen'), 1200);
    expect(find.byTooltip('Close'), findsOneWidget, reason: '✕ on entry');
    await shot('fullscreen_controls');
    await wait(const Duration(seconds: 5));
    expect(find.byTooltip('Close'), findsNothing, reason: 'auto-hidden');
    await tester.tapAt(const Offset(200, 400));
    await settle(600);
    expect(find.byTooltip('Close'), findsOneWidget, reason: 'tap shows ✕');
    await tap(find.byTooltip('Exit full screen'), 1000);

    // 4. Phone sleep: the engine stops and comes back on new ports; the
    // video must recover by itself (no stuck "Reconnecting…").
    await engine.stop();
    await wait(const Duration(seconds: 3));
    await engine.ensureStarted();
    await wait(const Duration(seconds: 15));
    expect(
      find.text('Reconnecting…'),
      findsNothing,
      reason: 'recovers after the engine restarts',
    );
    await shot('after_wake');

    // ✕ goes back to the list.
    await tap(find.byTooltip('Close'), 1500);
    expect(find.text('Driveway'), findsOneWidget);

    // 5. Grid: tap opens; tile pause; long-press menu.
    await tap(find.byTooltip('Grid'), 6000);
    await shot('grid');
    await tap(find.byTooltip('Pause'), 2500);
    await shot('grid_paused');
    await tester.longPress(find.text('Driveway').first);
    await settle(800);
    await shot('grid_menu');
    await tap(find.text('Open'), 5000);
    await tap(find.byTooltip('Close'), 1500);
    expect(find.byTooltip('Layout'), findsOneWidget, reason: '✕ back to grid');
    await tap(find.byType(BackButton), 800);
    await settle(1500);
    await shot('list_thumbs');

    // Per-camera defaults: ⋮ → Edit → When this camera opens.
    await tap(find.byTooltip('Show menu').first, 800);
    await tap(find.text('Edit'), 1500);
    await tap(find.text('When this camera opens'), 800);
    // Orientation is a phone-only choice; Full screen is always there.
    await tester.ensureVisible(
      find.text(Platform.isAndroid ? 'Orientation' : 'Full screen').last,
    );
    await settle(500);
    await shot('camera_defaults');
    await tester.pageBack();
    await settle(1000);

    // 6. Settings: keep screen on + dark theme.
    await tap(find.byTooltip('Settings'), 800);
    await shot('settings');
    await tap(find.text('Dark'), 600);
    await tap(find.byType(BackButton), 800);
    await settle(1500);
    await shot('list_dark');

    // 7. HD that never starts (dead main stream, working sub): after a
    // while the view offers SD instead of spinning forever.
    final deadUrl = demoUrl.replaceFirst(RegExp(r':\d+$'), ':9199');
    await tap(find.text('Add camera'), 2500);
    await tap(find.text('Enter details manually'), 1000);
    await tap(find.text('Auto-detect (recommended)'), 600);
    await tap(find.textContaining('Other stream URL').last, 800);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Garage',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Main stream URL'),
      deadUrl,
    );
    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'Sub-stream URL (optional, used by the grid)',
      ),
      demoUrl,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(400);
    await tap(find.byTooltip('Save'), 1500);
    // Third card: below the fold, so scroll the list up first.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await settle(800);
    await tap(find.text('Garage'), 3000);
    await tap(find.text('HD'), 23000);
    expect(find.text('Use SD'), findsOneWidget, reason: 'HD hint shown');
    await shot('hd_stuck');
    await tap(find.text('Use SD'), 5000);
    expect(find.text('Use SD'), findsNothing);
    await shot('hd_stuck_sd');
    await tap(find.byTooltip('Close'), 1500);

    await tester.pumpWidget(const SizedBox());
    await settle(1000);
    await engine.stop();
    container.dispose();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
