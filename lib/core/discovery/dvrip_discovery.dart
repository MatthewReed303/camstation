import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camstation/core/discovery/discovered_camera.dart';

/// DVRIP ("Sofia") LAN discovery.
///
/// Probe: a 20-byte header (magic 0xFF, message id 1530) broadcast to UDP
/// 34569. Cameras reply with message 1531 and JSON under
/// `NetWork.NetCommon`. Replies are often broadcast back to port 34569, so we
/// listen there. Source: OpenIPC/python-dvr, go2rtc internal/dvrip.
class DvripDiscovery {
  static const port = 34569;
  static const _probeMsg = 1530;
  static const _replyMsg = 1531;

  static Uint8List probePacket() {
    final b = ByteData(20)
      ..setUint8(0, 0xFF)
      ..setUint16(14, _probeMsg, Endian.little);
    return b.buffer.asUint8List();
  }

  /// Parses one UDP payload. Returns null if it is not a discovery reply.
  static DiscoveredCamera? parseReply(Uint8List data, {String? fromIp}) {
    if (data.length < 20 || data[0] != 0xFF) return null;
    final h = ByteData.sublistView(data);
    if (h.getUint16(14, Endian.little) != _replyMsg) return null;
    final len = h.getUint32(16, Endian.little);
    final end = (20 + len).clamp(20, data.length);
    var body = utf8.decode(data.sublist(20, end), allowMalformed: true);
    body = body.replaceAll(RegExp(r'[\x00\s]+$'), '');
    if (body.isEmpty) return null;

    final Map<String, Object?> j;
    try {
      j = jsonDecode(body) as Map<String, Object?>;
    } on FormatException {
      return null;
    }
    final nc = (j['NetWork.NetCommon'] as Map<String, Object?>?) ?? j;
    final ip = decodeHostIp(nc['HostIP'] as String?) ?? fromIp;
    if (ip == null) return null;
    return DiscoveredCamera(
      ip: ip,
      name: nc['HostName'] as String?,
      mac: (nc['MAC'] as String?)?.toLowerCase(),
      firmware: nc['Version'] as String?,
      dvripPort: (nc['TCPPort'] as int?) ?? 34567,
    );
  }

  /// HostIP is little-endian hex: "0x1401A8C0" → 192.168.1.20.
  static String? decodeHostIp(String? hex) {
    if (hex == null) return null;
    final v = int.tryParse(hex.replaceFirst(RegExp('^0[xX]'), ''), radix: 16);
    if (v == null) return null;
    return [
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ].join('.');
  }

  /// Broadcasts the probe (and unicasts it to [hosts], for cameras on other
  /// subnets) and collects replies for [window].
  static Future<List<DiscoveredCamera>> scan({
    Duration window = const Duration(seconds: 3),
    List<String> hosts = const [],
  }) async {
    RawDatagramSocket sock;
    try {
      sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
    } on SocketException {
      // Port busy: fall back to an ephemeral port (unicast replies still
      // arrive; broadcast replies to 34569 are missed).
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    sock.broadcastEnabled = true;

    final found = <String, DiscoveredCamera>{};
    final sub = sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d == null) return;
      final c = parseReply(d.data, fromIp: d.address.address);
      if (c != null) found[c.ip] = c;
    });

    final probe = probePacket();
    final targets = {'255.255.255.255', ...await _subnetBroadcasts(), ...hosts};
    for (var i = 0; i < 3; i++) {
      for (final t in targets) {
        try {
          sock.send(probe, InternetAddress(t), port);
        } on SocketException {
          // Interface without broadcast: ignore.
        }
      }
      await Future<void>.delayed(window ~/ 3);
    }
    await Future<void>.delayed(window ~/ 3);
    await sub.cancel();
    sock.close();
    return found.values.toList();
  }

  /// Assumes /24 networks (dart:io doesn't expose netmasks); the global
  /// broadcast covers the rest.
  static Future<Set<String>> _subnetBroadcasts() async {
    final out = <String>{};
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        final p = a.address.split('.');
        out.add('${p[0]}.${p[1]}.${p[2]}.255');
      }
    }
    return out;
  }
}
