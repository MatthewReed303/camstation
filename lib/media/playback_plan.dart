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
  bool webrtcCanDecodeH264High = true,
}) {
  // libwebrtc's desktop H.264 decoder crashes the whole app on non-4:2:0
  // streams (High 10 / 4:2:2 / 4:4:4; go2rtc reports those as raw codes
  // like "0xF4"). Normal Baseline/Main/High play fine. Never offer WebRTC
  // for the exotic ones, whatever the preference.
  final h264High = codecs.any(
    (c) =>
        c.name.toLowerCase() == 'h264' &&
        (c.profile?.toLowerCase().startsWith('0x') ?? false),
  );
  if (h264High && !webrtcCanDecodeH264High) return const [PlayerMode.rtsp];

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
