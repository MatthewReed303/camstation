import 'dart:collection';

import 'package:camstation/core/util/redact.dart';
import 'package:flutter/foundation.dart';

/// Small in-memory log of what the app decided and why (player choices,
/// fallbacks, reconnects). Shown under Settings → Diagnostics so a user can
/// copy it into a bug report. Always redacted.
final class AppLog {
  AppLog._();

  static final _lines = ListQueue<String>();
  static const _max = 400;
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static List<String> get lines => List.unmodifiable(_lines);

  static void add(String tag, String message) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final line =
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
        '[$tag] ${Redactor.redact(message)}';
    _lines.add(line);
    while (_lines.length > _max) {
      _lines.removeFirst();
    }
    changes.value++;
    if (kDebugMode) debugPrint(line);
  }

  static void clear() {
    _lines.clear();
    changes.value++;
  }
}
