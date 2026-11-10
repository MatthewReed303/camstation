import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/control/camera_control.dart';
import 'package:camstation/core/control/dvrip/dvrip_control.dart';
import 'package:camstation/core/control/onvif/onvif_control.dart';

/// The settings protocol for a camera: DVRIP for DVRIP cameras (it exposes
/// more, e.g. audio on/off), otherwise ONVIF on the camera's ONVIF port.
CameraControl controlFor(Camera cam, String password) => switch (cam.source) {
  SourceKind.dvrip => DvripControl(
    host: cam.host,
    port: cam.dvripPort,
    channel: cam.channel,
    username: cam.username,
    password: password,
  ),
  _ => OnvifControl(
    host: cam.host,
    port: cam.onvifPort,
    username: cam.username,
    password: password,
  ),
};
