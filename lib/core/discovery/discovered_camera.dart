import 'package:flutter/foundation.dart';

/// A camera found on the LAN, merged from DVRIP and ONVIF replies by IP.
@immutable
class DiscoveredCamera {
  const DiscoveredCamera({
    required this.ip,
    this.name,
    this.model,
    this.manufacturer,
    this.mac,
    this.firmware,
    this.dvripPort,
    this.onvifPort,
    this.onvifXaddr,
  });

  final String ip;
  final String? name;
  final String? model;
  final String? manufacturer;
  final String? mac;
  final String? firmware;

  /// Set when the camera answered DVRIP discovery.
  final int? dvripPort;

  /// Set when the camera answered ONVIF WS-Discovery.
  final int? onvifPort;
  final String? onvifXaddr;

  bool get hasDvrip => dvripPort != null;
  bool get hasOnvif => onvifPort != null;

  DiscoveredCamera merge(DiscoveredCamera o) => DiscoveredCamera(
    ip: ip,
    name: _pick(name, o.name),
    model: model ?? o.model,
    manufacturer: manufacturer ?? o.manufacturer,
    mac: mac ?? o.mac,
    firmware: firmware ?? o.firmware,
    dvripPort: dvripPort ?? o.dvripPort,
    onvifPort: onvifPort ?? o.onvifPort,
    onvifXaddr: onvifXaddr ?? o.onvifXaddr,
  );

  /// DVRIP often reports HostName "LocalHost" and ONVIF "NVT": both
  /// useless, so prefer whichever is more specific.
  static String? _pick(String? a, String? b) {
    bool generic(String? s) =>
        s == null ||
        s.isEmpty ||
        {'localhost', 'nvt'}.contains(s.toLowerCase());
    if (!generic(a)) return a;
    if (!generic(b)) return b;
    return a ?? b;
  }

  static bool _generic(String? s) =>
      s == null || s.isEmpty || {'localhost', 'nvt'}.contains(s.toLowerCase());

  /// A name a person would keep: the camera's own name if it has a real
  /// one, else "Camera <last part of the IP>".
  String get suggestedName {
    if (!_generic(name)) return name!;
    return 'Camera ${ip.split('.').last}';
  }

  /// "ONVIF · DVRIP" — what a person needs to know, no ports.
  String get protocolsLabel =>
      [if (hasOnvif) 'ONVIF', if (hasDvrip) 'DVRIP'].join(' · ');

  String get displayName {
    if (!_generic(name)) return name!;
    if (hasDvrip) return 'DVRIP camera';
    return model ?? ip;
  }
}

/// Expands targets like `192.168.1.20`, `192.168.1.0/24` or
/// `192.168.1.10-50` into host addresses for unicast probing (cameras on
/// another subnet never see broadcasts). Capped at a /22 (1022 hosts).
List<String> expandScanTargets(String input) {
  final out = <String>{};
  for (final raw in input.split(RegExp(r'[\s,;]+'))) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    final cidr = RegExp(r'^(\d+\.\d+\.\d+\.\d+)/(\d+)$').firstMatch(t);
    final range = RegExp(r'^(\d+\.\d+\.\d+)\.(\d+)-(\d+)$').firstMatch(t);
    if (cidr != null) {
      final bits = int.parse(cidr.group(2)!);
      final base = _ipKey(cidr.group(1)!);
      if (bits < 22 || bits > 32 || base == 0) {
        throw FormatException('Use a /22 to /32 network', t);
      }
      final size = 1 << (32 - bits);
      final net = base & ~(size - 1);
      final first = size > 2 ? net + 1 : net;
      final last = size > 2 ? net + size - 2 : net + size - 1;
      for (var v = first; v <= last; v++) {
        out.add(_ipStr(v));
      }
    } else if (range != null) {
      final a = int.parse(range.group(2)!);
      final b = int.parse(range.group(3)!);
      if (a > b || b > 255) throw FormatException('Bad range', t);
      for (var i = a; i <= b; i++) {
        out.add('${range.group(1)}.$i');
      }
    } else if (_ipKey(t) != 0) {
      out.add(t);
    } else {
      throw FormatException('Not an IP, range or /network', t);
    }
  }
  return out.toList();
}

String _ipStr(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF].join('.');

/// Merges results from several protocols into one entry per IP, sorted by IP.
List<DiscoveredCamera> mergeDiscovered(Iterable<DiscoveredCamera> found) {
  final byIp = <String, DiscoveredCamera>{};
  for (final c in found) {
    byIp.update(c.ip, (e) => e.merge(c), ifAbsent: () => c);
  }
  final list = byIp.values.toList()
    ..sort((a, b) => _ipKey(a.ip).compareTo(_ipKey(b.ip)));
  return list;
}

int _ipKey(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((x) => x == null || x < 0 || x > 255)) return 0;
  return (p[0]! << 24) | (p[1]! << 16) | (p[2]! << 8) | p[3]!;
}
