import 'dart:io';

/// Test settings from the host environment (desktop runs) or from
/// `--dart-define=KEY=value` (device runs, where the shell env isn't visible).
String? testEnv(String key) {
  final v = Platform.environment[key] ?? _defines[key];
  return (v == null || v.isEmpty) ? null : v;
}

const _defines = <String, String>{
  'CAMSTATION_CAM_IP': String.fromEnvironment('CAMSTATION_CAM_IP'),
  'CAMSTATION_CAM_KIND': String.fromEnvironment('CAMSTATION_CAM_KIND'),
  'CAMSTATION_DVRIP_VIA_RTSP': String.fromEnvironment(
    'CAMSTATION_DVRIP_VIA_RTSP',
  ),
  'CAMSTATION_ONVIF_PORT': String.fromEnvironment('CAMSTATION_ONVIF_PORT'),
  'CAMSTATION_CAM_USER': String.fromEnvironment('CAMSTATION_CAM_USER'),
  'CAMSTATION_CAM_PASS': String.fromEnvironment('CAMSTATION_CAM_PASS'),
  'CAMSTATION_GO2RTC': String.fromEnvironment('CAMSTATION_GO2RTC'),
  'CAMSTATION_DIAG_OUT': String.fromEnvironment('CAMSTATION_DIAG_OUT'),
  'CAMSTATION_TOUR_OUT': String.fromEnvironment('CAMSTATION_TOUR_OUT'),
  'CAMSTATION_JOURNEY_OUT': String.fromEnvironment('CAMSTATION_JOURNEY_OUT'),
  'CAMSTATION_SCAN': String.fromEnvironment('CAMSTATION_SCAN'),
};

/// Engine binary: on Android it is always the packaged libgo2rtc.so.
Future<String> Function()? testEngineLocator() {
  if (Platform.isAndroid) return null; // EngineBinary.locate() default
  final bin =
      testEnv('CAMSTATION_GO2RTC') ??
      '${Directory.current.path}/engine_bin/linux_amd64/go2rtc';
  return () async => bin;
}
