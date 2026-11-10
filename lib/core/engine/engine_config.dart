import 'dart:convert';
import 'dart:math';

/// Per-launch engine settings: random loopback ports and random credentials.
class EngineSettings {
  const EngineSettings({
    required this.apiPort,
    required this.rtspPort,
    required this.webrtcPort,
    required this.username,
    required this.password,
  });

  final int apiPort;
  final int rtspPort;
  final int webrtcPort;
  final String username;
  final String password;

  Uri get apiBase => Uri(scheme: 'http', host: '127.0.0.1', port: apiPort);

  /// Loopback RTSP URL for the fallback player. go2rtc never authenticates
  /// loopback RTSP clients, so stream names are unguessable
  /// tokens instead.
  String rtspUrl(String streamName) => 'rtsp://127.0.0.1:$rtspPort/$streamName';
}

/// go2rtc modules CamStation needs. Everything else (exec, ffmpeg, echo,
/// expr, webtorrent, hass, homekit, srtp, ...) stays unloaded.
const engineModules = <String>[
  'api',
  'ws',
  'rtsp',
  'webrtc',
  'mp4',
  'onvif',
  'dvrip',
  // Extra source types for "Stream URL" cameras. Source-only: rtmp's
  // server stays off (listen: '').
  'http',
  'rtmp',
  'isapi',
  'tapo',
];

/// Only these API paths exist. No web UI (`/`), no `/api/config`.
const engineAllowPaths = <String>[
  '/api',
  '/api/streams',
  '/api/webrtc',
  '/api/frame.mp4',
  '/api/exit',
];

/// Builds the inline go2rtc config. It is passed as `-c '<json>'` so go2rtc
/// has no config file and can never write camera URLs to disk. It contains no camera streams: those are registered at
/// runtime through the API.
String buildEngineConfig(EngineSettings s) => jsonEncode({
  'app': {'modules': engineModules},
  'api': {
    'listen': '127.0.0.1:${s.apiPort}',
    'username': s.username,
    'password': s.password,
    // Without this, loopback requests skip auth and any other app on the
    // device could drive the engine.
    'local_auth': true,
    'allow_paths': engineAllowPaths,
  },
  'rtsp': {'listen': '127.0.0.1:${s.rtspPort}'},
  'webrtc': {
    'listen': '127.0.0.1:${s.webrtcPort}/udp',
    // Default STUN servers stall every answer when offline.
    'ice_servers': <Object>[],
    'filters': {
      'loopback': true,
      'ips': ['127.0.0.1'],
      'networks': ['udp4'],
    },
  },
  'srtp': {'listen': ''},
  'rtmp': {'listen': ''},
  'log': {'level': 'info', 'format': 'text', 'output': 'stdout', 'time': ''},
});

/// URL-safe random token, used for credentials and stream names.
String randomToken([int bytes = 16]) {
  final r = Random.secure();
  return base64Url
      .encode(List<int>.generate(bytes, (_) => r.nextInt(256)))
      .replaceAll('=', '');
}
