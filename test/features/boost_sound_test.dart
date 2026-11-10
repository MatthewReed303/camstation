import 'dart:io';

import 'package:camstation/app/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Boost camera sound sets the engine voice boost, off removes it',
    () async {
      final dir = await Directory.systemTemp.createTemp('cs_boost_');
      addTearDown(() => dir.delete(recursive: true));
      final c = ProviderContainer(
        overrides: [supportDirProvider.overrideWithValue(dir)],
      );
      addTearDown(c.dispose);

      final engine = c.read(engineProvider);
      expect(c.read(settingsProvider).boostSound, isTrue, reason: 'default on');
      expect((await engine.environmentForTest())['GO2RTC_VOICE_BOOST'], '20');

      final s = c.read(settingsProvider);
      await c
          .read(settingsProvider.notifier)
          .update(s.copyWith(boostSound: false));
      expect(
        (await engine.environmentForTest()).containsKey('GO2RTC_VOICE_BOOST'),
        isFalse,
      );
    },
  );
}
