import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camstation/core/util/redact.dart';
import 'package:http/http.dart' as http;

class Go2rtcException implements Exception {
  Go2rtcException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'Go2rtcException(${statusCode ?? '-'}): ${Redactor.redact(message)}';
}

/// One codec seen on a producer (camera connection).
class CodecInfo {
  const CodecInfo({
    required this.kind,
    required this.name,
    this.sampleRate,
    this.profile,
  });
  final String kind; // 'video' | 'audio'
  final String name; // e.g. 'h264', 'pcm_alaw'
  final int? sampleRate;

  /// H.264/H.265 profile as go2rtc reports it ("Main", "High", ...).
  final String? profile;

  @override
  String toString() => sampleRate == null ? name : '$name/$sampleRate';
}

/// What go2rtc reports for one stream.
class StreamStatus {
  const StreamStatus({required this.producers, required this.consumerCount});

  factory StreamStatus.fromJson(Map<String, Object?> j) {
    final producers = <ProducerStatus>[];
    for (final p in (j['producers'] as List?) ?? const []) {
      producers.add(ProducerStatus.fromJson(p as Map<String, Object?>));
    }
    return StreamStatus(
      producers: producers,
      consumerCount: ((j['consumers'] as List?) ?? const []).length,
    );
  }

  final List<ProducerStatus> producers;
  final int consumerCount;

  List<CodecInfo> get codecs => [for (final p in producers) ...p.codecs];
  bool get hasVideo => codecs.any((c) => c.kind == 'video');
  bool get hasAudio => codecs.any((c) => c.kind == 'audio');

  /// A sendonly audio media on a producer = camera accepts talk audio.
  bool get hasBackchannel => producers.any(
    (p) => p.medias.any((m) => m.startsWith('audio, sendonly')),
  );
}

class ProducerStatus {
  const ProducerStatus({
    required this.medias,
    required this.codecs,
    required this.bytesReceived,
  });

  factory ProducerStatus.fromJson(Map<String, Object?> j) {
    final codecs = <CodecInfo>[];
    for (final r in (j['receivers'] as List?) ?? const []) {
      final c = (r as Map<String, Object?>)['codec'] as Map<String, Object?>?;
      if (c == null) continue;
      codecs.add(
        CodecInfo(
          kind: (c['codec_type'] as String?) ?? '',
          name: (c['codec_name'] as String?) ?? '?',
          sampleRate: c['sample_rate'] as int?,
          profile: c['profile'] as String?,
        ),
      );
    }
    return ProducerStatus(
      medias: [for (final m in (j['medias'] as List?) ?? const []) '$m'],
      codecs: codecs,
      bytesReceived: (j['bytes_recv'] as int?) ?? 0,
    );
  }

  final List<String> medias;
  final List<CodecInfo> codecs;
  final int bytesReceived;
}

/// Typed client for the endpoints CamStation uses.
class Go2rtcApi {
  Go2rtcApi({
    required this.base,
    required String username,
    required String password,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _auth = 'Basic ${base64.encode(utf8.encode('$username:$password'))}';

  final Uri base;
  final http.Client _client;
  final String _auth;

  static const _timeout = Duration(seconds: 10);

  Map<String, String> get _headers => {'Authorization': _auth};

  Uri _u(String path, [List<MapEntry<String, String>> query = const []]) {
    // Build the query by hand: go2rtc needs repeated `src=` keys.
    final q = query
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return base.replace(path: path, query: q.isEmpty ? null : q);
  }

  Never _fail(http.Response r, String what) => throw Go2rtcException(
    '$what: ${r.body.trim()}',
    statusCode: r.statusCode,
  );

  /// `GET /api` — health check. Returns the engine version.
  Future<String> version() async {
    final r = await _client
        .get(_u('/api'), headers: _headers)
        .timeout(_timeout);
    if (r.statusCode != 200) _fail(r, 'GET /api');
    final j = jsonDecode(r.body) as Map<String, Object?>;
    return (j['version'] as String?) ?? '?';
  }

  /// `PUT /api/streams` — create or replace a stream with one or more
  /// sources. With inline-only config go2rtc applies the change in memory and
  /// then answers `400 config file disabled`; that is success.
  Future<void> putStream(String name, List<String> sources) async {
    final r = await _client
        .put(
          _u('/api/streams', [
            MapEntry('name', name),
            for (final s in sources) MapEntry('src', s),
          ]),
          headers: _headers,
        )
        .timeout(_timeout);
    if (_ok(r)) return;
    _fail(r, 'PUT stream');
  }

  /// `DELETE /api/streams?src=NAME` (same 400 quirk as [putStream]).
  Future<void> deleteStream(String name) async {
    final r = await _client
        .delete(_u('/api/streams', [MapEntry('src', name)]), headers: _headers)
        .timeout(_timeout);
    if (_ok(r) || r.statusCode == 404) return;
    _fail(r, 'DELETE stream');
  }

  static bool _ok(http.Response r) =>
      r.statusCode == 200 ||
      (r.statusCode == 400 && r.body.contains('config file disabled'));

  /// `GET /api/streams?src=NAME`. With [probe], go2rtc attaches a temporary
  /// consumer so producers actually connect and report real codecs.
  Future<StreamStatus?> streamStatus(String name, {bool probe = false}) async {
    final r = await _client
        .get(
          _u('/api/streams', [
            MapEntry('src', name),
            if (probe) ...const [
              MapEntry('video', 'all'),
              MapEntry('audio', 'all'),
              MapEntry('microphone', ''),
            ],
          ]),
          headers: _headers,
        )
        .timeout(probe ? const Duration(seconds: 30) : _timeout);
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r, 'GET stream');
    return StreamStatus.fromJson(jsonDecode(r.body) as Map<String, Object?>);
  }

  /// `POST /api/webrtc?src=NAME` with a complete (non-trickle) offer.
  /// Returns the answer SDP.
  Future<String> webrtcAnswer(String name, String offerSdp) async {
    final r = await _client
        .post(
          _u('/api/webrtc', [MapEntry('src', name)]),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'type': 'offer', 'sdp': offerSdp}),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _fail(r, 'WebRTC offer');
    final j = jsonDecode(r.body) as Map<String, Object?>;
    final sdp = j['sdp'] as String?;
    if (sdp == null || sdp.isEmpty) {
      throw Go2rtcException('WebRTC answer without SDP');
    }
    return sdp;
  }

  /// `GET /api/frame.mp4?src=NAME` — one keyframe as MP4, no ffmpeg needed.
  Future<Uint8List> frameMp4(String name) async {
    final r = await _client
        .get(_u('/api/frame.mp4', [MapEntry('src', name)]), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _fail(r, 'GET frame.mp4');
    return r.bodyBytes;
  }

  /// `POST /api/exit` — ask the engine to quit.
  Future<void> exit() async {
    try {
      await _client
          .post(_u('/api/exit'), headers: _headers)
          .timeout(const Duration(seconds: 2));
    } on Object {
      // The process may die before answering; the caller kills it anyway.
    }
  }

  void close() => _client.close();
}
