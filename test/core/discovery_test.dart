import 'dart:convert';
import 'dart:typed_data';

import 'package:camstation/core/discovery/discovered_camera.dart';
import 'package:camstation/core/discovery/dvrip_discovery.dart';
import 'package:camstation/core/discovery/onvif_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a DVRIP reply shaped like the one the test camera sent
///, serial and MAC anonymised.
Uint8List dvripReply(Map<String, Object?> netCommon) {
  final body = utf8.encode(
    '${jsonEncode({'NetWork.NetCommon': netCommon, 'Ret': 100})}\n\x00',
  );
  final h = ByteData(20)
    ..setUint8(0, 0xFF)
    ..setUint16(14, 1531, Endian.little)
    ..setUint32(16, body.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...body]);
}

void main() {
  group('DVRIP discovery', () {
    test('probe packet is 20 bytes: magic 0xFF, msg 1530', () {
      final p = DvripDiscovery.probePacket();
      expect(p.length, 20);
      expect(p[0], 0xFF);
      expect(p[14] | (p[15] << 8), 1530);
    });

    test('decodes little-endian hex HostIP', () {
      expect(DvripDiscovery.decodeHostIp('0x1401A8C0'), '192.168.1.20');
      expect(DvripDiscovery.decodeHostIp('garbage'), isNull);
    });

    test('parses a real-shaped reply', () {
      final c = DvripDiscovery.parseReply(
        dvripReply({
          'HostName': 'LocalHost',
          'HostIP': '0x1401A8C0',
          'MAC': '02:00:00:AA:BB:CC',
          'TCPPort': 34567,
          'Version': 'V1.2.3',
        }),
      )!;
      expect(c.ip, '192.168.1.20');
      expect(c.dvripPort, 34567);
      expect(c.hasDvrip, isTrue);
      expect(c.mac, '02:00:00:aa:bb:cc');
      expect(c.firmware, 'V1.2.3');
    });

    test('ignores non-reply packets', () {
      expect(DvripDiscovery.parseReply(DvripDiscovery.probePacket()), isNull);
      expect(DvripDiscovery.parseReply(Uint8List(5)), isNull);
    });
  });

  group('ONVIF discovery', () {
    const reply = '''
<SOAP-ENV:Envelope><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch>
<d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/hardware/IPC-model onvif://www.onvif.org/name/NVT onvif://www.onvif.org/Profile/Streaming</d:Scopes>
<d:XAddrs>http://192.168.1.20:8899/onvif/device_service</d:XAddrs>
</d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>''';

    test('probe targets NetworkVideoTransmitter', () {
      expect(
        OnvifDiscovery.probeMessage('x'),
        contains('dn:NetworkVideoTransmitter'),
      );
    });

    test('parses XAddr port and scopes', () {
      final c = OnvifDiscovery.parseReply(reply, fromIp: '192.168.1.20')!;
      expect(c.onvifPort, 8899);
      expect(c.onvifXaddr, 'http://192.168.1.20:8899/onvif/device_service');
      expect(c.model, 'IPC-model');
      expect(c.name, 'NVT');
    });
  });

  group('scan targets', () {
    test('single IP, /24, range, dedupe', () {
      expect(expandScanTargets('192.168.1.20'), ['192.168.1.20']);
      final net = expandScanTargets('192.168.1.0/24');
      expect(net.length, 254);
      expect(net.first, '192.168.1.1');
      expect(net.last, '192.168.1.254');
      expect(expandScanTargets('10.0.0.5-7, 10.0.0.6'), [
        '10.0.0.5',
        '10.0.0.6',
        '10.0.0.7',
      ]);
    });

    test('rejects huge networks and junk', () {
      expect(() => expandScanTargets('10.0.0.0/8'), throwsFormatException);
      expect(() => expandScanTargets('camera.local'), throwsFormatException);
      expect(() => expandScanTargets('1.2.3.999'), throwsFormatException);
    });
  });

  test('merge combines protocols per IP and prefers specific names', () {
    final merged = mergeDiscovered([
      const DiscoveredCamera(ip: '192.168.1.20', name: 'NVT', onvifPort: 8899),
      const DiscoveredCamera(
        ip: '192.168.1.20',
        name: 'LocalHost',
        dvripPort: 34567,
        firmware: 'V5',
      ),
      const DiscoveredCamera(ip: '192.168.1.9', name: 'Garage', onvifPort: 80),
    ]);
    expect(merged.map((c) => c.ip), ['192.168.1.9', '192.168.1.20']);
    final xm = merged.last;
    expect(xm.hasDvrip && xm.hasOnvif, isTrue);
    expect(xm.firmware, 'V5');
    expect(xm.displayName, 'DVRIP camera');
    expect(merged.first.displayName, 'Garage');
  });
}
