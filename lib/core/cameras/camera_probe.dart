import 'dart:async';
import 'dart:io';

import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/stream_sources.dart';
import 'package:camstation/core/discovery/onvif_discovery.dart';
import 'package:camstation/core/engine/engine_config.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/core/engine/go2rtc_api.dart';
import 'package:camstation/core/util/redact.dart';

class ProbeResult {
  const ProbeResult({
    required this.camera,
    this.codecs = const [],
    this.supportsTalk = false,
    this.error,
  });

  /// The exact configuration that was tested (save this one).
  final Camera camera;
  final List<CodecInfo> codecs;
  final bool supportsTalk;
  final String? error;

  bool get hasVideo => codecs.any((c) => c.kind == 'video');
  bool get hasAudio => codecs.any((c) => c.kind == 'audio');
  bool get ok => hasVideo && error == null;

  /// Video + audio + talk scores highest.
  int get score =>
      (hasVideo ? 4 : 0) + (hasAudio ? 2 : 0) + (supportsTalk ? 1 : 0);

  String get summary {
    if (error != null) return error!;
    if (!hasVideo) {
      return hasAudio ? 'Audio only: no video received' : 'No video received';
    }
    final v = codecs.where((c) => c.kind == 'video').join(', ');
    final a = codecs.where((c) => c.kind == 'audio').join(', ');
    return 'Video $v · ${a.isEmpty ? 'no audio' : 'audio $a'}'
        '${supportsTalk ? ' · two-way talk' : ''}';
  }
}

/// Tests camera configurations through the engine before they are saved.
class CameraProbe {
  CameraProbe(this.engine);
  final EngineManager engine;

  /// Probes [cam]'s main stream (the one most likely to break) and its talk
  /// channel. Temporary engine streams are always removed.
  ///
  /// [knownTalk] skips the talk probe: a camera's talk channel can stay busy
  /// for a while after a probe, so it is only tested once per camera.
  Future<ProbeResult> probe(
    Camera cam,
    String password, {
    bool? knownTalk,
  }) async {
    final media = 'probe_${randomToken(8)}';
    final talk = 'probe_${randomToken(8)}';
    try {
      await engine.setStream(
        media,
        StreamSources.media(cam, password, StreamQuality.main),
      );
      final status = await engine.api.streamStatus(media, probe: true);
      final codecs = status?.codecs ?? const <CodecInfo>[];

      var talkOk = knownTalk ?? false;
      final talkSources = knownTalk != null
          ? null
          : StreamSources.talk(cam.copyWith(supportsTalk: true), password);
      if (codecs.isNotEmpty && talkSources != null) {
        try {
          await engine.setStream(talk, talkSources);
          final t = await engine.api.streamStatus(talk, probe: true);
          talkOk = t?.hasBackchannel ?? false;
        } on Object {
          talkOk = false;
        }
      }
      return ProbeResult(
        camera: cam.copyWith(supportsTalk: talkOk),
        codecs: codecs,
        supportsTalk: talkOk,
      );
    } on Go2rtcException catch (e) {
      return ProbeResult(camera: cam, error: _explain(e.message));
    } on TimeoutException {
      return ProbeResult(
        camera: cam,
        error: 'Timed out: camera offline or wrong address?',
      );
    } finally {
      await engine.removeStream(media).catchError((_) {});
      await engine.removeStream(talk).catchError((_) {});
    }
  }

  /// Tries the likely connection types for a host and returns all results,
  /// best first (video required; audio, then talk, preferred). Stops early
  /// once one has everything.
  Future<List<ProbeResult>> autoDetect(Camera cam, String password) async {
    final (dvripOpen, rtspOpen, onvifPort) = await (
      _tcpOpen(cam.host, cam.dvripPort),
      _tcpOpen(cam.host, cam.rtspPort),
      _onvifPort(cam.host),
    ).wait;
    final base = onvifPort == null ? cam : cam.copyWith(onvifPort: onvifPort);
    final candidates = [
      if (dvripOpen) base.copyWith(source: SourceKind.dvrip),
      if (dvripOpen && rtspOpen)
        base.copyWith(source: SourceKind.dvrip, dvripMediaViaRtsp: true),
      base.copyWith(source: SourceKind.onvif),
    ];
    final results = <ProbeResult>[];
    bool? dvripTalk;
    for (final c in candidates) {
      final isDvrip = c.source == SourceKind.dvrip;
      final r = await probe(c, password, knownTalk: isDvrip ? dvripTalk : null);
      if (isDvrip && r.error == null && r.codecs.isNotEmpty) {
        dvripTalk ??= r.supportsTalk;
      }
      results.add(r);
      if (r.score == 7) break;
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  /// Asks the camera itself for its ONVIF service port (unicast
  /// WS-Discovery); null if it doesn't answer.
  static Future<int?> _onvifPort(String host) async {
    try {
      final found = await OnvifDiscovery.scan(
        window: const Duration(milliseconds: 1500),
        hosts: [host],
      );
      for (final d in found) {
        if (d.ip == host) return d.onvifPort;
      }
    } on Object {
      // fall through
    }
    return null;
  }

  static Future<bool> _tcpOpen(String host, int port) async {
    try {
      final s = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 1500),
      );
      s.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  static String _explain(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('401') ||
        m.contains('unauthorized') ||
        m.contains('wrong user') ||
        m.contains('password')) {
      return 'Wrong username or password';
    }
    if (m.contains('timeout') || m.contains('i/o timeout')) {
      return 'Camera did not answer (offline or wrong port?)';
    }
    if (m.contains('wrong subtype') || m.contains('onvif: ')) {
      return 'No ONVIF media profiles: wrong ONVIF port, or ONVIF disabled';
    }
    if (m.contains('connection refused')) {
      return 'Connection refused: wrong port, or the service is disabled';
    }
    return Redactor.redact(raw);
  }
}
