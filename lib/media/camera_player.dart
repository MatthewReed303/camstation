import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camstation/core/engine/go2rtc_api.dart';
import 'package:camstation/core/util/app_log.dart';
import 'package:camstation/core/util/redact.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:camstation/media/player_backend.dart';
import 'package:camstation/media/stall_watchdog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

enum PlayerStatus { idle, connecting, playing, reconnecting, error }

@immutable
class PlayerState {
  const PlayerState({
    this.status = PlayerStatus.idle,
    this.mode,
    this.codecs = const [],
    this.error,
    this.attempt = 0,
  });

  final PlayerStatus status;
  final PlayerMode? mode;
  final List<CodecInfo> codecs;
  final String? error;
  final int attempt;

  PlayerState copyWith({
    PlayerStatus? status,
    PlayerMode? mode,
    List<CodecInfo>? codecs,
    String? error,
    int? attempt,
  }) => PlayerState(
    status: status ?? this.status,
    mode: mode ?? this.mode,
    codecs: codecs ?? this.codecs,
    error: error,
    attempt: attempt ?? this.attempt,
  );
}

/// Creates a backend for a stream; injectable for tests.
typedef BackendFactory = PlayerBackend Function(
  PlayerMode mode,
  String streamName,
);

/// The one player screens use. Hides WebRTC vs RTSP, falls back
/// automatically, reconnects on stalls with backoff, and guarantees that a
/// slow old connection can never replace a newer one (single-flight).
class CameraPlayer {
  CameraPlayer({
    required this.api,
    required this.createBackend,
    this.preference = PlayerPreference.auto,
  });

  final Go2rtcApi Function() api;
  final BackendFactory createBackend;
  PlayerPreference preference;

  final ValueNotifier<PlayerState> state = ValueNotifier(const PlayerState());

  /// Rebuilds when the active backend changes (the view widget changes).
  final ValueNotifier<PlayerBackend?> backend = ValueNotifier(null);

  String? _stream;
  int _generation = 0;
  StallWatchdog? _watchdog;
  Timer? _retry;
  double _volume = 1;
  bool _muted = false;
  bool _disposed = false;

  /// Stream name → codecs seen by the last probe (process lifetime).
  static final Map<String, List<CodecInfo>> _codecCache = {};

  /// Forget cached codecs, e.g. after camera settings change.
  static void forgetCodecs(String streamName) => _codecCache.remove(streamName);

  static bool get webrtcCanDecodeH265 =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Plays [streamName]. Cancels anything in flight.
  Future<void> play(String streamName) {
    _stream = streamName;
    state.value = const PlayerState(status: PlayerStatus.connecting);
    return _connect(attempt: 0);
  }

  Future<void> _connect({required int attempt}) async {
    final gen = ++_generation;
    _retry?.cancel();
    _watchdog?.stop();
    await _swap(null);
    final name = _stream;
    if (name == null || _disposed) return;

    // The codec probe costs ~1.3 s; cache it so re-opening a camera (or
    // switching back to a quality) starts the player straight away.
    var codecs = _codecCache[name] ?? const <CodecInfo>[];
    if (codecs.isEmpty) {
      try {
        codecs =
            (await api().streamStatus(name, probe: true))?.codecs ?? const [];
        if (codecs.isNotEmpty) _codecCache[name] = codecs;
      } on Object {
        // Probe failure isn't fatal: try playing anyway.
      }
    }
    if (gen != _generation) return;

    AppLog.add(
      'player',
      '$name: codecs ${codecs.isEmpty ? 'unknown' : codecs.join(', ')}',
    );
    final plan = planPlayback(
      codecs: codecs,
      preference: preference,
      webrtcCanDecodeH265: webrtcCanDecodeH265,
    );

    Object? lastError;
    for (final mode in plan) {
      final b = createBackend(mode, name);
      final t = Stopwatch()..start();
      try {
        await b.open();
      } on Object catch (e) {
        AppLog.add(
          'player',
          '$name: ${mode.name} failed after ${t.elapsedMilliseconds} ms: $e',
        );
        lastError = e;
        await b.dispose();
        if (gen != _generation) return;
        continue;
      }
      if (gen != _generation || _disposed) {
        await b.dispose(); // superseded while connecting
        return;
      }
      await b.setVolume(_volume);
      await b.setMuted(muted: _muted);
      await _swap(b);
      AppLog.add(
        'player',
        '$name: playing via ${mode.name} (${t.elapsedMilliseconds} ms)',
      );
      state.value = PlayerState(
        status: PlayerStatus.playing,
        mode: mode,
        codecs: codecs,
      );
      _watch(b, gen);
      return;
    }

    if (gen != _generation) return;
    _scheduleRetry(attempt + 1, lastError);
  }

  void _watch(PlayerBackend b, int gen) {
    _watchdog = StallWatchdog(
      progress: b.progress,
      onStall: () {
        if (gen != _generation) return;
        _scheduleRetry(1, 'no data for 10 s');
      },
    )..start();
  }

  void _scheduleRetry(int attempt, Object? error) {
    if (_disposed) return;
    AppLog.add('player', '$_stream: retry #$attempt after: $error');
    const delays = [1, 2, 4, 8, 15, 30];
    final secs = delays[(attempt - 1).clamp(0, delays.length - 1)];
    state.value = state.value.copyWith(
      status: attempt > 3 ? PlayerStatus.error : PlayerStatus.reconnecting,
      error: Redactor.redact('${error ?? 'unknown error'}'),
      attempt: attempt,
    );
    _retry = Timer(Duration(seconds: secs), () {
      if (!_disposed) unawaited(_connect(attempt: attempt));
    });
  }

  Future<void> _swap(PlayerBackend? next) async {
    final old = backend.value;
    backend.value = next;
    if (old != null && !identical(old, next)) await old.dispose();
  }

  Future<void> setVolume(double v) async {
    _volume = v;
    await backend.value?.setVolume(v);
  }

  Future<void> setMuted({required bool muted}) async {
    _muted = muted;
    await backend.value?.setMuted(muted: muted);
  }

  bool get muted => _muted;
  double get volume => _volume;

  final GlobalKey _boundary = GlobalKey();

  /// Current frame as PNG: the player's own capture when it has one,
  /// otherwise a capture of the rendered video widget (works for every
  /// backend and platform).
  Future<Uint8List?> snapshot() async {
    final b = backend.value;
    if (b == null) return null;
    try {
      final png = await b.snapshot().timeout(const Duration(seconds: 2));
      if (png != null && _isEncodedImage(png)) return png;
    } on Object {
      // fall through to the widget capture
    }
    return _captureView();
  }

  /// PNG or JPEG (flutter_webrtc on Android returns JPEG; fvp returns raw
  /// pixels, which RtspPlayer encodes to PNG).
  static bool _isEncodedImage(Uint8List b) =>
      b.length > 8 &&
      ((b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) ||
          (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF));

  Future<Uint8List?> _captureView() async {
    final ro = _boundary.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize || ro.size.isEmpty) {
      return null;
    }
    final image = await ro.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Retry now (e.g. user tapped "retry").
  Future<void> reconnect() => _connect(attempt: 0);

  Widget view({BoxFit fit = BoxFit.contain}) => RepaintBoundary(
    key: _boundary,
    child: ValueListenableBuilder<PlayerBackend?>(
      valueListenable: backend,
      builder: (context, b, _) =>
          b == null ? const SizedBox.shrink() : b.view(fit: fit),
    ),
  );

  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    _retry?.cancel();
    _watchdog?.stop();
    await _swap(null);
    state.dispose();
    backend.dispose();
  }
}
