import 'package:flutter/foundation.dart';

/// What a camera lets us change. The settings screen shows only these.
enum ControlFeature { video, audioToggle, image, time, password, reboot, ptz }

@immutable
class DeviceInfo {
  const DeviceInfo({this.model, this.firmware, this.manufacturer, this.name});
  final String? model;
  final String? firmware;
  final String? manufacturer;
  final String? name;
}

/// One encoder stream (main, sub, ...), protocol-neutral.
@immutable
class VideoEncoderConfig {
  const VideoEncoderConfig({
    required this.id,
    required this.label,
    this.codec,
    this.resolution,
    this.fps,
    this.bitrateKbps,
    this.bitrateMode,
    this.gopSeconds,
    this.quality,
    this.audioEnabled,
  });

  /// Opaque id understood by the implementation (e.g. "MainFormat").
  final String id;
  final String label;
  final String? codec; // "H.264", "H.265"
  final String? resolution; // "1080P", "1920x1080", ...
  final int? fps;
  final int? bitrateKbps;
  final String? bitrateMode; // "CBR" | "VBR"
  final int? gopSeconds;
  final int? quality; // 1 (lowest) .. 6 (highest), when supported
  final bool? audioEnabled;

  VideoEncoderConfig copyWith({
    String? codec,
    String? resolution,
    int? fps,
    int? bitrateKbps,
    String? bitrateMode,
    int? gopSeconds,
    int? quality,
    bool? audioEnabled,
  }) => VideoEncoderConfig(
    id: id,
    label: label,
    codec: codec ?? this.codec,
    resolution: resolution ?? this.resolution,
    fps: fps ?? this.fps,
    bitrateKbps: bitrateKbps ?? this.bitrateKbps,
    bitrateMode: bitrateMode ?? this.bitrateMode,
    gopSeconds: gopSeconds ?? this.gopSeconds,
    quality: quality ?? this.quality,
    audioEnabled: audioEnabled ?? this.audioEnabled,
  );
}

/// The values a stream accepts.
@immutable
class VideoEncoderOptions {
  const VideoEncoderOptions({
    this.codecs = const [],
    this.resolutions = const [],
    this.maxFps = 30,
    this.maxBitrateKbps = 16384,
    this.bitrateModes = const ['CBR', 'VBR'],
    this.hasAudio = false,
  });

  final List<String> codecs;
  final List<String> resolutions;
  final int maxFps;
  final int maxBitrateKbps;
  final List<String> bitrateModes;
  final bool hasAudio;
}

/// Image settings. Null fields are unsupported by the camera. Levels are
/// normalised to 0–100.
@immutable
class ImageSettings {
  const ImageSettings({
    this.flip,
    this.mirror,
    this.brightness,
    this.contrast,
    this.saturation,
    this.sharpness,
  });
  final bool? flip;
  final bool? mirror;
  final double? brightness;
  final double? contrast;
  final double? saturation;
  final double? sharpness;

  ImageSettings copyWith({
    bool? flip,
    bool? mirror,
    double? brightness,
    double? contrast,
    double? saturation,
    double? sharpness,
  }) => ImageSettings(
    flip: flip ?? this.flip,
    mirror: mirror ?? this.mirror,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    sharpness: sharpness ?? this.sharpness,
  );
}

enum PtzMove { up, down, left, right, zoomIn, zoomOut }

class ControlException implements Exception {
  ControlException(this.message, {this.isAuth = false});
  final String message;
  final bool isAuth;
  @override
  String toString() => message;
}

/// Camera settings over a control protocol (DVRIP, ONVIF, ...). Open with
/// [connect], always [close].
abstract class CameraControl {
  String get protocol;
  Set<ControlFeature> get features;

  Future<void> connect();
  Future<DeviceInfo> deviceInfo();

  Future<List<VideoEncoderConfig>> encoders();
  Future<VideoEncoderOptions> encoderOptions(String encoderId);

  /// Returns true when the camera must restart for the change to apply.
  Future<bool> setEncoder(VideoEncoderConfig config);

  Future<ImageSettings> image();
  Future<void> setImage(ImageSettings settings);

  Future<DateTime?> time();
  Future<void> setTime(DateTime localTime);

  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  });

  Future<void> reboot();

  Future<void> ptz(PtzMove move, {double speed = 0.5});
  Future<void> ptzStop();

  Future<void> close();
}
