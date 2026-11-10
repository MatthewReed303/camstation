// Closing a camera must leave nothing pulling its stream (no sound playing
// on with no screen), also when it is closed while still connecting.
//   CAMSTATION_CAM_IP=<ip> [CAMSTATION_CAM_KIND=dvrip] scripts/linux_env.sh \
//     flutter test integration_test/close_stops_stream_test.dart -d linux
// On a device pass the settings with --dart-define instead.
import 'dart:async';
import 'dart:io';

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
    id: 'closecheck',
    name: 'closecheck',
    host: ip,
    username: testEnv('CAMSTATION_CAM_USER') ?? 'admin',
    source: testEnv('CAMSTATION_CAM_KIND') == 'dvrip'
        ? SourceKind.dvrip
        : SourceKind.onvif,
    onvifPort: int.tryParse(testEnv('CAMSTATION_ONVIF_PORT') ?? '') ?? 80,
  );
  final pass = testEnv('CAMSTATION_CAM_PASS') ?? '';

  late EngineManager engine;
  setUpAll(() async {
    if (ip.isEmpty) return;
    RtspPlayer.registerBackend();
    await WebRtcPlayer.configureAudio();
    engine = EngineManager(
      runtimeDir: await Directory.systemTemp.createTemp('cs_close_'),
      locate: testEngineLocator(),
    );
    await engine.ensureStarted();
    await engine.setStream(
      'close_sub',
      StreamSources.media(cam, pass, StreamQuality.sub),
    );
  });
  tearDownAll(() async {
    if (ip.isNotEmpty) await engine.dispose();
  });

  Future<int> consumers() async =>
      (await engine.api.streamStatus('close_sub'))?.consumerCount ?? 0;

  CameraPlayer player(PlayerPreference pref) => CameraPlayer(
    api: () => engine.api,
    preference: pref,
    createBackend: (mode, name) => switch (mode) {
      PlayerMode.webrtc => WebRtcPlayer(api: engine.api, streamName: name),
      PlayerMode.rtsp => RtspPlayer(url: engine.settings.rtspUrl(name)),
    },
  );

  Future<void> pumpFor(WidgetTester t, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await t.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  for (final pref in [PlayerPreference.webrtc, PlayerPreference.rtsp]) {
    testWidgets('${pref.name}: close after playing', (t) async {
      final p = player(pref);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: p.view())));
      unawaited(p.play('close_sub'));
      for (
        var i = 0;
        i < 100 && p.state.value.status != PlayerStatus.playing;
        i++
      ) {
        await pumpFor(t, const Duration(milliseconds: 200));
      }
      expect(p.state.value.status, PlayerStatus.playing);
      await pumpFor(t, const Duration(seconds: 3));
      final before = await consumers();
      await t.pumpWidget(const SizedBox());
      await p.dispose();
      await pumpFor(t, const Duration(seconds: 3));
      final after = await consumers();
      // ignore: avoid_print
      print('CLOSE ${pref.name} after playing: consumers $before → $after');
      expect(before, greaterThan(0));
      expect(after, 0, reason: 'nothing may keep pulling the stream');
    }, skip: ip.isEmpty);

    testWidgets('${pref.name}: close while connecting', (t) async {
      // Different moments: before the backend exists, mid-handshake, just
      // before the first frame. The engine must let go within a few
      // seconds, not after its ~30 s ICE timeout.
      for (final ms in [150, 400, 700, 1000]) {
        final p = player(pref);
        await t.pumpWidget(MaterialApp(home: Scaffold(body: p.view())));
        unawaited(p.play('close_sub'));
        await pumpFor(t, Duration(milliseconds: ms));
        final status = p.state.value.status;
        await t.pumpWidget(const SizedBox());
        await p.dispose();
        await pumpFor(t, const Duration(seconds: 6));
        final after = await consumers();
        // ignore: avoid_print
        print('CLOSE ${pref.name} at $ms ms ($status): consumers → $after');
        expect(after, 0, reason: 'closed at $ms ms');
      }
    }, skip: ip.isEmpty);
  }
}
