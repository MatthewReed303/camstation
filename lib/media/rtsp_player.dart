import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camstation/media/playback_plan.dart';
import 'package:camstation/media/player_backend.dart';
import 'package:flutter/widgets.dart';
import 'package:fvp/fvp.dart';
import 'package:video_player/video_player.dart';

/// Fallback: fvp (libmdk) plays go2rtc's loopback RTSP re-stream. Used for
/// H.265 where WebRTC can't decode it, and for AAC audio.
class RtspPlayer implements PlayerBackend {
  RtspPlayer({required this.url});

  /// `rtsp://127.0.0.1:<port>/<token>`: loopback, unguessable name.
  final String url;
  VideoPlayerController? _c;
  double _volume = 1;
  bool _muted = false;

  /// Registers fvp as the video_player backend with low-latency settings.
  /// Call once at start-up.
  static void registerBackend() {
    registerWith(
      options: {
        // 2 = live: may drop frames to always show the newest picture.
        'lowLatency': 2,
        // Hardware first, software last: fvp/libmdk tries these in order, so
        // a failing hardware decoder falls back automatically.
        'video.decoders': const [
          'MediaCodec',
          'D3D11',
          'MFT:d3d=11',
          'DXVA',
          'VAAPI',
          'VDPAU',
          'CUDA',
          'VT',
          'FFmpeg',
        ],
        'player': const {
          'avformat.rtsp_transport': 'tcp',
          'avformat.fflags': '+nobuffer',
          'avformat.analyzeduration': '500000',
          'avformat.probesize': '65536',
          'buffer': '0+200',
        },
      },
    );
  }

  @override
  PlayerMode get mode => PlayerMode.rtsp;

  @override
  Future<void> open() async {
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    _c = c;
    await c.initialize().timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('RTSP player did not start'),
    );
    await c.setVolume(_muted ? 0 : _volume);
    await c.play();
  }

  @override
  Future<int> progress() async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return 0;
    if (c.value.hasError) throw StateError(c.value.errorDescription ?? 'error');
    return c.value.position.inMilliseconds;
  }

  @override
  Future<PlaybackStats> stats() async {
    final v = _c?.value;
    if (v == null || !v.isInitialized) return const PlaybackStats();
    return PlaybackStats(
      width: v.size.width.toInt(),
      height: v.size.height.toInt(),
    );
  }

  @override
  Widget view({BoxFit fit = BoxFit.contain}) {
    final c = _c;
    if (c == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: c,
      builder: (context, v, _) {
        if (!v.isInitialized || v.size.isEmpty) return const SizedBox.shrink();
        return FittedBox(
          fit: fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: v.size.width,
            height: v.size.height,
            child: VideoPlayer(c),
          ),
        );
      },
    );
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    await _c?.setVolume(_muted ? 0 : _volume);
  }

  @override
  Future<void> setMuted({required bool muted}) async {
    _muted = muted;
    await _c?.setVolume(muted ? 0 : _volume);
  }

  @override
  Future<Uint8List?> snapshot() async {
    // fvp's snapshot never completes on desktop; the widget capture in
    // CameraPlayer covers it there.
    if (!(Platform.isAndroid || Platform.isIOS)) return null;
    final c = _c;
    if (c == null || !c.value.isInitialized || c.value.size.isEmpty) {
      return null;
    }
    // fvp returns raw RGBA (stride = width*4), not an encoded image.
    // Ask for a small frame and encode it to PNG ourselves.
    final size = c.value.size;
    final w = size.width < 480 ? size.width.round() : 480;
    final h = (w * size.height / size.width).round();
    final rgba = await c.snapshot(width: w, height: h);
    if (rgba == null || rgba.length < w * h * 4) return null;
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    final image = await done.future;
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    final c = _c;
    _c = null;
    await c?.dispose();
  }
}
