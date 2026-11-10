# Development

## Requirements

- **Flutter 3.47.9** (Dart 3.13.7).
- **Linux builds:** `clang ninja-build libgtk-3-dev liblzma-dev libsecret-1-dev`.
- **Android:** JDK 21 and Android SDK 36.
- **Windows:** Visual Studio 2022 with *Desktop development with C++* and the ATL component.

## Build and run

```bash
scripts/fetch_go2rtc.sh            # engine for this machine (SHA-256 verified, not in git)
flutter pub get
flutter run -d linux               # VS Code snap? use: scripts/linux_env.sh flutter run -d linux

scripts/build_android.sh           # release APK (arm64 + armv7), runs fetch_go2rtc.sh android
```

Release packaging (APK, Windows installer, Linux AppImage) runs in GitHub Actions; see
`.github/workflows/release.yml`. It runs on tags `v*` and publishes to Releases.

## Project layout

```
lib/
  app/            routes, theme, providers (cameras, settings, per-camera view state)
  core/engine/    go2rtc as a child process: config, start/health/restart, HTTP API client
  core/cameras/   camera model, stream URLs per connection type, storage, Test/auto-detect
  core/control/   camera settings: DVRIP and ONVIF clients behind one interface
  core/discovery/ ONVIF + DVRIP discovery and subnet probing
  media/          CameraPlayer (WebRTC first, RTSP fallback), push-to-talk, watchdog
  features/       screens
android/          the only native code is MainActivity.kt (engine path, multicast lock, OS version)
scripts/          fetch_go2rtc.sh, build_android.sh, linux_env.sh
tool/             make_icons.py (all app icons), gop_probe.py and audio_level.py (stream diagnostics)
```

## How playback works

- **The engine.** go2rtc runs as a child process on `127.0.0.1` only, with random ports and
  credentials on every launch. Its config is passed on the command line, so camera addresses
  and passwords are never written to disk.
- **Streams.** Cameras are added to the engine as streams when they are opened.
- **Playing.** CameraPlayer tries WebRTC first, which has the lowest latency and supports
  talk. It falls back to the RTSP player for H.265 on desktop, for AAC audio, or when WebRTC
  fails.
- **Stall watchdog.** A stalled stream reconnects automatically.
- **Diagnostics.** The player's decisions are logged under Settings → Media engine and
  diagnostics.

## The engine

CamStation uses go2rtc v1.9.15 from
[MatthewReed303/go2rtc, branch `camstation`](https://github.com/MatthewReed303/go2rtc/tree/camstation).
The branch adds:

- **WebRTC on Android 11+.** A `GOOS=android` build, with the Android version passed in
  `ANDROID_VERSION` so interface listing works.
- **The DVRIP main-stream H.264 fix** (upstream issue #2671).
- **Voice boost.** With `GO2RTC_VOICE_BOOST=<dB>` the WebRTC and RTSP outputs amplify G.711
  audio, with a peak limiter (`pkg/pcm/voice_boost.go`). CamStation sets it to 20 unless
  *Boost camera sound* is off.
- **A release workflow.** It builds without UPX (Android 8 can't run UPX-packed executables)
  and publishes SHA256SUMS.

To update the engine:
1. Tag `camstation-<version>.<n>` on that branch.
2. Copy the new SHA256SUMS digests into `scripts/fetch_go2rtc.sh`.

## Tests

| Command | What it covers |
|---|---|
| `flutter test` | Unit tests. Engine and camera tests skip without the settings below |
| `CAMSTATION_GO2RTC=$PWD/engine_bin/linux_amd64/go2rtc flutter test test/integration/engine_manager_test.dart` | The real engine: loopback-only, auth, no files written, crash restart |
| `CAMSTATION_CAM_IP=<ip> flutter test test/integration/dvrip_control_live_test.dart` | DVRIP camera settings (read-only unless `CAMSTATION_ALLOW_WRITE=1`) |
| `CAMSTATION_CAM_IP=<ip> CAMSTATION_ONVIF_PORT=<port> flutter test test/integration/onvif_control_live_test.dart` | ONVIF camera settings |
| `CAMSTATION_CAM_IP=<ip> scripts/linux_env.sh flutter test integration_test/user_journey_test.dart -d linux` | A first-time user's whole journey on a phone-sized screen, with a screenshot per step |
| `scripts/linux_env.sh flutter test integration_test/demo_journey_test.dart -d linux` | The same with the demo camera (below): live view, full screen, recovery after sleep, grid, settings |
| `CAMSTATION_CAM_IP=<ip> scripts/linux_env.sh flutter test integration_test/close_stops_stream_test.dart -d linux` | Closing a camera (also mid-connect) leaves nothing pulling its stream |
| `flutter test integration_test/rtsp_dispose_diag_test.dart -d <device> --dart-define=CAMSTATION_DEMO_URL=…` | Freeing one of several RTSP players (a native-crash regression check) |

**Demo camera.** `tool/demo_camera.sh` (needs GStreamer) serves a test pattern with a clock on
`tcp://<host>:9100`. Add it as *Other stream URL*. From the Android emulator, the host is
`10.0.2.2`. The documentation screenshots come from the demo journey; never use a real camera
for them.

**On an Android device or emulator:**
- Pass camera settings with `--dart-define=CAMSTATION_CAM_IP=<ip>` instead of environment
  variables.
- Add `--no-uninstall` so you can pull the screenshots afterwards.

## Icons

All icons are generated from the logo geometry: `python3 tool/make_icons.py`. It writes
`assets/logo/`, the Android launcher icons (including adaptive and monochrome), the Windows
`.ico` and the Linux icon.
