import 'dart:async';

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/discovery/discovered_camera.dart';
import 'package:camstation/core/discovery/discovery_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  late final TextEditingController _targets = TextEditingController(
    text: ref.read(settingsProvider).lastScanTargets,
  );
  List<DiscoveredCamera>? _found;
  bool _scanning = false;
  String? _error;

  @override
  void dispose() {
    _targets.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Start scanning straight away: that's what the user came here for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_scan());
    });
  }

  Future<void> _scan() async {
    if (_scanning) return; // Enter in the box while a scan is running
    List<String> hosts;
    try {
      hosts = {
        ...expandScanTargets(_targets.text),
        // Cameras on other subnets never hear broadcasts: always re-probe
        // the networks of cameras already added.
        ...expandScanTargets(_savedCameraNetworks().join(' ')),
      }.toList();
    } on FormatException catch (e) {
      setState(() => _error = 'Extra networks: ${e.message} (${e.source})');
      return;
    }
    setState(() {
      _scanning = true;
      _error = null;
    });
    final settings = ref.read(settingsProvider);
    await ref
        .read(settingsProvider.notifier)
        .update(settings.copyWith(lastScanTargets: _targets.text.trim()));
    try {
      final found = await DiscoveryService.scan(hosts: hosts);
      if (mounted) setState(() => _found = found);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  List<String> _savedCameraNetworks() {
    final nets = <String>{};
    for (final c in ref.read(camerasProvider).value ?? const <Camera>[]) {
      final p = c.host.split('.');
      if (p.length == 4) nets.add('${p[0]}.${p[1]}.${p[2]}.0/24');
    }
    return nets.toList();
  }

  @override
  Widget build(BuildContext context) {
    final known = {
      for (final c in ref.watch(camerasProvider).value ?? const <Camera>[])
        c.host,
    };
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: const Text('Add camera')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _scanning
                ? 'Looking for cameras on your network…'
                : 'Cameras found on your network appear below.',
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Camera on a different network?'),
            initiallyExpanded: _targets.text.isNotEmpty,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _targets,
                decoration: const InputDecoration(
                  labelText: 'Also scan',
                  hintText: 'e.g. 192.168.1.0/24 or 10.0.0.20-40',
                  helperText:
                      'Networks of cameras you have added are '
                      'always scanned',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _scan(),
              ),
              const SizedBox(height: 12),
            ],
          ),
          FilledButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.radar),
            label: Text(_scanning ? 'Scanning…' : 'Scan network'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          if (found != null && found.isEmpty)
            const ListTile(
              leading: Icon(Icons.search_off),
              title: Text('No cameras found'),
              subtitle: Text(
                'Check the camera is powered and on the same network, or '
                'enter its subnet above, or add it manually by IP.',
              ),
            ),
          for (final c in found ?? const <DiscoveredCamera>[])
            Card(
              child: ListTile(
                leading: Icon(
                  c.hasDvrip ? Icons.videocam : Icons.videocam_outlined,
                ),
                title: Text(c.suggestedName),
                subtitle: Text('${c.ip} · ${c.protocolsLabel}'),
                trailing: known.contains(c.ip)
                    ? const Chip(label: Text('Added'))
                    : const Icon(Icons.add),
                onTap: known.contains(c.ip)
                    ? null
                    : () => context.push('/camera/new', extra: c),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => context.push('/camera/new'),
            icon: const Icon(Icons.edit),
            label: const Text('Enter details manually'),
          ),
        ],
      ),
    );
  }
}
