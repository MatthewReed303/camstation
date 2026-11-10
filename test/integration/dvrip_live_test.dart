// READ-ONLY DVRIP inspection of a real camera: logs in, reads info,
// capabilities and settings, writes nothing to the camera.
//   CAMSTATION_CAM_IP=<ip> [CAMSTATION_CAM_USER=admin] [CAMSTATION_CAM_PASS=]
//   [CAMSTATION_DUMP_DIR=/tmp/dvrip] flutter test test/integration/dvrip_live_test.dart
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:camstation/core/control/dvrip/dvrip_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final ip = env['CAMSTATION_CAM_IP'] ?? '';
  final out = env['CAMSTATION_DUMP_DIR'];

  test('read-only DVRIP inspection', () async {
    final c = DvripClient(ip);
    await c.login(
      env['CAMSTATION_CAM_USER'] ?? 'admin',
      env['CAMSTATION_CAM_PASS'] ?? '',
    );
    final dump = <String, Object?>{};
    Future<void> grab(String key, Future<Object?> Function() f) async {
      try {
        dump[key] = await f();
      } on Object catch (e) {
        dump[key] = {'_error': '$e'};
      }
    }

    await grab('SystemInfo', c.systemInfo);
    await grab('Time', () async => (await c.getTime())?.toIso8601String());
    for (final a in ['SystemFunction', 'EncodeCapability']) {
      await grab('ability:$a', () => c.getAbility(a));
    }
    for (final s in [
      'Simplify.Encode',
      'Camera.Param',
      'Camera.ParamEx',
      'General.General',
      'General.Location',
      'NetWork.NetCommon',
      'Detect.MotionDetect',
      'fVideo.AudioInVolume',
      'AVEnc.EncodeStaticParam',
    ]) {
      await grab('config:$s', () => c.getConfig(s));
    }
    await c.close();

    final redacted = jsonEncode(dump)
        .replaceAll(RegExp(r'"SerialNo"\s*:\s*"[^"]*"'), '"SerialNo":"***"')
        .replaceAll(RegExp(r'"MAC"\s*:\s*"[^"]*"'), '"MAC":"***"');
    if (out != null) {
      await Directory(out).create(recursive: true);
      await File('$out/dvrip_dump.json').writeAsString(redacted);
    }
    // ignore: avoid_print
    print('DVRIP sections read: ${dump.keys.join(', ')}');
    expect(dump['SystemInfo'], isA<Map<String, Object?>>());
  }, skip: ip.isEmpty ? 'set CAMSTATION_CAM_IP' : null);
}
