import 'dart:async';
import 'dart:io';

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/util/app_log.dart';
import 'package:camstation/core/util/screen_awake.dart';
import 'package:camstation/features/live_view/player_factory.dart';
import 'package:camstation/features/live_view/player_status_overlay.dart';
import 'package:camstation/features/live_view/thumbnails.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:camstation/media/talk_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

class LiveViewScreen extends ConsumerStatefulWidget {
  const LiveViewScreen({required this.cameraId, super.key});
  final String cameraId;

  @override
  ConsumerState<LiveViewScreen> createState() => _LiveViewScreenState();
}

class _LiveViewScreenState extends ConsumerState<LiveViewScreen> {
  late final CameraPlayer _player = createCameraPlayer(ref);
  StreamQuality _quality = StreamQuality.sub;
  late final ThumbnailKeeper _thumbs = ThumbnailKeeper(
    ref: ref,
    cameraId: widget.cameraId,
    capture: _player.snapshot,
  );
  Camera? _cam;
  TalkSession? _talk;
  bool _talking = false;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    ScreenAwake.watching(on: true);
    _openViews++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_applyOrientation());
      unawaited(_fullscreen ? _immersive() : _normalUi());
      if (_fullscreen) _showControls();
    });
    _cam = ref.read(camerasProvider.notifier).byId(widget.cameraId);
    final cam = _cam;
    if (cam != null) {
      // Open the way this camera is set up (or was last viewed).
      final start = ref.read(viewStateProvider.notifier).resolve(cam);
      _quality = start.quality;
      unawaited(_player.setMuted(muted: start.muted));
      unawaited(_player.setVolume(start.volume));
      _orientation = start.orientation;
      _fullscreen = start.fullscreen;
      unawaited(_applyOrientation());
      if (_fullscreen) {
        unawaited(
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
        );
      }
    }
    _player.state.addListener(_onPlayerState);
    unawaited(_open());
  }

  Future<void> _open() async {
    final cam = _cam;
    if (cam == null) return;
    try {
      final name = await ref.read(streamRegistryProvider).media(cam, _quality);
      if (mounted) await _player.play(name);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onPlayerState() {
    if (_player.state.value.status == PlayerStatus.playing) {
      if (_error != null && mounted) setState(() => _error = null);
      _thumbs.onPlaying();
    } else {
      _thumbs.onStopped();
    }
  }

  void _remember(ViewState Function(ViewState) f) => unawaited(
    ref.read(viewStateProvider.notifier).remember(widget.cameraId, f),
  );

  final TransformationController _zoom = TransformationController();
  bool get _zoomed => _zoom.value.getMaxScaleOnAxis() > 1.01;

  void _close() {
    // Back where the user came from (grid or list); the list if this view
    // was opened directly.
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  /// Not zoomed: a fast horizontal swipe moves to the previous/next camera.
  void _onInteractionEnd(ScaleEndDetails d) {
    setState(() {}); // refresh the "Reset zoom" chip
    if (_zoomed || d.pointerCount > 1) return;
    final vx = d.velocity.pixelsPerSecond.dx;
    if (vx.abs() < 700) return;
    final cams = ref.read(camerasProvider).value ?? const <Camera>[];
    final i = cams.indexWhere((c) => c.id == widget.cameraId);
    if (i < 0 || cams.length < 2) return;
    final next = cams[(i + (vx < 0 ? 1 : -1) + cams.length) % cams.length];
    unawaited(HapticFeedback.selectionClick());
    context.pushReplacement('/live/${next.id}');
  }

  Future<void> _switchQuality(StreamQuality q) async {
    unawaited(HapticFeedback.selectionClick());
    if (q == _quality) return;
    setState(() => _quality = q);
    _remember((v) => v.copyWith(quality: q));
    await _open(); // CameraPlayer cancels the in-flight connection
  }

  Future<void> _snapshot() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final png = await _player.snapshot();
      if (png == null) throw StateError('no frame yet');
      final dir = await _snapshotDir();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final f = File('${dir.path}/${_safe(_cam!.name)}_$ts.png');
      await f.writeAsBytes(png);
      await saveThumbnail(ref, widget.cameraId, png);
      messenger.showSnackBar(SnackBar(content: Text('Saved ${f.path}')));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Snapshot failed: $e')));
    }
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^\w\- ]'), '_');

  static Future<Directory> _snapshotDir() async {
    Directory? base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory(); // Android/data/<pkg>/files
    } else {
      base = await getDownloadsDirectory();
    }
    base ??= await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/CamStation');
    await d.create(recursive: true);
    return d;
  }

  Future<void> _talkStart() async {
    final cam = _cam;
    if (cam == null || _talking) return;
    // The microphone permission prompt comes from getUserMedia itself.
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _talking = true);
    try {
      final name = await ref.read(streamRegistryProvider).talk(cam);
      if (name == null) throw StateError('camera has no talk channel');
      final t = TalkSession(
        api: ref.read(engineProvider).api,
        talkStreamName: name,
      );
      _talk = t;
      try {
        await t.start();
        if (!_talking) {
          await t.stop(); // released while connecting: free mic + camera
          return;
        }
      } on Object catch (e) {
        // The camera's talk channel can be briefly busy (e.g. a previous
        // session still closing): retry once before giving up.
        if (!_talkBusy(e) || !_talking) rethrow;
        AppLog.add('talk', 'talk channel busy, retrying: $e');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!_talking) return;
        await t.start();
        if (!_talking) await t.stop();
      }
    } on Object catch (e) {
      AppLog.add('talk', 'failed: $e');
      final denied = '$e'.toLowerCase().contains('permission');
      _toast(
        denied
            ? 'Microphone permission is needed to talk'
            : _talkBusy(e)
            ? 'The camera is busy talking to another app or device. '
                  'Close it there and try again.'
            : 'Talk failed: $e',
      );
      await _talkStop();
    }
  }

  /// DVRIP cameras answer OPTalk with Ret 503 when talk is already in use.
  static bool _talkBusy(Object e) {
    final m = '$e';
    return m.contains('OPTalk') && m.contains('503');
  }

  Future<void> _talkStop() async {
    final t = _talk;
    _talk = null;
    if (mounted) setState(() => _talking = false);
    await t?.stop();
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    _remember((v) => v.copyWith(fullscreen: _fullscreen));
    _showControls(); // never leave a bare video with no way out
    await (_fullscreen ? _immersive() : _normalUi());
  }

  Timer? _hideControls;

  /// Full screen: show the controls (incl. ✕) and hide them again after a
  /// few seconds. Outside full screen they are always shown.
  void _showControls() {
    _hideControls?.cancel();
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    if (!_fullscreen) return;
    _hideControls = Timer(const Duration(seconds: 4), () {
      if (mounted && _fullscreen) setState(() => _controlsVisible = false);
    });
  }

  void _onVideoTap() {
    if (!_fullscreen) return;
    if (_controlsVisible) {
      _hideControls?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  static Future<void> _immersive() =>
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  /// Bars back. `manual` with all overlays also works below Android 10,
  /// where edgeToEdge is ignored.
  static Future<void> _normalUi() => SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );

  /// Live views open: swiping between cameras replaces one live view with
  /// another, and the old one's dispose runs after the new one's initState,
  /// so only the last one to close restores rotation and system bars.
  static int _openViews = 0;

  ViewOrientation _orientation = ViewOrientation.auto;
  static bool get _rotatable => Platform.isAndroid || Platform.isIOS;

  Future<void> _applyOrientation() async {
    if (!_rotatable) return;
    await SystemChrome.setPreferredOrientations(switch (_orientation) {
      ViewOrientation.auto => const [],
      ViewOrientation.landscape => const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
      ViewOrientation.portrait => const [DeviceOrientation.portraitUp],
    });
  }

  Future<void> _cycleOrientation() async {
    final next = ViewOrientation
        .values[(_orientation.index + 1) % ViewOrientation.values.length];
    setState(() => _orientation = next);
    _remember((v) => v.copyWith(orientation: next));
    await _applyOrientation();
  }

  @override
  void dispose() {
    _thumbs.dispose();
    _zoom.dispose();
    unawaited(_player.dispose());
    unawaited(_talk?.stop());
    ScreenAwake.watching(on: false);
    _hideControls?.cancel();
    _openViews--;
    if (_openViews == 0) {
      // Back to normal bars and rotation for the rest of the app.
      unawaited(_normalUi());
      if (_rotatable) {
        unawaited(SystemChrome.setPreferredOrientations(const []));
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    if (cam == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Camera not found')),
      );
    }
    final video = GestureDetector(
      onTap: _onVideoTap,
      onDoubleTap: _toggleFullscreen,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              transformationController: _zoom,
              maxScale: 6,
              onInteractionEnd: _onInteractionEnd,
              child: _player.view(),
            ),
            PlayerStatusOverlay(player: _player),
            if (_zoomed)
              Positioned(
                left: 0,
                right: 0,
                top: 8,
                child: Center(
                  child: ActionChip(
                    avatar: const Icon(Icons.zoom_out_map, size: 18),
                    label: const Text('Reset zoom'),
                    onPressed: () =>
                        setState(() => _zoom.value = Matrix4.identity()),
                  ),
                ),
              ),
            if (_fullscreen && _controlsVisible)
              Positioned(
                left: 8,
                top: 8,
                child: SafeArea(
                  child: IconButton.filledTonal(
                    tooltip: 'Close',
                    onPressed: _close,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            if (_error != null)
              Center(
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            if (ref.watch(settingsProvider).showStreamInfo)
              Positioned(
                right: 8,
                top: 8,
                child: PlayerInfoBadge(player: _player),
              ),
            if (_talking)
              const Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: Center(
                  child: Chip(
                    avatar: Icon(Icons.mic, color: Colors.red),
                    label: Text('Talking'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final scaffold = Scaffold(
      backgroundColor: _fullscreen ? Colors.black : null,
      appBar: _fullscreen
          ? null
          : AppBar(
              leading: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: _close,
              ),
              title: Text(cam.name),
              actions: [
                IconButton(
                  tooltip: 'Camera settings',
                  icon: const Icon(Icons.tune),
                  onPressed: () => context.push('/camera/${cam.id}/settings'),
                ),
              ],
            ),
      body: LayoutBuilder(
        builder: (context, box) {
          final portrait = box.maxHeight > box.maxWidth * 1.2;
          if (_fullscreen) {
            return Column(
              children: [
                Expanded(child: video),
                if (_controlsVisible) _controlsRow(cam),
              ],
            );
          }
          if (!portrait) {
            return Column(
              children: [
                Expanded(child: video),
                _controlsRow(cam),
              ],
            );
          }
          // Phone held upright: 16:9 video on top, tidy controls, and a big
          // talk button in the space that's left.
          return Column(
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: video),
              _controlsPortrait(cam),
              Expanded(
                child: cam.supportsTalk
                    ? Center(child: _talkButton(large: true))
                    : const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
    if (!_fullscreen) return scaffold;
    // Full screen is always black, so its controls use the dark colours
    // whatever the app theme is.
    return Theme(
      data: ThemeData(
        colorSchemeSeed: Color(ref.watch(settingsProvider).seedColor),
        brightness: Brightness.dark,
      ),
      child: scaffold,
    );
  }

  Widget get _qualityButton => SegmentedButton<StreamQuality>(
    showSelectedIcon: false,
    segments: const [
      ButtonSegment(value: StreamQuality.main, label: Text('HD')),
      ButtonSegment(value: StreamQuality.sub, label: Text('SD')),
    ],
    selected: {_quality},
    onSelectionChanged: (s) => _switchQuality(s.first),
  );

  Widget get _muteButton => IconButton(
    tooltip: _player.muted ? 'Unmute' : 'Mute',
    icon: Icon(_player.muted ? Icons.volume_off : Icons.volume_up),
    onPressed: () async {
      await _player.setMuted(muted: !_player.muted);
      _remember((v) => v.copyWith(muted: _player.muted));
      setState(() {});
    },
  );

  Widget get _volumeSlider => Slider(
    value: _player.volume,
    onChanged: (v) {
      unawaited(_player.setVolume(v));
      setState(() {});
    },
    onChangeEnd: (v) => _remember((s) => s.copyWith(volume: v)),
  );

  Widget get _snapshotButton => IconButton(
    tooltip: 'Snapshot',
    icon: const Icon(Icons.photo_camera_outlined),
    onPressed: _snapshot,
  );

  Widget get _rotateButton => IconButton(
    tooltip: 'Orientation: ${_orientation.label}',
    icon: Icon(switch (_orientation) {
      ViewOrientation.auto => Icons.screen_rotation,
      ViewOrientation.landscape => Icons.stay_current_landscape,
      ViewOrientation.portrait => Icons.stay_current_portrait,
    }),
    onPressed: _cycleOrientation,
  );

  Widget get _fullscreenButton => IconButton(
    tooltip: _fullscreen ? 'Exit full screen' : 'Full screen',
    icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
    onPressed: _toggleFullscreen,
  );

  Widget _talkButton({bool large = false}) {
    final talking = _talking;
    final child = large
        ? Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: talking
                  ? Colors.red.shade400
                  : Theme.of(context).colorScheme.secondaryContainer,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mic, size: 40, color: talking ? Colors.white : null),
                Text(
                  talking ? 'Talking…' : 'Hold to talk',
                  style: TextStyle(color: talking ? Colors.white : null),
                ),
              ],
            ),
          )
        : FilledButton.tonalIcon(
            onPressed: () {},
            style: talking
                ? FilledButton.styleFrom(backgroundColor: Colors.red.shade300)
                : null,
            icon: const Icon(Icons.mic),
            label: const Text('Hold to talk'),
          );
    return Semantics(
      button: true,
      label: 'Hold to talk',
      child: Listener(
        onPointerDown: (_) => _talkStart(),
        onPointerUp: (_) => _talkStop(),
        onPointerCancel: (_) => _talkStop(),
        child: child,
      ),
    );
  }

  /// One row: landscape, desktop and full screen.
  Widget _controlsRow(Camera cam) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          _qualityButton,
          _muteButton,
          SizedBox(width: 140, child: _volumeSlider),
          _snapshotButton,
          _fullscreenButton,
          if (_rotatable) _rotateButton,
          if (cam.supportsTalk) _talkButton(),
        ],
      ),
    ),
  );

  /// Two fixed rows for phones held upright.
  Widget _controlsPortrait(Camera cam) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Column(
      children: [
        Row(
          children: [
            _qualityButton,
            const SizedBox(width: 4),
            _muteButton,
            Expanded(child: _volumeSlider),
          ],
        ),
        Row(
          children: [
            _snapshotButton,
            _fullscreenButton,
            if (_rotatable) _rotateButton,
          ],
        ),
      ],
    ),
  );
}
