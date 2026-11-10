import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camstation/core/engine/go2rtc_api.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:camstation/media/player_backend.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Receive-only WebRTC playback from go2rtc.
///
/// Signalling: one HTTP POST of a fully-gathered offer to /api/webrtc
///. No STUN/TURN: everything is on 127.0.0.1.
class WebRtcPlayer implements PlayerBackend {
  WebRtcPlayer({required this.api, required this.streamName});

  final Go2rtcApi api;
  final String streamName;

  RTCPeerConnection? _pc;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _rendererReady = false;
  bool _disposed = false;
  bool _negotiating = false;
  MediaStreamTrack? _audio;
  MediaStreamTrack? _video;
  double _volume = 1;
  bool _muted = false;

  @override
  PlayerMode get mode => PlayerMode.webrtc;

  /// Highest volume [setVolume] accepts (1 = as received).
  static const maxVolume = 2.0;

  /// Call once at start-up, before any connection. flutter_webrtc on
  /// Android defaults to *voice call* audio: the quieter call volume and
  /// phone-call routing. Camera sound is media: play it on the media stream
  /// so it is as loud as any video app and follows the media volume.
  static Future<void> configureAudio() async {
    if (!Platform.isAndroid) return;
    try {
      await WebRTC.initialize(
        options: {
          'androidAudioConfiguration': AndroidAudioConfiguration.media.toMap(),
        },
      );
      await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration.media,
      );
    } on Object {
      // Keep the defaults: quieter, but sound still plays.
    }
  }

  @override
  Future<void> open() async {
    await _renderer.initialize();
    _rendererReady = true;
    if (_disposed) {
      await _close();
      throw StateError('closed while opening');
    }

    final pc = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': <Object>[],
    });
    if (_disposed) {
      // Closed while we were creating it: nobody else will close this one.
      await pc.close();
      await pc.dispose();
      await _close();
      throw StateError('closed while opening');
    }
    _pc = pc;

    // Listeners go on *before* negotiation: on loopback the connection can
    // complete before setRemoteDescription returns, and a late listener
    // misses it (it timed out at 10 s and dropped a working stream).
    var failed = false;
    pc
      ..onTrack = (e) {
        if (e.streams.isNotEmpty) _renderer.srcObject = e.streams.first;
        if (e.track.kind == 'audio') {
          _audio = e.track;
          unawaited(_applyAudio());
        } else {
          _video = e.track;
        }
      }
      ..onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          failed = true;
        }
      }
      ..onIceConnectionState = (s) {
        if (s == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          failed = true;
        }
      };

    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    final offer = await _completeOffer(pc);
    if (_disposed) {
      await _close(); // nothing sent to the engine yet
      throw StateError('closed while opening');
    }
    // From here the engine has its side of the call. If the screen closes
    // now, a half-made call would hold the camera stream until the engine's
    // ICE timeout, so dispose() leaves the hang-up to us (below).
    _negotiating = true;
    try {
      final answer = await api.webrtcAnswer(streamName, offer);
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    } on Object {
      _negotiating = false;
      if (_disposed) await _close();
      rethrow;
    }
    if (_disposed) {
      // Let it connect (sound stays off), then hang up properly so the
      // engine releases the camera straight away.
      final until = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(until) && !failed) {
        if (await progress() > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _negotiating = false;
      await _close();
      throw StateError('closed while opening');
    }
    _negotiating = false;

    // Ready = the first video frame is decoded. That is what the user sees,
    // and it doesn't depend on connection-state events, which flutter_webrtc
    // desktop doesn't reliably deliver.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) throw StateError('closed while opening');
      if (failed) throw StateError('WebRTC connection failed');
      if (((await stats()).framesDecoded ?? 0) > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('WebRTC: no video within 10 s');
  }

  /// Creates the offer and waits for ICE gathering, so the single HTTP POST
  /// carries every candidate (go2rtc's HTTP endpoint has no trickle).
  static Future<String> _completeOffer(RTCPeerConnection pc) async {
    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    // Host candidates only: gathering is near-instant; cap it anyway.
    await gathered.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    final local = await pc.getLocalDescription();
    return local?.sdp ?? offer.sdp!;
  }

  @override
  Future<int> progress() async {
    final pc = _pc;
    if (pc == null) return 0;
    var total = 0;
    for (final r in await pc.getStats()) {
      if (r.type == 'inbound-rtp') {
        final v = r.values['bytesReceived'];
        if (v is num) total += v.toInt();
      }
    }
    return total;
  }

  @override
  Future<PlaybackStats> stats() async {
    final pc = _pc;
    if (pc == null) return const PlaybackStats();
    int? i(Object? v) => v is num ? v.toInt() : null;
    for (final r in await pc.getStats()) {
      final v = r.values;
      if (r.type == 'inbound-rtp' && (v['kind'] ?? v['mediaType']) == 'video') {
        return PlaybackStats(
          framesDecoded: i(v['framesDecoded']),
          keyFramesDecoded: i(v['keyFramesDecoded']),
          width: i(v['frameWidth']),
          height: i(v['frameHeight']),
          fps: (v['framesPerSecond'] as num?)?.toDouble(),
          bytesReceived: i(v['bytesReceived']),
          pliCount: i(v['pliCount']),
          packetsLost: i(v['packetsLost']),
        );
      }
    }
    return const PlaybackStats();
  }

  @override
  Widget view({BoxFit fit = BoxFit.contain}) => RTCVideoView(
    _renderer,
    objectFit: fit == BoxFit.cover
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
  );

  Future<void> _applyAudio() async {
    final a = _audio;
    if (a == null) return;
    a.enabled = !_muted && !_disposed;
    try {
      await Helper.setVolume(_volume, a);
    } on Object {
      // Per-track volume is unsupported on some platforms;
      // mute still works via `enabled`.
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    // WebRTC track gain goes above 1: up to 2 = a 2× boost for quiet
    // cameras.
    _volume = volume.clamp(0, maxVolume);
    await _applyAudio();
  }

  @override
  Future<void> setMuted({required bool muted}) async {
    _muted = muted;
    await _applyAudio();
  }

  @override
  Future<Uint8List?> snapshot() async {
    // flutter_webrtc's captureFrame crashes the whole app on Linux/Windows
    // with HD frames: let CameraPlayer capture the rendered widget instead.
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      return null;
    }
    final v = _video;
    if (v == null) return null;
    final buf = await v.captureFrame();
    return buf.asUint8List();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    try {
      _audio?.enabled = false; // silence first, whatever happens next
    } on Object {
      // already gone
    }
    // Mid-handshake: open() completes it and hangs up (see there).
    if (_negotiating) return;
    await _close();
  }

  /// Closes the connection and the renderer. Each step on its own: if one
  /// throws, the others must still run, or the sound plays on after the
  /// screen is gone.
  Future<void> _close() async {
    final pc = _pc;
    _pc = null;
    _audio = null;
    _video = null;
    try {
      await pc?.close();
    } on Object {
      // already closed
    }
    try {
      await pc?.dispose();
    } on Object {
      // already disposed
    }
    if (_rendererReady) {
      _rendererReady = false;
      try {
        _renderer.srcObject = null;
        await _renderer.dispose();
      } on Object {
        // renderer already released
      }
    }
  }
}
