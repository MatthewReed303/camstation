// Live LAN discovery (read-only broadcast probes, no login).
//   CAMSTATION_LIVE_LAN=1 flutter test test/integration/discovery_live_test.dart
@Tags(['integration'])
library;

import 'dart:io';

import 'package:camstation/core/discovery/discovered_camera.dart';
import 'package:camstation/core/discovery/discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final skip = Platform.environment['CAMSTATION_LIVE_LAN'] == '1'
      ? null
      : 'set CAMSTATION_LIVE_LAN=1 to scan the real network';

  test(
    'finds cameras on the LAN via DVRIP + ONVIF',
    () async {
      final extra = Platform.environment['CAMSTATION_SCAN'] ?? '';
      final found = await DiscoveryService.scan(
        hosts: extra.isEmpty ? const [] : expandScanTargets(extra),
      );
      for (final c in found) {
        // Diagnostic output for a manual test run.
        // ignore: avoid_print
        print(
          '${c.ip}  ${c.displayName}  dvrip=${c.dvripPort}  '
          'onvif=${c.onvifPort}  fw=${c.firmware}',
        );
      }
      final target = Platform.environment['CAMSTATION_EXPECT_IP'];
      if (target != null) {
        expect(found.map((c) => c.ip), contains(target));
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
