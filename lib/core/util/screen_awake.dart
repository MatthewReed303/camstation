import 'dart:async';

import 'package:camstation/app/providers.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on according to the user's setting. Screens that show
/// video call [watching] while visible; the app calls [apply] when the
/// setting changes or the app comes back to the foreground.
final class ScreenAwake {
  ScreenAwake._();

  static int _watchers = 0;
  static KeepScreenOn _mode = KeepScreenOn.watching;

  static void apply(KeepScreenOn mode) {
    _mode = mode;
    _update();
  }

  /// Call with true when a video screen opens, false when it closes.
  static void watching({required bool on}) {
    _watchers = (_watchers + (on ? 1 : -1)).clamp(0, 1000);
    _update();
  }

  static void _update() {
    final keep = switch (_mode) {
      KeepScreenOn.always => true,
      KeepScreenOn.watching => _watchers > 0,
      KeepScreenOn.off => false,
    };
    unawaited(WakelockPlus.toggle(enable: keep).catchError((Object _) {}));
  }
}
