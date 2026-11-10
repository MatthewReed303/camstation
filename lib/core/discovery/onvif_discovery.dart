import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camstation/core/discovery/discovered_camera.dart';

/// ONVIF WS-Discovery: a SOAP Probe to 239.255.255.250:3702; devices answer
/// with unicast ProbeMatches. We bind one ephemeral socket per IPv4
/// interface (never to the multicast address: that breaks on Windows,
/// flutter/flutter#53477) and don't need joinMulticast.
class OnvifDiscovery {
  static final _group = InternetAddress('239.255.255.250');
  static const _port = 3702;

  static String probeMessage([String? messageId]) {
    final id = messageId ?? _uuid();
    return '<?xml version="1.0" encoding="UTF-8"?>'
        '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
        'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
        '<e:Header><w:MessageID>uuid:$id</w:MessageID>'
        '<w:To e:mustUnderstand="true">'
        'urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
        '<w:Action e:mustUnderstand="true">'
        'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
        '</e:Header><e:Body><d:Probe>'
        '<d:Types>dn:NetworkVideoTransmitter</d:Types>'
        '</d:Probe></e:Body></e:Envelope>';
  }

  /// Parses a ProbeMatches reply.
  static DiscoveredCamera? parseReply(String xml, {required String fromIp}) {
    final xaddrs = RegExp(r'<[^>]*XAddrs>([^<]+)<').firstMatch(xml)?.group(1);
    if (xaddrs == null) return null;
    // Prefer the XAddr on the address that answered; cameras often list
    // several (IPv6, other NICs).
    final urls = xaddrs.split(RegExp(r'\s+')).map(Uri.tryParse).nonNulls;
    final url = urls.firstWhere(
      (u) => u.host == fromIp,
      orElse: () => urls.isNotEmpty ? urls.first : Uri(),
    );
    if (url.host.isEmpty) return null;

    final scopes = RegExp(r'<[^>]*Scopes[^>]*>([^<]*)<')
        .firstMatch(xml)
        ?.group(1);
    String? scope(String key) {
      for (final s in (scopes ?? '').split(RegExp(r'\s+'))) {
        final m = RegExp('onvif://www.onvif.org/$key/(.+)').firstMatch(s);
        if (m != null) return Uri.decodeComponent(m.group(1)!);
      }
      return null;
    }

    return DiscoveredCamera(
      ip: fromIp,
      name: scope('name'),
      model: scope('hardware'),
      manufacturer: scope('manufacturer') ?? scope('mfr'),
      onvifPort: url.hasPort ? url.port : 80,
      onvifXaddr: url.toString(),
    );
  }

  /// Multicasts the probe on every IPv4 interface, and unicasts it to
  /// [hosts] (multicast never crosses a router).
  static Future<List<DiscoveredCamera>> scan({
    Duration window = const Duration(seconds: 3),
    List<String> hosts = const [],
  }) async {
    final found = <String, DiscoveredCamera>{};
    final socks = <RawDatagramSocket>[];
    final subs = <StreamSubscription<RawSocketEvent>>[];
    final msg = utf8.encode(probeMessage());

    final addrs = <InternetAddress>[
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
        for (final a in i.addresses)
          if (!a.isLoopback) a,
    ];
    if (addrs.isEmpty) addrs.add(InternetAddress.anyIPv4);

    for (final a in addrs) {
      try {
        final s = await RawDatagramSocket.bind(a, 0);
        socks.add(s);
        subs.add(
          s.listen((e) {
            if (e != RawSocketEvent.read) return;
            final d = s.receive();
            if (d == null) return;
            final c = parseReply(
              utf8.decode(d.data, allowMalformed: true),
              fromIp: d.address.address,
            );
            if (c != null) found[c.ip] = c;
          }),
        );
        s.send(msg, _group, _port);
      } on SocketException {
        // Interface can't send multicast: skip it.
      }
    }

    // Unicast probes go out once, from an any-address socket so the OS
    // picks the routed interface.
    if (hosts.isNotEmpty) {
      final u = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socks.add(u);
      subs.add(
        u.listen((e) {
          if (e != RawSocketEvent.read) return;
          final d = u.receive();
          if (d == null) return;
          final c = parseReply(
            utf8.decode(d.data, allowMalformed: true),
            fromIp: d.address.address,
          );
          if (c != null) found[c.ip] = c;
        }),
      );
      for (final h in hosts) {
        try {
          u.send(msg, InternetAddress(h), _port);
        } on Object {
          // unreachable host or bad address: skip
        }
      }
    }

    await Future<void>.delayed(window ~/ 2);
    for (final s in socks) {
      try {
        s.send(msg, _group, _port); // second probe: UDP is lossy
      } on SocketException {
        // ignore
      }
    }
    await Future<void>.delayed(window ~/ 2);
    for (final s in subs) {
      await s.cancel();
    }
    for (final s in socks) {
      s.close();
    }
    return found.values.toList();
  }

  static String _uuid() {
    final r = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }
}
