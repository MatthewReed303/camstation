import 'dart:io';

import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/camera_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('cs_store_'));
  tearDown(() => dir.delete(recursive: true));

  test('save/load round-trip, no password on disk', () async {
    final store = CameraStore(File('${dir.path}/cameras.json'));
    expect(await store.load(), isEmpty);
    const cam = Camera(
      id: 'a',
      name: 'Front',
      host: '192.168.1.20',
      source: SourceKind.dvrip,
    );
    await store.save([cam]);
    expect(await store.load(), [cam]);
    final raw = File('${dir.path}/cameras.json').readAsStringSync();
    expect(raw.toLowerCase(), isNot(contains('password')));
    expect(File('${dir.path}/cameras.json.tmp').existsSync(), isFalse);
  });
}
