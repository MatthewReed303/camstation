import 'dart:typed_data';

import 'package:camstation/media/playback_plan.dart';
import 'package:flutter/widgets.dart';

/// Live numbers for the info overlay and diagnostics. Null = unknown.
class PlaybackStats {
  const PlaybackStats({
    this.framesDecoded,
    this.width,
    this.height,
    this.fps,
    this.bytesReceived,
    this.keyFramesDecoded,
    this.pliCount,
    this.packetsLost,
  });

  final int? framesDecoded;
  final int? width;
  final int? height;
  final double? fps;
  final int? bytesReceived;
  final int? keyFramesDecoded;
  final int? pliCount;
  final int? packetsLost;

  bool get hasPicture => (width ?? 0) > 0 && (framesDecoded ?? 1) > 0;

  @override
  String toString() =>
      'frames=$framesDecoded key=$keyFramesDecoded ${width}x$height '
      'fps=${fps?.toStringAsFixed(1)} bytes=$bytesReceived '
      'pli=$pliCount lost=$packetsLost';
}

/// One concrete way of playing a go2rtc stream (WebRTC or RTSP/fvp).
/// Screens never use this directly; they go through `CameraPlayer`.
abstract class PlayerBackend {
  PlayerMode get mode;

  /// Connects and starts playback. Throws on failure.
  Future<void> open();

  /// A monotonically increasing progress counter (bytes received, frames
  /// decoded, or position in ms). The watchdog reconnects when it stalls.
  Future<int> progress();

  Future<PlaybackStats> stats();

  Widget view({BoxFit fit = BoxFit.contain});

  Future<void> setVolume(double volume);
  Future<void> setMuted({required bool muted});

  /// PNG/JPEG bytes of the current frame, or null if unavailable.
  Future<Uint8List?> snapshot();

  Future<void> dispose();
}
