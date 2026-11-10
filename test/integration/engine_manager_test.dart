// Runs the real go2rtc binary. Skipped unless CAMSTATION_GO2RTC points at it:
//   CAMSTATION_GO2RTC=$PWD/engine_bin/linux_amd64/go2rtc flutter test test/integration
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camstation/core/engine/engine_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final bin = Platform.environment['CAMSTATION_GO2RTC'];
  final skip = (bin == null || bin.isEmpty)
      ? 'set CAMSTATION_GO2RTC to run engine integration tests'
      : null;

  late Directory dir;
  late EngineManager engine;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('camstation_engine_');
    engine = EngineManager(runtimeDir: dir);
  });

  tearDown(() async {
    await engine.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> waitFor(bool Function() cond, {int seconds = 20}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!cond()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('waitFor');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test(
    'starts healthy, loopback-only, auth enforced, nothing on disk',
    () async {
      await engine.ensureStarted();
      expect(engine.state.value.isReady, isTrue);
      expect(engine.state.value.version, startsWith('1.9.15'));

      final base = engine.settings.apiBase;
      expect(base.host, '127.0.0.1');

      // local_auth: true → loopback without credentials is refused.
      final anon = await http.get(base.replace(path: '/api'));
      expect(anon.statusCode, 401);

      // allow_paths: the web UI and config editor do not exist.
      final ui = await http.get(
        base.replace(path: '/'),
        headers: {'Authorization': _basic(engine)},
      );
      expect(ui.statusCode, 404);

      await engine.setStream('tok_test', ['rtsp://192.0.2.1:554/none']);
      expect(await engine.api.streamStatus('tok_test'), isNotNull);

      // Inline config only: go2rtc must not have written a config file.
      final files = dir.listSync().map((f) => f.uri.pathSegments.last).toList();
      expect(files.where((f) => f.endsWith('.yaml')), isEmpty);
      expect(files, contains('go2rtc.pid'));
    },
    skip: skip,
  );

  test('restarts after a crash and re-registers streams', () async {
    await engine.ensureStarted();
    await engine.setStream('tok_keep', ['rtsp://192.0.2.1:554/none']);
    final oldPort = engine.settings.apiPort;
    final pid = int.parse(
      File('${dir.path}/go2rtc.pid').readAsStringSync().trim(),
    );

    Process.killPid(pid, ProcessSignal.sigkill);
    await waitFor(() => !engine.state.value.isReady);
    await waitFor(() => engine.state.value.isReady);

    expect(engine.settings.apiPort, isNot(oldPort), reason: 'fresh ports');
    expect(await engine.api.streamStatus('tok_keep'), isNotNull);
  }, skip: skip);

  test('stop() ends the process and closes the port', () async {
    await engine.ensureStarted();
    final base = engine.settings.apiBase;
    await engine.stop();
    expect(engine.state.value.stage, EngineStage.stopped);
    expect(File('${dir.path}/go2rtc.pid').existsSync(), isFalse);
    await expectLater(
      http.get(base.replace(path: '/api')),
      throwsA(isA<SocketException>()),
    );
  }, skip: skip);

  test('kills a stale engine left by a previous app crash', () async {
    await engine.ensureStarted();
    final pid = int.parse(
      File('${dir.path}/go2rtc.pid').readAsStringSync().trim(),
    );
    // Simulate the app dying without stopping the engine: a second manager
    // starting from the same runtime dir must clean it up.
    final second = EngineManager(runtimeDir: dir);
    await second.ensureStarted();
    expect(Directory('/proc/$pid').existsSync(), isFalse);
    await second.dispose();
  }, skip: skip);
}

String _basic(EngineManager e) {
  final s = e.settings;
  return 'Basic ${base64Encode(utf8.encode('${s.username}:${s.password}'))}';
}
