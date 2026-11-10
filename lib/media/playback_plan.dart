import 'package:camstation/core/engine/go2rtc_api.dart';

enum PlayerMode {
  /// flutter_webrtc against go2rtc (lowest latency, two-way audio).
  webrtc,

  /// fvp (libmdk) playing go2rtc's loopback RTSP re-stream: H.265 on
  /// desktop, AAC audio.
  rtsp,
}

enum PlayerPreference { auto, webrtc, rtsp }

/// Which players to try, in order, for a stream with the given codecs.
///
/// WebRTC can't carry AAC (go2rtc drops it silently) and flutter_webrtc only
/// decodes H.265 on Android/Apple. In those cases RTSP goes
/// first so the user gets picture *and* sound; WebRTC stays as a fallback.
List<PlayerMode> planPlayback({
  required List<CodecInfo> codecs,
  required PlayerPreference preference,
  required bool webrtcCanDecodeH265,
}) {
  switch (preference) {
    case PlayerPreference.webrtc:
      return const [PlayerMode.webrtc, PlayerMode.rtsp];
    case PlayerPreference.rtsp:
      return const [PlayerMode.rtsp, PlayerMode.webrtc];
    case PlayerPreference.auto:
      final names = codecs.map((c) => c.name.toLowerCase()).toSet();
      final h265 = names.contains('hevc') || names.contains('h265');
      final aac = names.contains('aac');
      if (aac || (h265 && !webrtcCanDecodeH265)) {
        return const [PlayerMode.rtsp, PlayerMode.webrtc];
      }
      return const [PlayerMode.webrtc, PlayerMode.rtsp];
  }
}
