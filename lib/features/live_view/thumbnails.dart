import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camstation/app/providers.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Last frame seen in live view, cached as the camera-list thumbnail.
/// go2rtc's frame.jpeg needs ffmpeg, so thumbnails come from
/// the player instead.
File thumbnailFile(Directory supportDir, String cameraId) =>
    File('${supportDir.path}/thumbs/$cameraId.png');

final thumbnailProvider = FutureProvider.family<File?, String>((ref, id) async {
  final f = thumbnailFile(ref.watch(supportDirProvider), id);
  return f.existsSync() ? f : null;
});

Future<void> saveThumbnail(WidgetRef ref, String id, Uint8List png) async {
  final f = thumbnailFile(ref.read(supportDirProvider), id);
  final small = await _downscale(png, 480);
  await f.parent.create(recursive: true);
  await f.writeAsBytes(small, flush: true);
  // Image.file caches by path: evict so the new frame shows.
  await FileImage(f).evict();
  ref.invalidate(thumbnailProvider(id));
}

/// A 4K frame is a ~33 MB PNG; thumbnails only need a few hundred pixels.
Future<Uint8List> _downscale(Uint8List png, int width) async {
  final codec = await ui.instantiateImageCodec(png, targetWidth: width);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  return data!.buffer.asUint8List();
}

/// Keeps a camera's thumbnail fresh while it plays: first grab a few seconds
/// after playback starts, then every [every]. Leaving the screen therefore
/// always leaves a recent image (a grab during dispose would be too late).
class ThumbnailKeeper {
  ThumbnailKeeper({
    required this.ref,
    required this.cameraId,
    required this.capture,
    this.every = const Duration(seconds: 15),
  });

  final WidgetRef ref;
  final String cameraId;
  final Future<Uint8List?> Function() capture;
  final Duration every;
  Timer? _timer;
  bool _busy = false;

  void onPlaying() {
    if (_timer != null) return;
    _timer = Timer(const Duration(seconds: 3), () {
      unawaited(grab());
      _timer = Timer.periodic(every, (_) => unawaited(grab()));
    });
  }

  void onStopped() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> grab() async {
    if (_busy) return;
    _busy = true;
    try {
      final png = await capture();
      if (png != null) await saveThumbnail(ref, cameraId, png);
    } on Object {
      // best effort
    } finally {
      _busy = false;
    }
  }

  void dispose() => onStopped();
}
