// Tests poke into decoded JSON maps; dynamic access is fine here.
// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';

import 'package:camstation/core/engine/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const s = EngineSettings(
    apiPort: 40001,
    rtspPort: 40002,
    webrtcPort: 40003,
    username: 'u',
    password: 'p',
  );
  final cfg = jsonDecode(buildEngineConfig(s)) as Map<String, dynamic>;

  test('every listener is loopback-only', () {
    expect(cfg['api']['listen'], '127.0.0.1:40001');
    expect(cfg['rtsp']['listen'], '127.0.0.1:40002');
    expect(cfg['webrtc']['listen'], '127.0.0.1:40003/udp');
    expect(cfg['srtp']['listen'], '');
  });

  test('API requires auth even on loopback', () {
    expect(cfg['api']['local_auth'], isTrue);
    expect(cfg['api']['username'], 'u');
    expect(cfg['api']['password'], 'p');
  });

  test('no web UI, no config endpoint, no ws', () {
    final paths = (cfg['api']['allow_paths'] as List).cast<String>();
    expect(paths, isNot(contains('/')));
    expect(paths, isNot(contains('/api/config')));
    expect(paths, isNot(contains('/api/ws')));
  });

  test('dangerous modules are not loaded', () {
    final mods = (cfg['app']['modules'] as List).cast<String>();
    const banned = ['exec', 'ffmpeg', 'echo', 'expr', 'webtorrent', 'hass'];
    for (final bad in banned) {
      expect(mods, isNot(contains(bad)));
    }
    expect(mods, containsAll(['api', 'rtsp', 'webrtc', 'dvrip', 'onvif']));
  });

  test('WebRTC: no STUN, loopback candidates allowed', () {
    expect(cfg['webrtc']['ice_servers'], isEmpty);
    expect(cfg['webrtc']['filters']['loopback'], isTrue);
  });

  test('config holds no camera streams', () {
    expect(cfg.containsKey('streams'), isFalse);
  });

  test('random tokens are url-safe and unique', () {
    final a = randomToken();
    final b = randomToken();
    expect(a, isNot(b));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
    expect(a.length, greaterThanOrEqualTo(21));
  });
}
