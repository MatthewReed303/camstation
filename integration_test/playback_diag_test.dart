// Playback diagnostics against a real camera, run inside the real app (real
// flutter_webrtc + fvp plugins):
//
//   scripts/linux_env.sh flutter test integration_test/playback_diag_test.dart -d linux
//
// Env (required, else skipped): CAMSTATION_CAM_IP. Optional: CAMSTATION_CAM_KIND
// (dvrip|onvif, default onvif), CAMSTATION_DVRIP_VIA_RTSP=1, CAMSTATION_CAM_USER (admin),
//      CAMSTATION_CAM_PASS (empty), CAMSTATION_DIAG_OUT (PNG output dir).
import 'dart:async';
import 'dart:io';

import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/stream_sources.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:camstation/media/player_backend.dart';
import 'package:camstation/media/rtsp_player.dart';
import 'package:camstation/media/webrtc_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_env.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cam = Camera(
    id: 'diag',
    name: 'diag',
    host: testEnv('CAMSTATION_CAM_IP') ?? '',
    username: testEnv('CAMSTATION_CAM_USER') ?? 'admin',
    source: testEnv('CAMSTATION_CAM_KIND') == 'dvrip'
        ? SourceKind.dvrip
        : SourceKind.onvif,
    dvripMediaViaRtsp: testEnv('CAMSTATION_DVRIP_VIA_RTSP') == '1',
    onvifPort: int.tryParse(testEnv('CAMSTATION_ONVIF_PORT') ?? '') ?? 80,
  );
  final pass = testEnv('CAMSTATION_CAM_PASS') ?? '';
  final noCamera = (testEnv('CAMSTATION_CAM_IP') ?? '').isEmpty;
  final outDir = Directory(
    testEnv('CAMSTATION_DIAG_OUT') ??
        '${Directory.systemTemp.path}/camstation_diag',
  );

  late EngineManager engine;

  setUpAll(() async {
    if (noCamera) return;
    RtspPlayer.registerBackend();
    await outDir.create(recursive: true);
    engine = EngineManager(
      runtimeDir: await Directory.systemTemp.createTemp('cs_diag_'),
      locate: testEngineLocator(),
    );
    await engine.ensureStarted();
  });

  tearDownAll(() async {
    if (!noCamera) await engine.dispose();
  });

  String ms(Stopwatch w) => '${w.elapsedMilliseconds} ms';

  Future<void> measure(
    WidgetTester tester,
    String label,
    PlayerBackend Function(String stream) make,
    StreamQuality q,
  ) async {
    final stream = 'diag_${q.name}';
    await engine.setStream(stream, StreamSources.media(cam, pass, q));
    final b = make(stream);
    final w = Stopwatch()..start();
    String? openError;
    try {
      await b.open();
    } on Object catch (e) {
      openError = '$e';
    }
    final tOpen = w.elapsedMilliseconds;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox.expand(child: b.view())),
      ),
    );

    int? firstPicture;
    final progress = <int>[];
    PlaybackStats last = const PlaybackStats();
    while (w.elapsed < const Duration(seconds: 15)) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        last = await b.stats();
        if (firstPicture == null && last.hasPicture) {
          firstPicture = w.elapsedMilliseconds;
        }
        if (progress.length < 30) progress.add(await b.progress());
      } on Object catch (e) {
        last = PlaybackStats(packetsLost: -1);
        openError ??= 'stats: $e';
      }
      if (firstPicture != null && w.elapsedMilliseconds - firstPicture > 4000) {
        break;
      }
    }
    // ignore: avoid_print
    print(
      'DIAG $label ${q.name}: open=${openError == null ? '${tOpen}ms' : 'FAILED after ${tOpen}ms: $openError'} '
      'firstPicture=${firstPicture == null ? 'NEVER' : '${firstPicture}ms'} '
      'stats[$last] progress=${progress.take(12).toList()} total=${ms(w)}',
    );
    try {
      final png = await b.snapshot().timeout(const Duration(seconds: 3));
      if (png != null) {
        final f = File('${outDir.path}/${label}_${q.name}.png');
        await f.writeAsBytes(png);
        // ignore: avoid_print
        print('DIAG snapshot ${f.path} (${png.length} bytes)');
      }
    } on Object catch (e) {
      // ignore: avoid_print
      print('DIAG snapshot $label failed: $e');
    }
    await tester.pumpWidget(const SizedBox());
    await b.dispose();
    await engine.removeStream(stream);
  }

  for (final q in [StreamQuality.sub, StreamQuality.main]) {
    testWidgets(
      'webrtc ${q.name}',
      (tester) async {
        await measure(
          tester,
          'webrtc',
          (s) => WebRtcPlayer(api: engine.api, streamName: s),
          q,
        );
      },
      skip: noCamera,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets(
      'rtsp ${q.name}',
      (tester) async {
        await measure(
          tester,
          'rtsp',
          (s) => RtspPlayer(url: engine.settings.rtspUrl(s)),
          q,
        );
      },
      skip: noCamera,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  for (final q in [StreamQuality.sub, StreamQuality.main]) {
    testWidgets(
      'full CameraPlayer ${q.name}',
      (tester) async {
        final stream = 'diagcp_${q.name}';
        await engine.setStream(stream, StreamSources.media(cam, pass, q));
        final player = CameraPlayer(
          api: () => engine.api,
          createBackend: (mode, name) => switch (mode) {
            PlayerMode.webrtc => WebRtcPlayer(
              api: engine.api,
              streamName: name,
            ),
            PlayerMode.rtsp => RtspPlayer(url: engine.settings.rtspUrl(name)),
          },
        );
        final transitions = <String>[];
        final w = Stopwatch()..start();
        player.state.addListener(() {
          final st = player.state.value;
          transitions.add(
            '${w.elapsedMilliseconds}ms:${st.status.name}'
            '${st.mode == null ? '' : '/${st.mode!.name}'}'
            '${st.error == null ? '' : '(${st.error})'}',
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SizedBox.expand(child: player.view())),
          ),
        );
        unawaited(player.play(stream));
        int? firstPicture;
        while (w.elapsed < const Duration(seconds: 25)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 150));
          final b = player.backend.value;
          if (firstPicture == null &&
              b != null &&
              (await b.stats()).hasPicture) {
            firstPicture = w.elapsedMilliseconds;
          }
        }
        final last = await player.backend.value?.stats();
        // ignore: avoid_print
        print(
          'DIAG CameraPlayer ${q.name}: firstPicture='
          '${firstPicture == null ? 'NEVER' : '${firstPicture}ms'} '
          'transitions=$transitions final[$last]',
        );
        final png = await player.snapshot().catchError((Object _) => null);
        if (png != null) {
          await File('${outDir.path}/cameraplayer_${q.name}.png')
              .writeAsBytes(png);
        }
        await tester.pumpWidget(const SizedBox());
        await player.dispose();
        await engine.removeStream(stream);
        expect(firstPicture, isNotNull);
        expect(
          transitions.where((t) => t.contains('reconnecting')),
          isEmpty,
          reason: 'no spurious reconnects',
        );
      },
      skip: noCamera,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
