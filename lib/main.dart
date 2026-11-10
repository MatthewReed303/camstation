import 'dart:async';
import 'dart:io';

import 'package:camstation/app/app.dart';
import 'package:camstation/app/providers.dart';
import 'package:camstation/core/util/app_log.dart';
import 'package:camstation/media/rtsp_player.dart';
import 'package:camstation/media/webrtc_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  RtspPlayer.registerBackend();
  await WebRtcPlayer.configureAudio();
  unawaited(_logDevice());
  _registerThirdPartyLicences();
  final dir = await getApplicationSupportDirectory();
  final container = ProviderContainer(
    overrides: [supportDirProvider.overrideWithValue(dir)],
  );
  _stopEngineOnSignals(container);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CamStationApp(),
    ),
  );
}

/// On Linux/macOS a terminated app must not leave go2rtc running. SIGKILL
/// can't be caught; that case is cleaned up by the pidfile check on the
/// next start (EngineManager._killStale). Windows/Android: the normal exit
/// path and the pidfile cover it.
void _stopEngineOnSignals(ProviderContainer container) {
  if (!(Platform.isLinux || Platform.isMacOS)) return;
  var stopping = false;
  for (final sig in [
    ProcessSignal.sigterm,
    ProcessSignal.sigint,
    ProcessSignal.sighup,
  ]) {
    sig.watch().listen((_) async {
      if (stopping) return;
      stopping = true;
      try {
        await container
            .read(engineProvider)
            .stop()
            .timeout(const Duration(seconds: 3));
      } on Object {
        // exiting anyway
      }
      exit(0);
    });
  }
}

/// Licences for bundled components that are not Dart packages.
/// Android: phone model and its video decoders' limits, into the
/// diagnostics log (why a 4K stream won't play on an older phone).
Future<void> _logDevice() async {
  if (!Platform.isAndroid) return;
  try {
    final info = await const MethodChannel('camstation/platform')
        .invokeMethod<String>('deviceInfo');
    for (final line in (info ?? '').split('\n')) {
      if (line.isNotEmpty) AppLog.add('device', line);
    }
  } on Object {
    // diagnostics only
  }
}

void _registerThirdPartyLicences() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['go2rtc'],
      '''
MIT License

Copyright (c) 2022 Alexey Khit

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''',
    );
    yield const LicenseEntryWithLineBreaks(
      ['libmdk (via fvp)'],
      '''
libmdk is proprietary freeware by Wang Bin, distributed with the fvp package.
"Free for Flutter users. A key is already included. Can be commercial
softwares." See https://github.com/wang-bin/mdk-sdk#license''',
    );
  });
}
