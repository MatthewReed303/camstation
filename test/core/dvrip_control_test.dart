import 'package:camstation/core/control/dvrip/dvrip_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes resolution masks (bit = SDK capture-size enum)', () {
    expect(DvripControl.decodeMask('0x01164000', DvripControl.resolutionBits), [
      '1080P',
      '3M',
      '5M',
      '4M',
      '4K',
    ]);
    expect(DvripControl.decodeMask('0x0000004B', DvripControl.resolutionBits), [
      'D1',
      'HD1',
      'CIF',
      'QVGA',
    ]);
  });

  test('decodes compression masks', () {
    expect(DvripControl.decodeMask('0x00000180', DvripControl.codecBits), [
      'H.264',
      'H.265',
    ]);
  });

  test('bad masks decode to nothing', () {
    expect(DvripControl.decodeMask(null, DvripControl.codecBits), isEmpty);
    expect(DvripControl.decodeMask('zz', DvripControl.codecBits), isEmpty);
  });

  test('every resolution has a size label', () {
    for (final name in DvripControl.resolutionBits.values.where(
      (n) => !n.endsWith('_N'),
    )) {
      expect(DvripControl.resolutionSizes, contains(name), reason: name);
    }
  });
}
