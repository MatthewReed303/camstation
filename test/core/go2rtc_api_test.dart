import 'dart:convert';

import 'package:camstation/core/engine/go2rtc_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<http.Request> seen;

  Go2rtcApi apiWith(http.Response Function(http.Request) handler) {
    seen = [];
    return Go2rtcApi(
      base: Uri.parse('http://127.0.0.1:40001'),
      username: 'u',
      password: 'p',
      client: MockClient((r) async {
        seen.add(r);
        return handler(r);
      }),
    );
  }

  test('sends Basic auth on every call', () async {
    final api = apiWith((_) => http.Response('{"version":"1.9.15"}', 200));
    expect(await api.version(), '1.9.15');
    expect(
      seen.single.headers['Authorization'],
      'Basic ${base64.encode(utf8.encode('u:p'))}',
    );
  });

  test('putStream sends repeated src params and treats the inline-config '
      '400 as success', () async {
    final api = apiWith((_) => http.Response('config file disabled', 400));
    await api.putStream('tok', ['rtsp://a/1', 'dvrip://b?backchannel=1']);
    final q = seen.single.url.query;
    expect(q, contains('name=tok'));
    expect(
      RegExp('src=').allMatches(q).length,
      2,
      reason: 'go2rtc needs one src= per source',
    );
    expect(seen.single.method, 'PUT');
  });

  test('putStream surfaces real errors', () async {
    final api = apiWith((_) => http.Response('wrong source', 400));
    expect(
      () => api.putStream('x', ['bad://']),
      throwsA(isA<Go2rtcException>()),
    );
  });

  test('webrtcAnswer posts JSON offer and returns answer sdp', () async {
    final api = apiWith((r) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['type'], 'offer');
      expect(r.headers['Content-Type'], startsWith('application/json'));
      return http.Response('{"type":"answer","sdp":"v=0 answer"}', 200);
    });
    expect(await api.webrtcAnswer('tok', 'v=0 offer'), 'v=0 answer');
    expect(seen.single.url.queryParameters['src'], 'tok');
  });

  test('streamStatus parses codecs and backchannel', () async {
    const body = '''
{"producers":[
  {"url":"rtsp://x","medias":["video, recvonly, H264","audio, recvonly, PCMA/8000"],
   "receivers":[{"codec":{"codec_name":"h264","codec_type":"video"}},
                {"codec":{"codec_name":"pcm_alaw","codec_type":"audio","sample_rate":8000}}],
   "bytes_recv":1234},
  {"url":"dvrip://y","medias":["audio, sendonly, PCMA/8000"]}
],"consumers":[{}]}''';
    final api = apiWith((_) => http.Response(body, 200));
    final s = (await api.streamStatus('tok', probe: true))!;
    expect(s.hasVideo, isTrue);
    expect(s.hasAudio, isTrue);
    expect(s.hasBackchannel, isTrue);
    expect(s.codecs.map((c) => '$c'), ['h264', 'pcm_alaw/8000']);
    expect(s.consumerCount, 1);
    expect(seen.single.url.query, contains('microphone'));
  });

  test('streamStatus returns null for unknown stream', () async {
    final api = apiWith((_) => http.Response('', 404));
    expect(await api.streamStatus('nope'), isNull);
  });

  test('error messages are redacted', () {
    final e = Go2rtcException('dial dvrip://admin:secret@1.2.3.4 failed');
    expect('$e', isNot(contains('secret')));
  });
}
