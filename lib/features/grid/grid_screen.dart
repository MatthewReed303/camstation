import 'dart:async';

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/util/screen_awake.dart';
import 'package:camstation/features/live_view/player_factory.dart';
import 'package:camstation/features/live_view/player_status_overlay.dart';
import 'package:camstation/features/live_view/thumbnails.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Multi-camera grid on sub-streams.
/// - 1–4 columns, scrolls; only tiles on screen exist, so only they play.
/// - Tap a tile for its controls (pause, sound, open); double-tap opens it.
/// - "Arrange" reorders cameras and chooses which appear.
/// Columns, order, hidden and paused cameras are remembered.
class GridScreen extends ConsumerStatefulWidget {
  const GridScreen({super.key});

  @override
  ConsumerState<GridScreen> createState() => _GridScreenState();
}

class _GridScreenState extends ConsumerState<GridScreen> {
  /// The one tile whose sound is on (null = all muted).
  String? _audible;

  AppSettings get _s => ref.read(settingsProvider);

  Future<void> _set(AppSettings Function(AppSettings) f) =>
      ref.read(settingsProvider.notifier).update(f(_s));

  @override
  void initState() {
    super.initState();
    ScreenAwake.watching(on: true);
  }

  @override
  void dispose() {
    ScreenAwake.watching(on: false);
    super.dispose();
  }

  Future<void> _togglePause(String id) => _set((s) {
    final p = {...s.gridPaused};
    if (!p.remove(id)) p.add(id);
    return s.copyWith(gridPaused: p);
  });

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final all = ref.watch(camerasProvider).value ?? const <Camera>[];
    final visible = all
        .where((c) => !settings.gridHidden.contains(c.id))
        .toList();
    final cols = settings.gridColumns;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Grid'),
        actions: [
          PopupMenuButton<int>(
            tooltip: 'Layout',
            icon: const Icon(Icons.view_module_outlined),
            initialValue: cols,
            onSelected: (v) => _set((s) => s.copyWith(gridColumns: v)),
            itemBuilder: (_) => [
              for (final n in [1, 2, 3, 4])
                CheckedPopupMenuItem(
                  value: n,
                  checked: n == cols,
                  child: Text(n == 1 ? '1 column' : '$n columns'),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Arrange cameras',
            icon: const Icon(Icons.reorder),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (_) => const _ArrangeSheet(),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) => _set(
              (s) => s.copyWith(
                gridPaused: v == 'pause' ? {for (final c in all) c.id} : {},
              ),
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pause', child: Text('Pause all')),
              PopupMenuItem(value: 'play', child: Text('Play all')),
            ],
          ),
        ],
      ),
      body: all.isEmpty
          ? const _Message('No cameras yet')
          : visible.isEmpty
          ? const _Message('All cameras are hidden. Use Arrange to show some.')
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              // No pre-building off-screen: off-screen tiles must not play.
              cacheExtent: 0,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                childAspectRatio: 16 / 9,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: visible.length,
              itemBuilder: (_, i) {
                final c = visible[i];
                return _GridTile(
                  key: ValueKey(c.id),
                  cam: c,
                  paused: settings.gridPaused.contains(c.id),
                  audible: _audible == c.id,
                  onTogglePause: () => _togglePause(c.id),
                  onToggleSound: () =>
                      setState(() => _audible = _audible == c.id ? null : c.id),
                );
              },
            ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70),
      ),
    ),
  );
}

class _GridTile extends ConsumerStatefulWidget {
  const _GridTile({
    required this.cam,
    required this.paused,
    required this.audible,
    required this.onTogglePause,
    required this.onToggleSound,
    super.key,
  });

  final Camera cam;
  final bool paused;
  final bool audible;
  final VoidCallback onTogglePause;
  final VoidCallback onToggleSound;

  @override
  ConsumerState<_GridTile> createState() => _GridTileState();
}

class _GridTileState extends ConsumerState<_GridTile> {
  CameraPlayer? _player;
  ThumbnailKeeper? _thumbs;
  bool _controls = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    if (!widget.paused) unawaited(_start());
  }

  @override
  void didUpdateWidget(_GridTile old) {
    super.didUpdateWidget(old);
    if (old.paused != widget.paused) {
      if (widget.paused) {
        unawaited(_stop());
      } else {
        unawaited(_start());
      }
    }
    if (old.audible != widget.audible) {
      unawaited(_player?.setMuted(muted: !widget.audible));
    }
  }

  Future<void> _start() async {
    if (_player != null) return;
    final p = createCameraPlayer(ref);
    final t = ThumbnailKeeper(
      ref: ref,
      cameraId: widget.cam.id,
      capture: p.snapshot,
      every: const Duration(seconds: 30),
    );
    p.state.addListener(() {
      if (p.state.value.status == PlayerStatus.playing) {
        t.onPlaying();
      } else {
        t.onStopped();
      }
    });
    setState(() {
      _player = p;
      _thumbs = t;
    });
    await p.setMuted(muted: !widget.audible);
    try {
      final name = await ref
          .read(streamRegistryProvider)
          .media(widget.cam, StreamQuality.sub);
      if (mounted && identical(_player, p)) await p.play(name);
    } on Object {
      // shown by the status overlay on the next state change
    }
  }

  Future<void> _stop() async {
    final p = _player;
    final t = _thumbs;
    if (p == null) return;
    await t?.grab(); // freshest image for the paused tile
    t?.dispose();
    setState(() {
      _player = null;
      _thumbs = null;
    });
    await p.dispose();
  }

  void _showControls() {
    _hide?.cancel();
    setState(() => _controls = !_controls);
    if (_controls) {
      _hide = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _controls = false);
      });
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    _thumbs?.dispose();
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    final thumb = ref.watch(thumbnailProvider(widget.cam.id)).value;
    return GestureDetector(
      onTap: _showControls,
      onDoubleTap: () => context.push('/live/${widget.cam.id}'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          if (thumb != null && (p == null || widget.paused))
            Image.file(
              thumb,
              fit: BoxFit.cover,
              color: Colors.black38,
              colorBlendMode: BlendMode.darken,
            ),
          if (p != null) p.view(fit: BoxFit.cover),
          if (p != null) PlayerStatusOverlay(player: p, compact: true),
          if (widget.paused)
            Center(
              child: IconButton.filledTonal(
                iconSize: 32,
                tooltip: 'Play',
                onPressed: widget.onTogglePause,
                icon: const Icon(Icons.play_arrow),
              ),
            ),
          Positioned(
            left: 6,
            bottom: 4,
            right: 6,
            child: Row(
              children: [
                if (widget.audible)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.volume_up, size: 14, color: Colors.white),
                  ),
                Expanded(
                  child: Text(
                    widget.cam.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 3)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_controls && !widget.paused)
            ColoredBox(
              color: Colors.black45,
              child: Center(
                child: Wrap(
                  spacing: 8,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Pause',
                      onPressed: widget.onTogglePause,
                      icon: const Icon(Icons.pause),
                    ),
                    IconButton.filledTonal(
                      tooltip: widget.audible ? 'Mute' : 'Sound on',
                      onPressed: widget.onToggleSound,
                      icon: Icon(
                        widget.audible ? Icons.volume_off : Icons.volume_up,
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Open',
                      onPressed: () => context.push('/live/${widget.cam.id}'),
                      icon: const Icon(Icons.open_in_full),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Drag to reorder; switch to show/hide in the grid.
class _ArrangeSheet extends ConsumerWidget {
  const _ArrangeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cams = ref.watch(camerasProvider).value ?? const <Camera>[];
    final hidden = ref.watch(settingsProvider).gridHidden;
    final height = MediaQuery.sizeOf(context).height * 0.6;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Drag to reorder · switch to show in the grid'),
          ),
          Expanded(
            child: ReorderableListView.builder(
              // Our own handle on the left; no extra desktop handles.
              buildDefaultDragHandles: false,
              itemCount: cams.length,
              onReorder: (from, to) => ref
                  .read(camerasProvider.notifier)
                  .reorder(from, to > from ? to - 1 : to),
              itemBuilder: (_, i) {
                final c = cams[i];
                return ListTile(
                  key: ValueKey(c.id),
                  leading: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(c.name),
                  subtitle: Text(c.host),
                  trailing: Switch(
                    value: !hidden.contains(c.id),
                    onChanged: (show) {
                      final s = ref.read(settingsProvider);
                      final h = {...s.gridHidden};
                      if (show) {
                        h.remove(c.id);
                      } else {
                        h.add(c.id);
                      }
                      unawaited(
                        ref
                            .read(settingsProvider.notifier)
                            .update(s.copyWith(gridHidden: h)),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
