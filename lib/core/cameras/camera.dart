import 'package:flutter/foundation.dart';

/// How CamStation reaches a camera. Each kind maps to go2rtc sources in
/// `stream_sources.dart`.
enum SourceKind {
  /// DVRIP ("Sofia", TCP 34567). Media over DVRIP, or over the camera's own
  /// RTSP server when [Camera.dvripMediaViaRtsp] is set; two-way audio over
  /// the DVRIP backchannel.
  dvrip,

  /// ONVIF: the engine resolves a media profile to an RTSP URI.
  onvif,

  /// RTSP URL(s) supplied by the user.
  rtsp,

  /// Any other stream URL the engine supports (RTSPS, RTMP, HTTP
  /// MJPEG/MP4/HLS/FLV, ISAPI, Tapo/Kasa/VIGI, ...).
  url;

  String get label => switch (this) {
    SourceKind.dvrip => 'DVRIP',
    SourceKind.onvif => 'ONVIF',
    SourceKind.rtsp => 'RTSP',
    SourceKind.url => 'Stream URL',
  };

  /// Kinds that take user-supplied URLs instead of host/ports.
  bool get usesUrls => this == SourceKind.rtsp || this == SourceKind.url;
}

enum StreamQuality { main, sub }

/// What a camera opens with in live view.
enum StartQuality {
  last('Last used'),
  main('HD'),
  sub('SD');

  const StartQuality(this.label);
  final String label;
}

enum StartAudio {
  last('Last used'),
  on('On'),
  muted('Muted');

  const StartAudio(this.label);
  final String label;
}

/// Screen orientation for live view (phones/tablets).
enum ViewOrientation {
  auto('Auto-rotate'),
  landscape('Landscape'),
  portrait('Portrait');

  const ViewOrientation(this.label);
  final String label;
}

enum StartOrientation {
  last('Last used'),
  auto('Auto'),
  landscape('Landscape'),
  portrait('Portrait');

  const StartOrientation(this.label);
  final String label;
}

enum StartFullscreen {
  last('Last used'),
  on('On'),
  off('Off');

  const StartFullscreen(this.label);
  final String label;
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.firstWhere((v) => v.name == name, orElse: () => fallback);

/// Camera metadata. Never holds the password: that lives in the secret
/// store (see `camera_repository.dart`).
@immutable
class Camera {
  const Camera({
    required this.id,
    required this.name,
    required this.host,
    required this.source,
    this.username = 'admin',
    this.rtspPort = 554,
    this.dvripPort = 34567,
    this.onvifPort = 80,
    this.channel = 0,
    this.dvripMediaViaRtsp = false,
    this.urlMain,
    this.urlSub,
    this.supportsTalk = false,
    this.startQuality = StartQuality.last,
    this.startAudio = StartAudio.last,
    this.startOrientation = StartOrientation.last,
    this.startFullscreen = StartFullscreen.last,
  });

  factory Camera.fromJson(Map<String, Object?> j) {
    final source = j['source'] as String?;
    return Camera(
      id: j['id']! as String,
      name: j['name']! as String,
      host: j['host']! as String,
      source: SourceKind.values.firstWhere(
        (k) => k.name == source,
        orElse: () => SourceKind.rtsp,
      ),
      username: (j['username'] as String?) ?? 'admin',
      rtspPort: (j['rtspPort'] as int?) ?? 554,
      dvripPort: (j['dvripPort'] as int?) ?? 34567,
      onvifPort: (j['onvifPort'] as int?) ?? 80,
      channel: (j['channel'] as int?) ?? 0,
      dvripMediaViaRtsp: (j['dvripMediaViaRtsp'] as bool?) ?? false,
      urlMain: j['urlMain'] as String?,
      urlSub: j['urlSub'] as String?,
      supportsTalk: (j['supportsTalk'] as bool?) ?? false,
      startQuality: _enumByName(
        StartQuality.values,
        j['startQuality'],
        StartQuality.last,
      ),
      startAudio: _enumByName(
        StartAudio.values,
        j['startAudio'],
        StartAudio.last,
      ),
      startOrientation: _enumByName(
        StartOrientation.values,
        j['startOrientation'],
        StartOrientation.last,
      ),
      startFullscreen: _enumByName(
        StartFullscreen.values,
        j['startFullscreen'],
        StartFullscreen.last,
      ),
    );
  }

  /// Random id; also the unguessable prefix of the camera's engine streams.
  final String id;
  final String name;

  /// IP address. Hostnames don't resolve inside the engine on Android.
  final String host;
  final SourceKind source;
  final String username;
  final int rtspPort;
  final int dvripPort;
  final int onvifPort;

  /// 0-based channel (DVR/NVR inputs).
  final int channel;

  /// DVRIP cameras: take video/audio from the camera's RTSP server (DVRIP
  /// stays for two-way audio and settings). Chosen by auto-detect when it
  /// gives a better result than DVRIP media.
  final bool dvripMediaViaRtsp;

  /// For [SourceKind.rtsp]/[SourceKind.url]: stream URLs *without*
  /// credentials; credentials are injected when the stream is registered.
  final String? urlMain;
  final String? urlSub;

  /// The camera accepts two-way audio (found by the Test probe).
  final bool supportsTalk;

  /// Live view opens with this stream / sound (or what was used last).
  final StartQuality startQuality;
  final StartAudio startAudio;
  final StartOrientation startOrientation;
  final StartFullscreen startFullscreen;

  /// "DVRIP · video via RTSP", "ONVIF", ...
  String get connectionSummary => switch (source) {
    SourceKind.dvrip when dvripMediaViaRtsp => 'DVRIP · video via RTSP',
    _ => source.label,
  };

  Camera copyWith({
    String? name,
    String? host,
    SourceKind? source,
    String? username,
    int? rtspPort,
    int? dvripPort,
    int? onvifPort,
    int? channel,
    bool? dvripMediaViaRtsp,
    String? urlMain,
    String? urlSub,
    bool? supportsTalk,
    StartQuality? startQuality,
    StartAudio? startAudio,
    StartOrientation? startOrientation,
    StartFullscreen? startFullscreen,
  }) => Camera(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    source: source ?? this.source,
    username: username ?? this.username,
    rtspPort: rtspPort ?? this.rtspPort,
    dvripPort: dvripPort ?? this.dvripPort,
    onvifPort: onvifPort ?? this.onvifPort,
    channel: channel ?? this.channel,
    dvripMediaViaRtsp: dvripMediaViaRtsp ?? this.dvripMediaViaRtsp,
    urlMain: urlMain ?? this.urlMain,
    urlSub: urlSub ?? this.urlSub,
    supportsTalk: supportsTalk ?? this.supportsTalk,
    startQuality: startQuality ?? this.startQuality,
    startAudio: startAudio ?? this.startAudio,
    startOrientation: startOrientation ?? this.startOrientation,
    startFullscreen: startFullscreen ?? this.startFullscreen,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'source': source.name,
    'username': username,
    'rtspPort': rtspPort,
    'dvripPort': dvripPort,
    'onvifPort': onvifPort,
    'channel': channel,
    'dvripMediaViaRtsp': dvripMediaViaRtsp,
    if (urlMain != null) 'urlMain': urlMain,
    if (urlSub != null) 'urlSub': urlSub,
    'supportsTalk': supportsTalk,
    'startQuality': startQuality.name,
    'startAudio': startAudio.name,
    'startOrientation': startOrientation.name,
    'startFullscreen': startFullscreen.name,
  };

  @override
  bool operator ==(Object other) =>
      other is Camera && mapEquals(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);
}
