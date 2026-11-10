// Does freeing an RTSP (fvp) player crash, and does a snapshot matter?
//   flutter test integration_test/rtsp_dispose_diag_test.dart -d <device> \
//     --dart-define=CAMSTATION_DEMO_URL=tcp://<host>:9100 \
//     --dart-define=DIAG_VARIANT=plain|snap|snap_pending|two|two_sw|two_mc \
//     [--dart-define=DIAG_DEC=MediaCodec:copy=1]
// "two" frees one of two playing players: the grid's pause case.
import 'dart:async';

import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/stream_sources.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/media/rtsp_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fvp/fvp.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test_env.dart';

const _demo = String.fromEnvironment('CAMSTATION_DEMO_URL');
const _dec = String.fromEnvironment('DIAG_DEC', defaultValue: 'MediaCodec');
const _variant = String.fromEnvironment('DIAG_VARIANT', defaultValue: 'plain');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('rtsp dispose ($_variant)', (tester) async {
    if (_variant.endsWith('_sw') || _variant.endsWith('_mc')) {
      registerWith(
        options: {
          'video.decoders': _variant.endsWith('_sw')
              ? const ['FFmpeg']
              : [_dec, 'FFmpeg'],
          'player': const {'avformat.rtsp_transport': 'tcp'},
        },
      );
    } else {
      RtspPlayer.registerBackend();
    }
    final engine = EngineManager(
      runtimeDir: await getApplicationSupportDirectory(),
      locate: testEngineLocator(),
    );
    await engine.ensureStarted();
    const cam = Camera(
      id: 'diag',
      name: 'demo',
      host: '127.0.0.1',
      source: SourceKind.url,
      username: '',
      urlMain: _demo,
    );
    await engine.setStream(
      'diag',
      StreamSources.media(cam, '', StreamQuality.main),
    );

    Future<void> pumpFor(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final players = [
      for (var i = 0; i < (_variant.startsWith('two') ? 2 : 1); i++)
        RtspPlayer(url: engine.settings.rtspUrl('diag')),
    ];
    for (final p in players) {
      await p.open();
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [for (final p in players) Expanded(child: p.view())],
          ),
        ),
      ),
    );
    await pumpFor(3000);
    // ignore: avoid_print
    print('DIAG playing');

    final p = players.first;
    if (_variant == 'snap') {
      final s = await p.snapshot();
      // ignore: avoid_print
      print('DIAG snap ${s?.length}');
    } else if (_variant == 'snap_pending') {
      unawaited(p.snapshot());
    }
    // Remove the view first (as the grid does), then free the player.
    await tester.pumpWidget(const SizedBox());
    await pumpFor(200);
    await p.dispose();
    // ignore: avoid_print
    print('DIAG disposed');
    await pumpFor(3000);
    for (final q in players.skip(1)) {
      await q.dispose();
    }
    await pumpFor(1000);
    // ignore: avoid_print
    print('DIAG survived');
    await engine.dispose();
  });
}
