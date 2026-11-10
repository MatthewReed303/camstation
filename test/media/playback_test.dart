import 'dart:typed_data';

import 'package:camstation/core/engine/go2rtc_api.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:camstation/media/player_backend.dart';
import 'package:camstation/media/stall_watchdog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const h264 = CodecInfo(kind: 'video', name: 'h264');
const hevc = CodecInfo(kind: 'video', name: 'hevc');
const pcma = CodecInfo(kind: 'audio', name: 'pcm_alaw', sampleRate: 8000);
const aac = CodecInfo(kind: 'audio', name: 'aac');

class FakeBackend implements PlayerBackend {
  FakeBackend(
    this.mode, {
    this.fail = false,
    this.openDelay = Duration.zero,
    this.volumeDelay = Duration.zero,
  });
  @override
  final PlayerMode mode;
  final bool fail;
  final Duration openDelay;
  final Duration volumeDelay;
  bool? lastMuted;
  bool opened = false;
  bool disposed = false;
  int counter = 0;

  @override
  Future<void> open() async {
    await Future<void>.delayed(openDelay);
    if (fail) throw StateError('$mode failed');
    opened = true;
  }

  @override
  Future<int> progress() async => counter;
  @override
  Future<PlaybackStats> stats() async => const PlaybackStats();
  @override
  Widget view({BoxFit fit = BoxFit.contain}) => const SizedBox();
  @override
  Future<void> setVolume(double volume) => Future<void>.delayed(volumeDelay);
  @override
  Future<void> setMuted({required bool muted}) async => lastMuted = muted;
  @override
  Future<Uint8List?> snapshot() async => null;
  @override
  Future<void> dispose() async => disposed = true;
}

Go2rtcApi fakeApi(String codecsJson) => Go2rtcApi(
  base: Uri.parse('http://127.0.0.1:1'),
  username: 'u',
  password: 'p',
  client: MockClient(
    (_) async => http.Response(
      '{"producers":[{"medias":[],"receivers":$codecsJson}]}',
      200,
    ),
  ),
);

const h264pcma =
    '[{"codec":{"codec_name":"h264","codec_type":"video"}},'
    '{"codec":{"codec_name":"pcm_alaw","codec_type":"audio"}}]';

void main() {
  group('planPlayback', () {
    List<PlayerMode> plan(List<CodecInfo> c, {bool h265ok = false}) =>
        planPlayback(
          codecs: c,
          preference: PlayerPreference.auto,
          webrtcCanDecodeH265: h265ok,
        );

    test('H.264 + G.711 → WebRTC first', () {
      expect(plan([h264, pcma]), [PlayerMode.webrtc, PlayerMode.rtsp]);
    });
    test('H.265 on desktop → RTSP first', () {
      expect(plan([hevc, pcma]), [PlayerMode.rtsp, PlayerMode.webrtc]);
    });
    test('H.265 on Android → WebRTC first', () {
      expect(plan([hevc, pcma], h265ok: true).first, PlayerMode.webrtc);
    });
    test('AAC anywhere → RTSP first (WebRTC would drop audio)', () {
      expect(plan([h264, aac], h265ok: true).first, PlayerMode.rtsp);
    });
    test('exotic H.264 (4:4:4 etc.) on desktop → RTSP only; High is fine', () {
      const p444 = CodecInfo(kind: 'video', name: 'h264', profile: '0xF4');
      const high = CodecInfo(kind: 'video', name: 'h264', profile: 'High');
      List<PlayerMode> plan(CodecInfo v) => planPlayback(
        codecs: [v, pcma],
        preference: PlayerPreference.webrtc,
        webrtcCanDecodeH265: false,
        webrtcCanDecodeH264High: false,
      );
      expect(plan(p444), [PlayerMode.rtsp]);
      expect(plan(high).first, PlayerMode.webrtc);
    });

    test('explicit preference wins', () {
      expect(
        planPlayback(
          codecs: [hevc],
          preference: PlayerPreference.webrtc,
          webrtcCanDecodeH265: false,
        ).first,
        PlayerMode.webrtc,
      );
    });
  });

  group('CameraPlayer', () {
    test(
      'falls back to RTSP when WebRTC fails, disposes the failed one',
      () async {
        final made = <FakeBackend>[];
        final p = CameraPlayer(
          api: () => fakeApi(h264pcma),
          createBackend: (mode, _) {
            final b = FakeBackend(mode, fail: mode == PlayerMode.webrtc);
            made.add(b);
            return b;
          },
        );
        await p.play('tok');
        expect(p.state.value.status, PlayerStatus.playing);
        expect(p.state.value.mode, PlayerMode.rtsp);
        expect(made.first.disposed, isTrue);
        expect(made.last.opened && !made.last.disposed, isTrue);
        await p.dispose();
        expect(made.last.disposed, isTrue, reason: 'strict disposal');
      },
    );

    test(
      'single-flight: a slow old connection never replaces a newer one',
      () async {
        final made = <String, FakeBackend>{};
        final p = CameraPlayer(
          api: () => fakeApi(h264pcma),
          createBackend: (mode, name) => made[name] = FakeBackend(
            mode,
            openDelay: name == 'slow'
                ? const Duration(milliseconds: 200)
                : Duration.zero,
          ),
        );
        final first = p.play('slow');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await p.play('fast');
        await first;
        expect(identical(p.backend.value, made['fast']), isTrue);
        expect(made['slow']!.disposed, isTrue);
        await p.dispose();
      },
    );

    test(
      'all backends failing → reconnecting state with redacted error',
      () async {
        final p = CameraPlayer(
          api: () => fakeApi(h264pcma),
          createBackend: (mode, _) => FakeBackend(mode, fail: true),
        );
        await p.play('tok');
        expect(p.state.value.status, PlayerStatus.reconnecting);
        expect(p.state.value.error, isNotNull);
        await p.dispose();
      },
    );
  });

  group('closing the screen stops the sound', () {
    test('closed while connecting: that backend is freed at once', () async {
      final made = <FakeBackend>[];
      final p = CameraPlayer(
        api: () => fakeApi(h264pcma),
        createBackend: (mode, _) {
          final b = FakeBackend(
            mode,
            openDelay: const Duration(milliseconds: 300),
          );
          made.add(b);
          return b;
        },
      );
      final playing = p.play('tok');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await p.dispose();
      expect(made.single.disposed, isTrue, reason: 'not after open ends');
      await playing;
      expect(made.every((b) => b.disposed), isTrue);
    });

    test(
      'closed while volume is applied: backend is not left playing',
      () async {
        final made = <FakeBackend>[];
        final p = CameraPlayer(
          api: () => fakeApi(h264pcma),
          createBackend: (mode, _) {
            final b = FakeBackend(
              mode,
              volumeDelay: const Duration(milliseconds: 200),
            );
            made.add(b);
            return b;
          },
        );
        final playing = p.play('tok');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await p.dispose();
        await playing;
        expect(made, isNotEmpty);
        expect(made.every((b) => b.disposed), isTrue);
      },
    );

    test('talking silences the camera without changing mute', () async {
      final b = FakeBackend(PlayerMode.webrtc);
      final p = CameraPlayer(
        api: () => fakeApi(h264pcma),
        createBackend: (_, _) => b,
      );
      await p.play('tok');
      await p.duck(on: true);
      expect(b.lastMuted, isTrue);
      expect(p.muted, isFalse);
      await p.duck(on: false);
      expect(b.lastMuted, isFalse);
      await p.dispose();
    });
  });

  test(
    'engine down while connecting (phone asleep) → retries, then recovers',
    () async {
      var engineUp = false;
      final p = CameraPlayer(
        api: () => fakeApi(h264pcma),
        createBackend: (mode, _) {
          // The real factory reads engine.api/settings, which throw while the
          // engine is stopped.
          if (!engineUp) throw StateError('engine not running');
          return FakeBackend(mode);
        },
      );
      await p.play('tok');
      expect(p.state.value.status, PlayerStatus.reconnecting);
      engineUp = true;
      p.engineRestarted();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(p.state.value.status, PlayerStatus.playing);
      await p.dispose();
    },
  );

  group('StallWatchdog', () {
    test('fires only after no progress for stallAfter', () async {
      var now = DateTime(2026);
      var value = 0;
      var stalls = 0;
      final w = StallWatchdog(
        progress: () async => value,
        onStall: () => stalls++,
        clock: () => now,
      )..start();
      await w.tick(); // baseline
      value = 100;
      now = now.add(const Duration(seconds: 9));
      await w.tick();
      now = now.add(const Duration(seconds: 9));
      await w.tick(); // 9 s since last change: still fine
      expect(stalls, 0);
      now = now.add(const Duration(seconds: 2));
      await w.tick(); // 11 s without change
      expect(stalls, 1);
      w.stop();
    });

    test('progress errors count as no progress', () async {
      var now = DateTime(2026);
      var stalls = 0;
      final w = StallWatchdog(
        progress: () async => throw StateError('x'),
        onStall: () => stalls++,
        clock: () => now,
      )..start();
      now = now.add(const Duration(seconds: 11));
      await w.tick();
      expect(stalls, 1);
    });
  });
}
