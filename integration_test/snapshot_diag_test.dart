// Does CameraPlayer.snapshot() return a real image for each player mode?
//   flutter test integration_test/snapshot_diag_test.dart -d <device> \
//     --dart-define=CAMSTATION_CAM_IP=<ip> [--dart-define=CAMSTATION_CAM_KIND=dvrip …]
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/stream_sources.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:camstation/media/rtsp_player.dart';
import 'package:camstation/media/webrtc_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_env.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final ip = testEnv('CAMSTATION_CAM_IP') ?? '';
  final cam = Camera(
    id: 'snapdiag',
    name: 'snap',
    host: ip,
    source: testEnv('CAMSTATION_CAM_KIND') == 'dvrip'
        ? SourceKind.dvrip
        : SourceKind.onvif,
    dvripMediaViaRtsp: testEnv('CAMSTATION_DVRIP_VIA_RTSP') == '1',
    onvifPort: int.tryParse(testEnv('CAMSTATION_ONVIF_PORT') ?? '') ?? 80,
  );

  for (final pref in [PlayerPreference.rtsp, PlayerPreference.webrtc]) {
    testWidgets('snapshot via ${pref.name}', (tester) async {
      RtspPlayer.registerBackend();
      final engine = EngineManager(
        runtimeDir: await Directory.systemTemp.createTemp('cs_snap_'),
        locate: testEngineLocator(),
      );
      await engine.ensureStarted();
      await engine.setStream(
        'snap_sub',
        StreamSources.media(cam, '', StreamQuality.sub),
      );
      final p = CameraPlayer(
        api: () => engine.api,
        preference: pref,
        createBackend: (mode, name) => switch (mode) {
          PlayerMode.webrtc => WebRtcPlayer(api: engine.api, streamName: name),
          PlayerMode.rtsp => RtspPlayer(url: engine.settings.rtspUrl(name)),
        },
      );
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: p.view())));
      unawaited(p.play('snap_sub'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final mode = p.state.value.mode?.name;
      Object? backendErr;
      int? backendBytes;
      final w = Stopwatch()..start();
      try {
        backendBytes = (await p.backend.value!.snapshot().timeout(
          const Duration(seconds: 3),
        ))?.length;
      } on Object catch (e) {
        backendErr = e;
      }
      final tBackend = w.elapsedMilliseconds;
      final png = await p.snapshot();
      String detail = 'null';
      if (png != null) {
        final codec = await ui.instantiateImageCodec(png);
        final img = (await codec.getNextFrame()).image;
        final px = (await img.toByteData())!;
        var sum = 0;
        for (var k = 0; k < px.lengthInBytes; k += 4 * 97) {
          sum += px.getUint8(k) + px.getUint8(k + 1) + px.getUint8(k + 2);
        }
        detail =
            '${img.width}x${img.height} avgRGB=${(sum / (px.lengthInBytes / (4 * 97)) / 3).toStringAsFixed(1)}';
      }
      // ignore: avoid_print
      print(
        'SNAP pref=${pref.name} mode=$mode backend.snapshot: '
        '${backendErr ?? '$backendBytes bytes'} in ${tBackend}ms | '
        'CameraPlayer.snapshot: $detail',
      );
      await tester.pumpWidget(const SizedBox());
      await p.dispose();
      await engine.dispose();
    }, skip: ip.isEmpty);
  }
}
