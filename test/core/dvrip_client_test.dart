import 'dart:convert';
import 'dart:typed_data';

import 'package:camstation/core/control/dvrip/dvrip_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sofiaHash matches the value cameras expose for an empty password', () {
    expect(DvripClient.sofiaHash(''), 'tlJwpbo6');
    expect(DvripClient.sofiaHash('admin').length, 8);
  });

  test('encode: 20-byte LE header + JSON + \\n\\0', () {
    final p = DvripClient.encode(0x12345678, 3, 1042, {'Name': 'X'});
    final h = ByteData.sublistView(p);
    expect(h.getUint8(0), 0xFF);
    expect(h.getUint32(4, Endian.little), 0x12345678);
    expect(h.getUint32(8, Endian.little), 3);
    expect(h.getUint16(14, Endian.little), 1042);
    final len = h.getUint32(16, Endian.little);
    expect(p.length, 20 + len);
    expect(p.sublist(p.length - 2), [0x0A, 0x00]);
    expect(utf8.decode(p.sublist(20, p.length - 2)), '{"Name":"X"}');
  });

  test('decodeBody strips terminator and control characters', () {
    final body = [...utf8.encode('{"Ret":100,"Name":"a\u0001b"}'), 0x0A, 0x00];
    expect(DvripClient.decodeBody(body), {'Ret': 100, 'Name': 'ab'});
  });

  test('decodeBody keeps UTF-8 text intact', () {
    final body = utf8.encode('{"ChannelTitle":["Café"]}\n\x00');
    expect(DvripClient.decodeBody(body)['ChannelTitle'], ['Café']);
  });

  test('DvripException classifies auth and lockout', () {
    expect(DvripException(203, 'x').isAuth, isTrue);
    expect(DvripException(205, 'x').isLocked, isTrue);
  });
}
