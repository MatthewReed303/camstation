import 'dart:async';

/// Calls [onStall] when [progress] stops increasing for [stallAfter].
///
/// [progress] returns a monotonically increasing counter (bytes, frames or
/// position). Errors from [progress] count as no progress.
class StallWatchdog {
  StallWatchdog({
    required this.progress,
    required this.onStall,
    this.stallAfter = const Duration(seconds: 10),
    this.interval = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Future<int> Function() progress;
  final void Function() onStall;
  final Duration stallAfter;
  final Duration interval;
  final DateTime Function() _now;

  Timer? _timer;
  int _last = -1;
  DateTime? _lastChange;
  bool _busy = false;

  void start() {
    stop();
    _last = -1;
    _lastChange = _now();
    _timer = Timer.periodic(interval, (_) => tick());
  }

  /// One check; public for tests.
  Future<void> tick() async {
    if (_busy) return;
    _busy = true;
    try {
      int v;
      try {
        v = await progress();
      } on Object {
        v = _last;
      }
      final now = _now();
      if (v > _last) {
        _last = v;
        _lastChange = now;
      } else if (now.difference(_lastChange ?? now) >= stallAfter) {
        stop();
        onStall();
      }
    } finally {
      _busy = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
