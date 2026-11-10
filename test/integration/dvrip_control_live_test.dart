// DvripControl against a real camera.
//   CAMSTATION_CAM_IP=<ip> flutter test test/integration/dvrip_control_live_test.dart
// Read-only unless CAMSTATION_ALLOW_WRITE=1, which writes each setting back
// with its *current* value (round-trip check; nothing changes).
@Tags(['integration'])
library;

import 'dart:io';

import 'package:camstation/core/control/camera_control.dart';
import 'package:camstation/core/control/dvrip/dvrip_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final ip = env['CAMSTATION_CAM_IP'] ?? '';
  final write = env['CAMSTATION_ALLOW_WRITE'] == '1';

  test('DvripControl read (and optional same-value write)', () async {
    final c = DvripControl(
      host: ip,
      username: env['CAMSTATION_CAM_USER'] ?? 'admin',
      password: env['CAMSTATION_CAM_PASS'] ?? '',
    );
    await c.connect();
    try {
      final info = await c.deviceInfo();
      final encs = await c.encoders();
      final opts = {for (final e in encs) e.id: await c.encoderOptions(e.id)};
      final img = await c.image();
      final t = await c.time();
      // ignore: avoid_print
      print(
        'CONTROL features=${c.features.map((f) => f.name).toList()} '
        'model=${info.model} fw=${info.firmware}',
      );
      for (final e in encs) {
        final o = opts[e.id]!;
        // ignore: avoid_print
        print(
          'CONTROL ${e.label}: ${e.codec} ${e.resolution} ${e.fps}fps '
          '${e.bitrateKbps}kbps ${e.bitrateMode} gop=${e.gopSeconds}s '
          'q=${e.quality} audio=${e.audioEnabled} | options: '
          'codecs=${o.codecs} res=${o.resolutions} audio=${o.hasAudio}',
        );
        expect(
          o.resolutions,
          contains(e.resolution),
          reason: 'current value must be among decoded options',
        );
        expect(o.codecs, contains(e.codec));
      }
      // ignore: avoid_print
      print('CONTROL image flip=${img.flip} mirror=${img.mirror} time=$t');
      expect(encs, isNotEmpty);

      if (write) {
        for (final e in encs) {
          final restart = await c.setEncoder(e);
          final again = (await c.encoders()).firstWhere((x) => x.id == e.id);
          expect(again.resolution, e.resolution);
          expect(again.fps, e.fps, reason: 'camera must not clamp fps');
          expect(again.bitrateKbps, e.bitrateKbps);
          expect(again.audioEnabled, e.audioEnabled);
          // ignore: avoid_print
          print('CONTROL same-value write ${e.id}: ok (restart=$restart)');
        }
        await c.setImage(img);
        // ignore: avoid_print
        print('CONTROL same-value image write: ok');
      }
    } finally {
      await c.close();
    }
  }, skip: ip.isEmpty ? 'set CAMSTATION_CAM_IP' : null);
}
