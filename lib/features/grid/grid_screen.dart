import 'dart:async';

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/util/screen_awake.dart';
import 'package:camstation/features/live_view/player_factory.dart';
import 'package:camstation/features/live_view/thumbnails.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Several cameras at once, on their low-bandwidth sub-streams.
/// - Tap a tile to open it; long-press for more (pause, sound, hide).
/// - Each tile shows its name, a status dot and sound/pause buttons.
/// - Only tiles on screen play, and the grid pauses while a camera is open.
/// Columns, order, hidden and paused cameras are remembered.
/// Auto grid layout: as many columns as fit with tiles at least ~320 dp
/// wide, between 1 and [max], and never more columns than cameras.
int gridAutoColumns(double width, int count, int max) =>
    (width / 320).floor().clamp(1, max).clamp(1, count < 1 ? 1 : count);

class GridScreen extends ConsumerStatefulWidget {
  const GridScreen({super.key});

  @override
  ConsumerState<GridScreen> createState() => _GridScreenState();
}

class _GridScreenState extends ConsumerState<GridScreen> {
  /// The one tile whose sound is on (null = all muted).
  String? _audible;

  /// A live view is open on top: stop the tiles meanwhile.
  bool _covered = false;

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

  AppSettings get _s => ref.read(settingsProvider);

  Future<void> _set(AppSettings Function(AppSettings) f) =>
      ref.read(settingsProvider.notifier).update(f(_s));

  Future<void> _togglePause(String id) => _set((s) {
    final p = {...s.gridPaused};
    if (!p.remove(id)) p.add(id);
    return s.copyWith(gridPaused: p);
  });

  Future<void> _hide(String id) =>
      _set((s) => s.copyWith(gridHidden: {...s.gridHidden, id}));

  Future<void> _open(String id) async {
    setState(() => _covered = true);
    await context.push('/live/$id');
    if (mounted) setState(() => _covered = false);
  }

  /// Phones (narrow side under 600 dp) get at most 2 columns: smaller tiles
  /// are too small to see or tap.
  int _maxColumns(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide < 600 ? 2 : 4;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final all = ref.watch(camerasProvider).value ?? const <Camera>[];
    final visible = all
        .where((c) => !settings.gridHidden.contains(c.id))
        .toList();
    final maxCols = _maxColumns(context);
    final width = MediaQuery.sizeOf(context).width;
    final auto = settings.gridColumns == 0;
    final cols = auto
        ? gridAutoColumns(width, visible.length, maxCols)
        : settings.gridColumns.clamp(1, maxCols);
    final tileWidth = (width - 8 * (cols + 1)) / cols;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Grid'),
        actions: [
          PopupMenuButton<int>(
            tooltip: 'Layout',
            icon: const Icon(Icons.view_module_outlined),
            onSelected: (v) => _set((s) => s.copyWith(gridColumns: v)),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 0,
                checked: auto,
                child: const Text('Auto'),
              ),
              for (var n = 1; n <= maxCols; n++)
                CheckedPopupMenuItem(
                  value: n,
                  checked: !auto && n == cols,
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
          ? const _Message(
              icon: Icons.videocam_outlined,
              text: 'No cameras yet. Add one from the camera list.',
            )
          : visible.isEmpty
          ? const _Message(
              icon: Icons.visibility_off_outlined,
              text: 'All cameras are hidden. Use Arrange to show some.',
            )
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              // No pre-building off-screen: off-screen tiles must not play.
              cacheExtent: 0,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                childAspectRatio: 16 / 9,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: visible.length,
              itemBuilder: (_, i) {
                final c = visible[i];
                return _GridTile(
                  key: ValueKey(c.id),
                  cam: c,
                  paused: settings.gridPaused.contains(c.id),
                  active: !_covered,
                  audible: _audible == c.id,
                  compact: tileWidth < 260,
                  onOpen: () => _open(c.id),
                  onTogglePause: () => _togglePause(c.id),
                  onToggleSound: () =>
                      setState(() => _audible = _audible == c.id ? null : c.id),
                  onHide: () => _hide(c.id),
                );
              },
            ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _GridTile extends ConsumerStatefulWidget {
  const _GridTile({
    required this.cam,
    required this.paused,
    required this.active,
    required this.audible,
    required this.compact,
    required this.onOpen,
    required this.onTogglePause,
    required this.onToggleSound,
    required this.onHide,
    super.key,
  });

  final Camera cam;
  final bool paused;

  /// False while a live view covers the grid.
  final bool active;
  final bool audible;
  final bool compact;
  final VoidCallback onOpen;
  final VoidCallback onTogglePause;
  final VoidCallback onToggleSound;
  final VoidCallback onHide;

  @override
  ConsumerState<_GridTile> createState() => _GridTileState();
}

class _GridTileState extends ConsumerState<_GridTile> {
  CameraPlayer? _player;
  ThumbnailKeeper? _thumbs;
  int _gen = 0;
  bool _registerFailed = false;

  bool get _shouldPlay => !widget.paused && widget.active;

  @override
  void initState() {
    super.initState();
    if (_shouldPlay) unawaited(_start());
  }

  @override
  void didUpdateWidget(_GridTile old) {
    super.didUpdateWidget(old);
    final was = !old.paused && old.active;
    if (was != _shouldPlay) unawaited(_shouldPlay ? _start() : _stop());
    if (old.audible != widget.audible) {
      unawaited(_player?.setMuted(muted: !widget.audible));
    }
  }

  Future<void> _start() async {
    final gen = ++_gen;
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
      if (mounted) setState(() {});
    });
    setState(() {
      _player = p;
      _thumbs = t;
      _registerFailed = false;
    });
    await p.setMuted(muted: !widget.audible);
    try {
      final name = await ref
          .read(streamRegistryProvider)
          .media(widget.cam, StreamQuality.sub);
      if (mounted && gen == _gen && identical(_player, p)) await p.play(name);
    } on Object {
      if (mounted && gen == _gen) setState(() => _registerFailed = true);
    }
  }

  Future<void> _stop() async {
    final gen = ++_gen;
    final p = _player;
    final t = _thumbs;
    if (p == null) return;
    // Detach first so a quick Play starts a fresh player.
    setState(() {
      _player = null;
      _thumbs = null;
    });
    await t?.grab(); // freshest image for the paused tile
    t?.dispose();
    await p.dispose();
    if (mounted && gen == _gen) setState(() {});
  }

  Future<void> _menu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                widget.cam.name,
                style: Theme.of(c).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_full),
              title: const Text('Open'),
              onTap: () => Navigator.pop(c, 'open'),
            ),
            ListTile(
              leading: Icon(widget.paused ? Icons.play_arrow : Icons.pause),
              title: Text(widget.paused ? 'Play' : 'Pause'),
              onTap: () => Navigator.pop(c, 'pause'),
            ),
            ListTile(
              leading: Icon(
                widget.audible ? Icons.volume_off : Icons.volume_up,
              ),
              title: Text(widget.audible ? 'Mute' : 'Listen to this camera'),
              onTap: () => Navigator.pop(c, 'sound'),
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Hide from grid'),
              onTap: () => Navigator.pop(c, 'hide'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'open':
        widget.onOpen();
      case 'pause':
        widget.onTogglePause();
      case 'sound':
        widget.onToggleSound();
      case 'hide':
        widget.onHide();
    }
  }

  @override
  void dispose() {
    _gen++;
    _thumbs?.dispose();
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    final status = p?.state.value.status;
    final playing = status == PlayerStatus.playing;
    final thumb = ref.watch(thumbnailProvider(widget.cam.id)).value;
    final (dot, label) = widget.paused
        ? (Colors.grey, 'Paused')
        : _registerFailed || status == PlayerStatus.error
        ? (Colors.redAccent, 'Offline')
        : playing
        ? (Colors.greenAccent, 'Live')
        : (Colors.amber, 'Connecting');

    return Semantics(
      button: true,
      label: '${widget.cam.name}, $label',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.black,
          child: InkWell(
            onTap: widget.onOpen,
            onLongPress: _menu,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Last image until the live picture arrives (never bare black).
                if (thumb != null && !playing)
                  Image.file(
                    thumb,
                    fit: BoxFit.cover,
                    color: widget.paused ? Colors.black45 : null,
                    colorBlendMode: BlendMode.darken,
                  )
                else if (!playing)
                  const Center(
                    child: Icon(
                      Icons.videocam,
                      color: Colors.white24,
                      size: 40,
                    ),
                  ),
                if (p != null) p.view(fit: BoxFit.cover),
                if (!widget.paused && !playing && label == 'Connecting')
                  const Center(
                    child: SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    ),
                  ),
                if (label == 'Offline')
                  Center(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        if (p != null) {
                          unawaited(p.reconnect());
                        } else {
                          unawaited(_start());
                        }
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ),
                if (widget.paused)
                  Center(
                    child: IconButton.filled(
                      iconSize: 32,
                      tooltip: 'Play',
                      onPressed: widget.onTogglePause,
                      icon: const Icon(Icons.play_arrow),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _TileBar(
                    name: widget.cam.name,
                    dot: dot,
                    status: label,
                    compact: widget.compact,
                    audible: widget.audible,
                    paused: widget.paused,
                    onSound: widget.onToggleSound,
                    onPause: widget.onTogglePause,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Name, status and the two tile actions on a dark gradient: always
/// readable over any picture, in light and dark themes.
class _TileBar extends StatelessWidget {
  const _TileBar({
    required this.name,
    required this.dot,
    required this.status,
    required this.compact,
    required this.audible,
    required this.paused,
    required this.onSound,
    required this.onPause,
  });

  final String name;
  final Color dot;
  final String status;
  final bool compact;
  final bool audible;
  final bool paused;
  final VoidCallback onSound;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    final iconSize = compact ? 18.0 : 22.0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(10, compact ? 10 : 16, 2, 2),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: white,
                  fontWeight: FontWeight.w600,
                  fontSize: compact ? 12 : 14,
                ),
              ),
            ),
            IconButton(
              tooltip: audible ? 'Mute' : 'Listen',
              iconSize: iconSize,
              visualDensity: VisualDensity.compact,
              color: white,
              onPressed: onSound,
              icon: Icon(audible ? Icons.volume_up : Icons.volume_off),
            ),
            IconButton(
              tooltip: paused ? 'Play' : 'Pause',
              iconSize: iconSize,
              visualDensity: VisualDensity.compact,
              color: white,
              onPressed: onPause,
              icon: Icon(paused ? Icons.play_arrow : Icons.pause),
            ),
          ],
        ),
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
