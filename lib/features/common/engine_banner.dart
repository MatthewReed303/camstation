import 'package:camstation/app/providers.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shows a strip when the media engine is not running, with a retry.
class EngineBanner extends ConsumerWidget {
  const EngineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    return ValueListenableBuilder<EngineState>(
      valueListenable: engine.state,
      builder: (context, s, _) {
        final (text, retry) = switch (s.stage) {
          EngineStage.running || EngineStage.stopped => (null, false),
          EngineStage.starting => ('Starting media engine…', false),
          EngineStage.restarting => (
            'Media engine restarting${s.error == null ? '' : ': ${s.error}'}',
            false,
          ),
          EngineStage.failed => (
            'Media engine failed to start: ${s.error ?? 'unknown error'}',
            true,
          ),
        };
        if (text == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: retry ? scheme.errorContainer : scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(child: Text(text, maxLines: 3)),
                if (retry)
                  TextButton(
                    onPressed: () => engine.ensureStarted().ignore(),
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
