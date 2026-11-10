import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:camstation/core/engine/engine_binary.dart';
import 'package:camstation/core/engine/engine_config.dart';
import 'package:camstation/core/engine/go2rtc_api.dart';
import 'package:camstation/core/util/redact.dart';
import 'package:flutter/foundation.dart';

enum EngineStage { stopped, starting, running, restarting, failed }

@immutable
class EngineState {
  const EngineState(this.stage, {this.error, this.version});
  final EngineStage stage;
  final String? error;
  final String? version;

  bool get isReady => stage == EngineStage.running;
}

/// Runs go2rtc as a child process bound to 127.0.0.1.
///
/// Responsibilities: pick free ports + random credentials, start the process
/// with an inline config, wait for the health check, capture and redact its
/// logs, restart with backoff on crash, re-register streams after a restart
/// (go2rtc keeps streams in memory only), kill a stale engine left by a
/// previous crash, and stop cleanly.
class EngineManager {
  EngineManager({
    required this.runtimeDir,
    Future<String> Function()? locate,
    Future<Map<String, String>> Function()? environment,
  }) : _locate = locate ?? EngineBinary.locate,
       _environment = environment ?? EngineBinary.environment;

  /// App-private directory for the pidfile and the engine's working dir.
  final Directory runtimeDir;
  final Future<String> Function() _locate;
  final Future<Map<String, String>> Function() _environment;

  /// The environment the next start will use (for tests).
  @visibleForTesting
  Future<Map<String, String>> environmentForTest() => _environment();

  final ValueNotifier<EngineState> _state = ValueNotifier(
    const EngineState(EngineStage.stopped),
  );
  ValueListenable<EngineState> get state => _state;

  final _log = ListQueue<String>();
  static const _logMax = 500;

  /// Redacted engine log lines (most recent last).
  List<String> get logLines => List.unmodifiable(_log);

  Process? _process;
  Go2rtcApi? _api;
  EngineSettings? _settings;
  bool _stopping = false;
  int _restartAttempt = 0;
  Timer? _restartTimer;
  Completer<void>? _starting;
  Future<void>? _stopFuture;

  /// Streams we want to exist: name → sources. Re-applied after restarts.
  final _streams = <String, List<String>>{};

  Go2rtcApi get api => _api ?? (throw StateError('engine not running'));
  EngineSettings get settings =>
      _settings ?? (throw StateError('engine not running'));

  File get _pidFile => File('${runtimeDir.path}/go2rtc.pid');

  /// Starts the engine if needed and completes when it is healthy.
  Future<void> ensureStarted() async {
    final stopping = _stopFuture;
    if (stopping != null) await stopping;
    return _ensureStarted();
  }

  Future<void> _ensureStarted() {
    if (_state.value.isReady) return Future.value();
    final inflight = _starting;
    if (inflight != null) return inflight.future;
    final c = Completer<void>();
    _starting = c;
    _stopping = false;
    unawaited(
      _start()
          .then((_) => c.complete())
          .catchError((Object e, StackTrace st) {
            c.completeError(e, st);
          })
          .whenComplete(() => _starting = null),
    );
    return c.future;
  }

  Future<void> _start() async {
    _set(_restartAttempt == 0 ? EngineStage.starting : EngineStage.restarting);
    try {
      await runtimeDir.create(recursive: true);
      await _killStale();
      final binary = await _locate();

      final s = EngineSettings(
        apiPort: await _freeTcpPort(),
        rtspPort: await _freeTcpPort(),
        webrtcPort: await _freeUdpPort(),
        username: randomToken(9),
        password: randomToken(18),
      );
      Redactor.addSecret(s.password);

      final p = await Process.start(
        binary,
        ['-c', buildEngineConfig(s)],
        workingDirectory: runtimeDir.path,
        environment: await _environment(),
      );
      _process = p;
      await _pidFile.writeAsString('${p.pid}');
      _pipe(p.stdout);
      _pipe(p.stderr);
      unawaited(p.exitCode.then((code) => _onExit(p, code)));

      final api = Go2rtcApi(
        base: s.apiBase,
        username: s.username,
        password: s.password,
      );
      final version = await _waitHealthy(api, p);
      _api = api;
      _settings = s;
      _restartAttempt = 0;
      // Streams first: players reconnect as soon as we report "running".
      for (final e in _streams.entries) {
        await api.putStream(e.key, e.value);
      }
      _set(EngineStage.running, version: version);
    } on Object catch (e) {
      _set(EngineStage.failed, error: Redactor.redact('$e'));
      await _killProcess();
      // Keep trying in the background (e.g. a failed start right after the
      // phone woke up); stop() cancels this.
      if (!_stopping) _scheduleRestart();
      rethrow;
    }
  }

  Future<String> _waitHealthy(Go2rtcApi api, Process p) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var exited = false;
    unawaited(p.exitCode.then((_) => exited = true));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      if (exited) {
        throw StateError('engine exited during start-up: ${_lastLogLines()}');
      }
      try {
        return await api.version();
      } on Object catch (e) {
        lastError = e;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    throw TimeoutException('engine health check failed: $lastError');
  }

  String _lastLogLines() =>
      _log.skip(_log.length > 5 ? _log.length - 5 : 0).join(' | ');

  void _pipe(Stream<List<int>> s) {
    s
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_addLog, onError: (_) {});
  }

  void _addLog(String line) {
    final clean = Redactor.redact(line);
    _log.add(clean);
    while (_log.length > _logMax) {
      _log.removeFirst();
    }
    if (kDebugMode) debugPrint('[go2rtc] $clean');
  }

  void _onExit(Process p, int code) {
    if (!identical(p, _process)) return;
    _process = null;
    _api?.close();
    _api = null;
    // Its ports are dead: players must fail fast and retry, not dial them.
    _settings = null;
    _pidFile.deleteSync2();
    if (_stopping) return;
    _addLog('engine exited with code $code');
    _scheduleRestart();
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();
    final delays = [1, 2, 4, 8, 15, 30];
    final secs = delays[_restartAttempt.clamp(0, delays.length - 1)];
    _restartAttempt++;
    _set(EngineStage.restarting, error: 'engine stopped; retrying in ${secs}s');
    _restartTimer = Timer(Duration(seconds: secs), () {
      if (_stopping) return;
      unawaited(ensureStarted().catchError((_) => _scheduleRestart()));
    });
  }

  /// Registers (or replaces) a stream, remembered across engine restarts.
  Future<void> setStream(String name, List<String> sources) async {
    _streams[name] = List.unmodifiable(sources);
    await ensureStarted();
    await api.putStream(name, sources);
  }

  /// Whether a stream is registered (and re-applied after restarts).
  bool hasStream(String name) => _streams.containsKey(name);

  Future<void> removeStream(String name) async {
    _streams.remove(name);
    if (_state.value.isReady) await api.deleteStream(name);
  }

  /// Stops the engine. Registered streams are kept and re-applied on the
  /// next [ensureStarted] (e.g. on app resume).
  Future<void> stop() async {
    _stopping = true;
    _restartTimer?.cancel();
    // Not "running" from here on, so an ensureStarted() during the stop
    // waits for it and starts a fresh engine instead of returning early.
    _set(EngineStage.stopped);
    final stopping = Completer<void>();
    _stopFuture = stopping.future;
    final pending = _starting;
    if (pending != null) {
      await pending.future.catchError((_) {});
    }
    await _api?.exit();
    await _killProcess();
    _api?.close();
    _api = null;
    final pw = _settings?.password;
    if (pw != null) Redactor.removeSecret(pw);
    _settings = null;
    _set(EngineStage.stopped);
    stopping.complete();
    _stopFuture = null;
  }

  Future<void> _killProcess() async {
    final p = _process;
    if (p == null) return;
    p.kill();
    final code = await p.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -9;
      },
    );
    _addLog('engine stopped (code $code)');
    _process = null;
    _pidFile.deleteSync2();
  }

  /// Kills an engine left running by a previous crash of the app.
  Future<void> _killStale() async {
    if (!_pidFile.existsSync()) return;
    final pid = int.tryParse((await _pidFile.readAsString()).trim());
    _pidFile.deleteSync2();
    if (pid == null) return;
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        final cmd = File('/proc/$pid/cmdline');
        if (cmd.existsSync() && cmd.readAsStringSync().contains('go2rtc')) {
          Process.killPid(pid, ProcessSignal.sigkill);
          _addLog('killed stale engine pid $pid');
        }
      } else if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
        if ('${r.stdout}'.toLowerCase().contains('go2rtc')) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
          _addLog('killed stale engine pid $pid');
        }
      }
    } on Object catch (e) {
      _addLog('stale engine check failed: $e');
    }
  }

  void _set(EngineStage stage, {String? error, String? version}) {
    _state.value = EngineState(stage, error: error, version: version);
  }

  static Future<int> _freeTcpPort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static Future<int> _freeUdpPort() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    s.close();
    return port;
  }

  Future<void> dispose() async {
    await stop();
    _state.dispose();
  }
}

extension on File {
  void deleteSync2() {
    try {
      if (existsSync()) deleteSync();
    } on Object {
      // best effort
    }
  }
}
