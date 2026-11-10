import 'package:camstation/features/grid/grid_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auto grid: one column on an upright phone', () {
    expect(gridAutoColumns(393, 4, 2), 1);
  });
  test('auto grid: two on a sideways phone, capped by the phone limit', () {
    expect(gridAutoColumns(851, 4, 2), 2);
    expect(gridAutoColumns(2000, 9, 2), 2);
  });
  test('auto grid: desktop fits more, never more than cameras', () {
    expect(gridAutoColumns(1280, 9, 4), 4);
    expect(gridAutoColumns(1280, 2, 4), 2);
    expect(gridAutoColumns(1280, 0, 4), 1);
  });
}
