import 'dart:io';

import 'package:flutter/services.dart';

/// Finds the go2rtc executable for this platform.
///
/// - Dev override: env `CAMSTATION_GO2RTC=/path/to/go2rtc`.
/// - Android: `<nativeLibraryDir>/libgo2rtc.so` (packaged as a jniLib so it
///   is extracted to an executable location; W^X blocks app data dirs).
/// - Linux/Windows: `<app dir>/engine/go2rtc[.exe]`, copied there by the
///   CMake install step from `engine_bin/` (see scripts/fetch_go2rtc.sh).
class EngineBinary {
  const EngineBinary._();

  static const _platform = MethodChannel('camstation/platform');

  static Future<String> locate() async {
    final override = Platform.environment['CAMSTATION_GO2RTC'];
    if (override != null && override.isNotEmpty) return _check(override);

    if (Platform.isAndroid) {
      final dir = await _platform.invokeMethod<String>('nativeLibraryDir');
      if (dir == null) throw const FileSystemException('no nativeLibraryDir');
      return _check('$dir/libgo2rtc.so');
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final name = Platform.isWindows ? 'go2rtc.exe' : 'go2rtc';
    return _check('$exeDir${sep}engine$sep$name');
  }

  /// Extra environment for the engine process. On Android the engine needs
  /// the Android version to list network interfaces on Android 11+
  /// (see go2rtc `android.go` in the CamStation engine build).
  static Future<Map<String, String>> environment() async {
    if (!Platform.isAndroid) return const {};
    try {
      final release = await _platform.invokeMethod<String>('androidRelease');
      final major = RegExp(r'^\d+').firstMatch(release ?? '')?.group(0);
      return {if (major != null) 'ANDROID_VERSION': major};
    } on Object {
      return const {};
    }
  }

  static String _check(String path) {
    if (!File(path).existsSync()) {
      throw FileSystemException(
        'Engine binary not found. Run scripts/fetch_go2rtc.sh, then rebuild.',
        path,
      );
    }
    return path;
  }
}
