// OnvifControl against a real camera.
//   CAMSTATION_CAM_IP=<ip> CAMSTATION_ONVIF_PORT=<port> \
//     flutter test test/integration/onvif_control_live_test.dart
// Read-only unless CAMSTATION_ALLOW_WRITE=1, which writes settings back with
// their *current* values (round-trip check; nothing changes).
@Tags(['integration'])
library;

import 'dart:io';

import 'package:camstation/core/control/camera_control.dart';
import 'package:camstation/core/control/onvif/onvif_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final ip = env['CAMSTATION_CAM_IP'] ?? '';
  final write = env['CAMSTATION_ALLOW_WRITE'] == '1';

  test('OnvifControl read (and optional same-value write)', () async {
    final c = OnvifControl(
      host: ip,
      port: int.tryParse(env['CAMSTATION_ONVIF_PORT'] ?? '') ?? 80,
      username: env['CAMSTATION_CAM_USER'] ?? 'admin',
      password: env['CAMSTATION_CAM_PASS'] ?? '',
    );
    await c.connect();
    try {
      final info = await c.deviceInfo();
      // ignore: avoid_print
      print(
        'ONVIF features=${c.features.map((f) => f.name).toList()} '
        '${info.manufacturer} ${info.model} fw=${info.firmware}',
      );
      final encs = await c.encoders();
      for (final e in encs) {
        final o = await c.encoderOptions(e.id);
        // ignore: avoid_print
        print(
          'ONVIF ${e.label}: ${e.codec} ${e.resolution} ${e.fps}fps '
          '${e.bitrateKbps}kbps gop=${e.gopSeconds}s | res=${o.resolutions} '
          'maxFps=${o.maxFps}',
        );
      }
      final img = await c.image();
      // ignore: avoid_print
      print(
        'ONVIF image b=${img.brightness?.round()} c=${img.contrast?.round()} '
        's=${img.saturation?.round()} sh=${img.sharpness?.round()} '
        'time=${await c.time()}',
      );
      expect(encs, isNotEmpty);
      if (write) {
        // Some firmware rejects even an unchanged config (ConfigModify);
        // report it rather than fail: the request itself is spec-valid.
        try {
          for (final e in encs) {
            await c.setEncoder(e);
            final again = (await c.encoders()).firstWhere((x) => x.id == e.id);
            expect(again.resolution, e.resolution);
            expect(again.fps, e.fps, reason: 'camera must not clamp fps');
            expect(again.bitrateKbps, e.bitrateKbps);
          }
          // ignore: avoid_print
          print('ONVIF same-value encoder write: ok');
        } on ControlException catch (e) {
          // ignore: avoid_print
          print('ONVIF encoder write rejected by camera: $e');
        }
        try {
          await c.setImage(img);
          final img2 = await c.image();
          expect(img2.brightness?.round(), img.brightness?.round());
          // ignore: avoid_print
          print('ONVIF same-value image write: ok');
        } on ControlException catch (e) {
          // ignore: avoid_print
          print('ONVIF image write rejected by camera: $e');
        }
      }
    } finally {
      await c.close();
    }
  }, skip: ip.isEmpty ? 'set CAMSTATION_CAM_IP' : null);
}
