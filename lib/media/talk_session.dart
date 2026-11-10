import 'dart:async';

import 'package:camstation/core/engine/go2rtc_api.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Push-to-talk: a separate WebRTC connection that only exists while the
/// user holds the talk button.
///
/// go2rtc claims the camera's talk session as soon as the peer connection
/// connects, so we only connect on press and close on
/// release. Audio must be **sendrecv** — a sendonly-audio offer is treated
/// by go2rtc's HTTP endpoint as an ingest producer, not a consumer.
/// go2rtc forces the codec to what the camera wants (PCMA/8000 for DVRIP).
class TalkSession {
  TalkSession({required this.api, required this.talkStreamName});

  final Go2rtcApi api;
  final String talkStreamName;

  RTCPeerConnection? _pc;
  MediaStream? _mic;

  bool get active => _pc != null;

  bool _cancelled = false;

  Future<void> start() async {
    if (_pc != null) return;
    _cancelled = false;
    final mic = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    _mic = mic;
    if (_cancelled) {
      await stop();
      return;
    }
    final RTCPeerConnection pc;
    try {
      pc = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': <Object>[],
      });
    } on Object {
      await stop();
      rethrow;
    }
    _pc = pc;
    try {
      await pc.addTransceiver(
        track: mic.getAudioTracks().first,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: [mic],
        ),
      );
      final gathered = Completer<void>();
      pc.onIceGatheringState = (s) {
        if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !gathered.isCompleted) {
          gathered.complete();
        }
      };
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await gathered.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      final local = await pc.getLocalDescription();
      final answer = await api.webrtcAnswer(
        talkStreamName,
        local?.sdp ?? offer.sdp!,
      );
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    } on Object {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _cancelled = true;
    final pc = _pc;
    final mic = _mic;
    _pc = null;
    _mic = null;
    for (final t in mic?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await mic?.dispose();
    await pc?.close();
    await pc?.dispose();
  }
}
