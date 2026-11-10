import 'package:camstation/app/providers.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:camstation/media/rtsp_player.dart';
import 'package:camstation/media/webrtc_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Builds a [CameraPlayer] wired to the current engine. Backends are created
/// per connection attempt, so they always use the engine's current ports
/// (which change when the engine restarts).
CameraPlayer createCameraPlayer(WidgetRef ref) {
  final engine = ref.read(engineProvider);
  final player = CameraPlayer(
    api: () => engine.api,
    preference: ref.read(settingsProvider).preference,
    createBackend: (mode, name) => switch (mode) {
      PlayerMode.webrtc => WebRtcPlayer(api: engine.api, streamName: name),
      PlayerMode.rtsp => RtspPlayer(url: engine.settings.rtspUrl(name)),
    },
  );
  // Reconnect when the engine comes back (e.g. after the phone slept).
  var wasRunning = engine.state.value.isReady;
  void onEngine() {
    final running = engine.state.value.isReady;
    if (running && !wasRunning) player.engineRestarted();
    wasRunning = running;
  }

  engine.state.addListener(onEngine);
  player.onDispose = () => engine.state.removeListener(onEngine);
  return player;
}
