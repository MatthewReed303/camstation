import 'package:camstation/core/cameras/camera.dart';

/// Builds the go2rtc source URLs for a camera.
///
/// Rules:
/// - Credentials are percent-encoded, and `#` is always escaped: go2rtc
///   treats a raw `#` as the start of its own `#params`.
/// - The viewing stream never includes a talk backchannel. Talk gets its own
///   stream so the camera's talk session (an extra login on many cameras)
///   is only held while the user is actually talking.
final class StreamSources {
  const StreamSources._();

  /// URL schemes accepted for [SourceKind.url]; each needs its engine module
  /// loaded (see `engine_config.dart`). Command-running sources (exec,
  /// ffmpeg, echo, expr) are never accepted.
  static const supportedSchemes = <String>{
    'rtsp', 'rtsps', 'rtspx', // RTSP (+TLS)
    'rtmp', 'rtmps', 'rtmpx', // RTMP (+TLS)
    'http', 'https', 'httpx', // MJPEG, JPEG, MP4, HLS, FLV, MPEG-TS
    'tcp', // raw MPEG-TS/MJPEG over TCP (encoders, the demo camera)
    'isapi', // Hikvision ISAPI two-way audio
    'tapo', 'kasa', 'vigi', // TP-Link
    'dvrip', 'onvif',
  };

  /// Null if [url] is acceptable for [SourceKind.url], else a reason.
  static String? validateUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.scheme.isEmpty || u.host.isEmpty) {
      return 'Enter a full URL, e.g. rtsp://192.168.1.20:554/stream1';
    }
    if (!supportedSchemes.contains(u.scheme.toLowerCase())) {
      return 'Unsupported type "${u.scheme}://"';
    }
    return null;
  }

  /// Sources for the viewing stream.
  static List<String> media(
    Camera cam,
    String password,
    StreamQuality quality,
  ) {
    final main = quality == StreamQuality.main;
    return switch (cam.source) {
      SourceKind.dvrip when cam.dvripMediaViaRtsp => [
        _sofiaRtsp(cam, password, main: main),
      ],
      SourceKind.dvrip => [_dvrip(cam, password, subtype: main ? 0 : 1)],
      SourceKind.onvif => [_onvif(cam, password, main: main)],
      SourceKind.rtsp || SourceKind.url => [
        _withUserinfo(
          (main ? cam.urlMain : cam.urlSub) ??
              cam.urlMain ??
              (throw ArgumentError('camera ${cam.id} has no stream URL')),
          cam.username,
          password,
        ),
      ],
    };
  }

  /// Sources for the talk (backchannel) stream, or null if not supported.
  static List<String>? talk(Camera cam, String password) {
    if (!cam.supportsTalk) return null;
    return switch (cam.source) {
      SourceKind.dvrip => [
        '${_dvrip(cam, password, subtype: 0)}&backchannel=1',
      ],
      // RTSP/ONVIF/ISAPI/Tapo: go2rtc opens the source's own backchannel on
      // a fresh connection when the camera offers one.
      SourceKind.onvif ||
      SourceKind.rtsp ||
      SourceKind.url => media(cam, password, StreamQuality.sub),
    };
  }

  static String _enc(String s) => Uri.encodeComponent(s);

  static String _userinfo(String user, String pass) =>
      '${_enc(user)}:${_enc(pass)}';

  static String _dvrip(Camera c, String pass, {required int subtype}) =>
      'dvrip://${_userinfo(c.username, pass)}@${c.host}:${c.dvripPort}'
      '?channel=${c.channel}&subtype=$subtype';

  static String _onvif(Camera c, String pass, {required bool main}) =>
      'onvif://${_userinfo(c.username, pass)}@${c.host}:${c.onvifPort}'
      '?subtype=${main ? 0 : 1}';

  /// The RTSP URL form used by DVRIP cameras: credentials, channel (1-based)
  /// and stream index in the path. The camera parses the values raw, so
  /// only characters that would break the URL itself are escaped.
  static String _sofiaRtsp(Camera c, String pass, {required bool main}) {
    String raw(String s) => s
        .replaceAll('%', '%25')
        .replaceAll('&', '%26')
        .replaceAll('#', '%23')
        .replaceAll(' ', '%20');
    return 'rtsp://${c.host}:${c.rtspPort}/user=${raw(c.username)}'
        '&password=${raw(pass)}&channel=${c.channel + 1}'
        '&stream=${main ? 0 : 1}.sdp';
  }

  /// Injects credentials into a user URL, replacing any userinfo in it.
  static String _withUserinfo(String url, String user, String pass) {
    final u = Uri.parse(url.trim());
    if (user.isEmpty && pass.isEmpty) return url.trim().replaceAll('#', '%23');
    return u
        .replace(userInfo: _userinfo(user, pass))
        .toString()
        .replaceAll('#', '%23');
  }
}
