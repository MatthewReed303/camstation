import 'package:camstation/media/camera_player.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:flutter/material.dart';

/// Spinner / reconnecting / error layer on top of a player.
class PlayerStatusOverlay extends StatelessWidget {
  const PlayerStatusOverlay({
    required this.player,
    this.compact = false,
    super.key,
  });

  final CameraPlayer player;
  final bool compact;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlayerState>(
    valueListenable: player.state,
    builder: (context, s, _) {
      switch (s.status) {
        case PlayerStatus.playing:
        case PlayerStatus.idle:
          return const SizedBox.shrink();
        case PlayerStatus.connecting:
          return const Center(child: CircularProgressIndicator());
        case PlayerStatus.reconnecting:
        case PlayerStatus.error:
          final isError = s.status == PlayerStatus.error;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isError)
                    const Icon(Icons.videocam_off, color: Colors.white70)
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    isError ? 'Camera unavailable' : 'Reconnecting…',
                    style: const TextStyle(color: Colors.white),
                  ),
                  if (!compact && s.error != null)
                    Text(
                      s.error!,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  if (isError && !compact)
                    TextButton(
                      onPressed: player.reconnect,
                      child: const Text('Retry now'),
                    ),
                ],
              ),
            ),
          );
      }
    },
  );
}

/// Small "WebRTC · h264 · pcm_alaw/8000" badge.
class PlayerInfoBadge extends StatelessWidget {
  const PlayerInfoBadge({required this.player, super.key});
  final CameraPlayer player;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlayerState>(
    valueListenable: player.state,
    builder: (context, s, _) {
      if (s.status != PlayerStatus.playing || s.mode == null) {
        return const SizedBox.shrink();
      }
      final mode = s.mode == PlayerMode.webrtc ? 'WebRTC' : 'RTSP';
      // Video first, then audio.
      final sorted = [...s.codecs]
        ..sort(
          (a, b) => (a.kind == 'video' ? 0 : 1) - (b.kind == 'video' ? 0 : 1),
        );
      final codecs = sorted.isEmpty ? '' : ' · ${sorted.join(' · ')}';
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            '$mode$codecs',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      );
    },
  );
}
