import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/stream_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const dvrip = Camera(
    id: 'c1',
    name: 'Front',
    host: '192.168.1.20',
    source: SourceKind.dvrip,
    supportsTalk: true,
  );

  group('DVRIP', () {
    test('media over DVRIP: main = subtype 0, sub = subtype 1', () {
      expect(StreamSources.media(dvrip, '', StreamQuality.main), [
        'dvrip://admin:@192.168.1.20:34567?channel=0&subtype=0',
      ]);
      expect(
        StreamSources.media(dvrip, '', StreamQuality.sub).single,
        endsWith('subtype=1'),
      );
    });

    test(
      'media via the camera RTSP server uses the credential-in-path form',
      () {
        final cam = dvrip.copyWith(dvripMediaViaRtsp: true, channel: 2);
        expect(StreamSources.media(cam, '', StreamQuality.main), [
          'rtsp://192.168.1.20:554/user=admin&password=&channel=3&stream=0.sdp',
        ]);
        expect(
          StreamSources.media(cam, '', StreamQuality.sub).single,
          endsWith('stream=1.sdp'),
        );
      },
    );

    test('talk is a separate DVRIP backchannel source', () {
      expect(StreamSources.talk(dvrip, ''), [
        'dvrip://admin:@192.168.1.20:34567?channel=0&subtype=0&backchannel=1',
      ]);
      expect(
        StreamSources.talk(dvrip.copyWith(supportsTalk: false), ''),
        isNull,
      );
    });
  });

  test('special characters never leak a raw # (go2rtc param marker)', () {
    final dv = StreamSources.media(
      dvrip,
      'p@ss#w:rd',
      StreamQuality.sub,
    ).single;
    expect(dv, isNot(contains('#')));
    expect(dv, startsWith('dvrip://admin:p%40ss%23w%3Ard@192.168.1.20:34567'));

    final rt = StreamSources.media(
      dvrip.copyWith(dvripMediaViaRtsp: true),
      'a&b#c',
      StreamQuality.main,
    ).single;
    expect(rt, contains('password=a%26b%23c&channel=1'));
    expect(rt, isNot(contains('#')));
  });

  test('ONVIF picks profile 0 for main, 1 for sub', () {
    final cam = dvrip.copyWith(source: SourceKind.onvif, onvifPort: 8899);
    expect(StreamSources.media(cam, 'pw', StreamQuality.sub), [
      'onvif://admin:pw@192.168.1.20:8899?subtype=1',
    ]);
  });

  group('URL kinds', () {
    const rtsp = Camera(
      id: 'c2',
      name: 'Generic',
      host: '10.0.0.5',
      source: SourceKind.rtsp,
      username: 'viewer',
      urlMain: 'rtsp://10.0.0.5:554/Streaming/101',
    );

    test('credentials are injected; sub falls back to main', () {
      expect(StreamSources.media(rtsp, 'pw', StreamQuality.sub), [
        'rtsp://viewer:pw@10.0.0.5:554/Streaming/101',
      ]);
    });

    test('stream URL kind works for other schemes', () {
      final cam = rtsp.copyWith(
        source: SourceKind.url,
        urlMain: 'https://10.0.0.5/video.mjpg',
      );
      expect(StreamSources.media(cam, 'pw', StreamQuality.main), [
        'https://viewer:pw@10.0.0.5/video.mjpg',
      ]);
    });

    test('validateUrl accepts supported schemes only', () {
      for (final ok in [
        'rtsp://1.2.3.4/a',
        'rtsps://1.2.3.4/a',
        'rtmp://1.2.3.4/live/x',
        'https://1.2.3.4/x.m3u8',
        'isapi://1.2.3.4/',
        'tapo://1.2.3.4',
        'tcp://127.0.0.1:9100',
      ]) {
        expect(StreamSources.validateUrl(ok), isNull, reason: ok);
      }
      for (final bad in [
        'exec:ffmpeg -i x',
        'ffmpeg:rtsp://x',
        'echo:hi',
        'nonsense',
        'ftp://1.2.3.4/x',
      ]) {
        expect(StreamSources.validateUrl(bad), isNotNull, reason: bad);
      }
    });
  });

  group('Camera json', () {
    test('round-trips', () {
      final c = dvrip.copyWith(dvripMediaViaRtsp: true);
      expect(Camera.fromJson(c.toJson()), c);
    });
  });
}
