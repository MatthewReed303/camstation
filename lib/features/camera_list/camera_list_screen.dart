import 'dart:io';

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/features/common/engine_banner.dart';
import 'package:camstation/features/live_view/thumbnails.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class CameraListScreen extends ConsumerWidget {
  const CameraListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cams = ref.watch(camerasProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('CamStation'),
        actions: [
          IconButton(
            tooltip: 'Grid',
            icon: const Icon(Icons.grid_view),
            onPressed: () => context.push('/grid'),
          ),
          IconButton(
            tooltip: 'Find cameras',
            icon: const Icon(Icons.radar),
            onPressed: () => context.push('/discover'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/discover'),
        icon: const Icon(Icons.add),
        label: const Text('Add camera'),
      ),
      body: Column(
        children: [
          const EngineBanner(),
          Expanded(
            child: cams.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Could not load cameras: $e')),
              data: (list) => list.isEmpty
                  ? const _Empty()
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 420,
                            childAspectRatio: 16 / 12,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _CameraCard(cam: list[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset('assets/logo/camstation-256.png', width: 96, height: 96),
          const SizedBox(height: 16),
          const Text('No cameras yet', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => context.push('/discover'),
            icon: const Icon(Icons.radar),
            label: const Text('Find cameras on my network'),
          ),
        ],
      ),
    ),
  );
}

class _CameraCard extends ConsumerWidget {
  const _CameraCard({required this.cam});
  final Camera cam;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = ref.watch(thumbnailProvider(cam.id));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/live/${cam.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: switch (thumb.value) {
                  final File f => Image.file(f, fit: BoxFit.cover),
                  _ => const Icon(
                    Icons.videocam,
                    color: Colors.white38,
                    size: 48,
                  ),
                },
              ),
            ),
            ListTile(
              title: Text(
                cam.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${cam.host} · ${cam.connectionSummary}',
                maxLines: 1,
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'settings') {
                    await context.push('/camera/${cam.id}/settings');
                  } else if (v == 'edit') {
                    await context.push('/camera/${cam.id}/edit');
                  } else if (v == 'delete') {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text('Remove ${cam.name}?'),
                        content: const Text(
                          'The camera and its saved password are removed from '
                          'this device. The camera itself is not changed.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    );
                    if (ok ?? false) {
                      await ref.read(camerasProvider.notifier).remove(cam.id);
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'settings',
                    child: Text('Camera settings'),
                  ),
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
