import 'package:camstation/core/util/redact.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Redactor', () {
    test('masks URL userinfo', () {
      expect(
        Redactor.redact('dvrip://admin:s3cret@192.168.1.20:34567?channel=0'),
        'dvrip://***@192.168.1.20:34567?channel=0',
      );
    });

    test('masks credential-in-path RTSP password (raw and hashed)', () {
      expect(
        Redactor.redact(
          'rtsp://192.168.1.20:554/user=admin&password=tlJwpbo6&channel=1',
        ),
        'rtsp://192.168.1.20:554/user=admin&password=***&channel=1',
      );
      // go2rtc logs replace & with _ in some messages.
      expect(
        Redactor.redact('user=admin_password=tlJwpbo6_channel=1'),
        'user=admin_password=***_channel=1',
      );
    });

    test('masks Basic auth header', () {
      expect(
        Redactor.redact('Authorization: Basic YWRtaW46cGFzcw=='),
        'Authorization: Basic ***',
      );
    });

    test('masks registered runtime secrets', () {
      Redactor.addSecret('engine-pass-123456');
      expect(
        Redactor.redact('api password engine-pass-123456 ok'),
        'api password *** ok',
      );
      Redactor.removeSecret('engine-pass-123456');
    });

    test('leaves ordinary text alone', () {
      const s = 'streams: codecs not matched: H265';
      expect(Redactor.redact(s), s);
    });
  });
}
