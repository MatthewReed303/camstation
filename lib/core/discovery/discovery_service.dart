import 'dart:io';

import 'package:camstation/core/discovery/discovered_camera.dart';
import 'package:camstation/core/discovery/dvrip_discovery.dart';
import 'package:camstation/core/discovery/onvif_discovery.dart';
import 'package:flutter/services.dart';

/// Runs ONVIF and DVRIP discovery together and merges the results by IP.
class DiscoveryService {
  static const _platform = MethodChannel('camstation/platform');

  /// [hosts]: extra addresses to probe directly (see [expandScanTargets]),
  /// for cameras on another subnet or site.
  static Future<List<DiscoveredCamera>> scan({
    Duration window = const Duration(seconds: 3),
    List<String> hosts = const [],
  }) async {
    // Android drops multicast/broadcast on Wi-Fi without a MulticastLock.
    final lock = Platform.isAndroid;
    if (lock) await _platform.invokeMethod<void>('acquireMulticastLock');
    try {
      // Some routers/APs drop broadcast and multicast even on the same
      // network, so also probe every address on our own networks directly.
      final all = {...hosts, ...await localSubnetHosts()}.toList();
      final results = await Future.wait([
        DvripDiscovery.scan(window: window, hosts: all),
        OnvifDiscovery.scan(window: window, hosts: all),
      ]);
      return mergeDiscovered(results.expand((r) => r));
    } finally {
      if (lock) await _platform.invokeMethod<void>('releaseMulticastLock');
    }
  }

  /// Every host on the /24 of each physical IPv4 interface. Skips loopback
  /// and virtual bridges (Docker, libvirt, VirtualBox, …) and anything that
  /// isn't a private address. dart:io has no netmask, so /24 is assumed.
  static Future<List<String>> localSubnetHosts() async {
    final virtual = RegExp(
      r'^(lo|docker|br-|virbr|veth|vmnet|vboxnet|cni|flannel|podman|lxc)',
    );
    final out = <String>{};
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      if (virtual.hasMatch(i.name)) continue;
      for (final a in i.addresses) {
        final p = a.address.split('.').map(int.parse).toList();
        final private =
            p[0] == 10 ||
            (p[0] == 172 && p[1] >= 16 && p[1] <= 31) ||
            (p[0] == 192 && p[1] == 168);
        if (!private) continue;
        out.addAll(expandScanTargets('${p[0]}.${p[1]}.${p[2]}.0/24'));
        out.remove(a.address);
      }
    }
    return out.toList();
  }
}
