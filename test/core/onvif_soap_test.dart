import 'dart:convert';

import 'package:camstation/core/control/onvif/onvif_soap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('PasswordDigest matches the WS-Security spec example', () {
    // OASIS UsernameToken Profile: Base64(SHA1(nonce + created + password)).
    final nonce = base64.decode('LKqI6G/AikKCQrN0zqZFlg==');
    expect(
      OnvifSoap.digest(nonce, '2010-09-16T07:50:45Z', 'userpassword'),
      'tuOSpGlFlIXsozq4HFNeeGeFLEI=',
    );
  });

  test('isoUtc formats as UTC with Z', () {
    expect(
      OnvifSoap.isoUtc(DateTime.utc(2026, 1, 2, 3, 4, 5)),
      '2026-01-02T03:04:05Z',
    );
  });

  test(
    'call sends auth header and surfaces SOAP faults as auth errors',
    () async {
      late String sent;
      final soap = OnvifSoap(
        username: 'admin',
        password: 'pw',
        client: MockClient((r) async {
          sent = r.body;
          return http.Response(
            '<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
            '<s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value></s:Code>'
            '<s:Reason><s:Text>Not Authorized</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>',
            400,
          );
        }),
      );
      await expectLater(
        soap.call(
          Uri.parse('http://1.2.3.4/onvif/device_service'),
          '<tds:GetUsers/>',
        ),
        throwsA(isA<OnvifFault>().having((f) => f.isAuth, 'isAuth', isTrue)),
      );
      expect(sent, contains('PasswordDigest'));
      expect(sent, contains('<wsse:Username>admin</wsse:Username>'));
      expect(
        sent,
        isNot(contains('>pw<')),
        reason: 'password never sent in clear',
      );
    },
  );
}
