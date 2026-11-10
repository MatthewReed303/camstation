// Drives the real app through its main screens against a real camera and
// saves a PNG of each screen (UI review without a screen-capture tool):
//
//   CAMSTATION_TOUR_OUT=/tmp/tour scripts/linux_env.sh \
//     flutter test integration_test/screens_tour_test.dart -d linux
//
// Uses a temp data dir and an in-memory secret store: never touches the
// user's real camera list or keyring.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camstation/app/app.dart';
import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
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
  final out = Directory(
    testEnv('CAMSTATION_TOUR_OUT') ??
        '${Directory.systemTemp.path}/camstation_tour',
  );
  final camIp = testEnv('CAMSTATION_CAM_IP') ?? '';
  final noCamera = camIp.isEmpty;

  testWidgets(
    'screens tour',
    (tester) async {
      RtspPlayer.registerBackend();
      await out.create(recursive: true);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;

      final dataDir = await Directory.systemTemp.createTemp('cs_tour_');
      final cam = Camera(
        id: 'tourcam${DateTime.now().millisecondsSinceEpoch}',
        name: 'Front door',
        host: camIp,
        source: testEnv('CAMSTATION_CAM_KIND') == 'dvrip'
            ? SourceKind.dvrip
            : SourceKind.onvif,
        dvripMediaViaRtsp: testEnv('CAMSTATION_DVRIP_VIA_RTSP') == '1',
        onvifPort: int.tryParse(testEnv('CAMSTATION_ONVIF_PORT') ?? '') ?? 80,
        supportsTalk: true,
      );
      File('${dataDir.path}/cameras.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'cameras': [cam.toJson()],
        }),
      );
      final secrets = MemorySecretStore();
      await secrets.write(cam.id, testEnv('CAMSTATION_CAM_PASS') ?? '');
      final engine = EngineManager(
        runtimeDir: Directory('${dataDir.path}/engine'),
        locate: testEngineLocator(),
      );

      final container = ProviderContainer(
        overrides: [
          supportDirProvider.overrideWithValue(dataDir),
          secretStoreProvider.overrideWithValue(secrets),
          engineProvider.overrideWithValue(engine),
        ],
      );
      final shotKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: shotKey,
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

      var n = 0;
      Future<void> shot(String name) async {
        await tester.pump();
        final boundary =
            shotKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final f = File(
          '${out.path}/${(++n).toString().padLeft(2, '0')}_$name.png',
        );
        await f.writeAsBytes(png!.buffer.asUint8List());
        // ignore: avoid_print
        print('TOUR ${f.path}');
      }

      Future<void> back() async {
        await tester.tap(find.byType(BackButton).first);
        await wait(const Duration(milliseconds: 600));
      }

      // 1. Camera list (engine starting).
      await wait(const Duration(seconds: 2));
      await shot('camera_list');

      // 2. Live view, default quality (HD).
      await tester.tap(find.text('Front door'));
      await wait(const Duration(seconds: 5));
      await shot('live_view_hd');

      // 3. Switch to SD.
      await tester.tap(find.text('SD'));
      await wait(const Duration(seconds: 4));
      await shot('live_view_sd');
      await back();

      // 4. Camera list again: thumbnail from the live view.
      await wait(const Duration(seconds: 1));
      await shot('camera_list_thumbnail');

      // 5. Grid.
      await tester.tap(find.byTooltip('Grid'));
      await wait(const Duration(seconds: 5));
      await shot('grid');
      await back();

      // 6. Discover with the camera's subnet saved → found automatically.
      await tester.tap(find.byTooltip('Find cameras'));
      await wait(const Duration(milliseconds: 500));
      await tester.tap(find.text('Scan network'));
      await wait(const Duration(seconds: 5));
      await shot('discover');
      await back();

      // 7. Add camera → Test (auto-detect).
      await tester.tap(find.text('Add camera'));
      await wait(const Duration(milliseconds: 500));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'IP address'),
        camIp,
      );
      await tester.tap(find.text('Test'));
      await wait(const Duration(seconds: 25));
      await shot('add_camera_test');
      await back();

      // 8. Settings.
      await tester.tap(find.byTooltip('Settings'));
      await wait(const Duration(milliseconds: 600));
      await shot('settings');

      await back();

      // 9. Camera settings (from live view).
      await tester.tap(find.text('Front door'));
      await wait(const Duration(seconds: 3));
      await tester.tap(find.byTooltip('Camera settings'));
      await wait(const Duration(seconds: 8));
      await shot('camera_settings');
      await tester.tap(find.text('Main stream (HD)'));
      await wait(const Duration(seconds: 1));
      await shot('camera_settings_video');

      await tester.pumpWidget(const SizedBox());
      await wait(const Duration(seconds: 1));
      await engine.stop();
      container.dispose();
    },
    skip: noCamera,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
