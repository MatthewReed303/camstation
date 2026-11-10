import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';

import 'dart:io';

import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/core/util/app_log.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

const appVersion = '0.3.1';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final engine = ref.watch(engineProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionTitle('Appearance'),
          ListTile(
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) =>
                  notifier.update(s.copyWith(themeMode: v.first)),
            ),
          ),
          ListTile(
            title: const Text('Accent colour'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in accentColors)
                    _ColorDot(
                      color: Color(c),
                      selected: s.seedColor == c,
                      onTap: () => notifier.update(s.copyWith(seedColor: c)),
                    ),
                ],
              ),
            ),
          ),
          const _SectionTitle('Playback'),
          ListTile(
            title: const Text('Default stream'),
            subtitle: const Text(
              'For cameras never opened before; each camera can override it',
            ),
            trailing: SegmentedButton<StreamQuality>(
              segments: const [
                ButtonSegment(value: StreamQuality.main, label: Text('HD')),
                ButtonSegment(value: StreamQuality.sub, label: Text('SD')),
              ],
              selected: {s.defaultQuality},
              onSelectionChanged: (v) =>
                  notifier.update(s.copyWith(defaultQuality: v.first)),
            ),
          ),
          ListTile(
            title: const Text('Player'),
            subtitle: const Text(
              'Auto picks WebRTC (lowest latency, talk) and switches to RTSP '
              'for H.265 or AAC when needed',
            ),
            trailing: DropdownButton<PlayerPreference>(
              value: s.preference,
              onChanged: (v) =>
                  v == null ? null : notifier.update(s.copyWith(preference: v)),
              items: const [
                DropdownMenuItem(
                  value: PlayerPreference.auto,
                  child: Text('Auto'),
                ),
                DropdownMenuItem(
                  value: PlayerPreference.webrtc,
                  child: Text('WebRTC'),
                ),
                DropdownMenuItem(
                  value: PlayerPreference.rtsp,
                  child: Text('RTSP'),
                ),
              ],
            ),
          ),
          ListTile(
            title: const Text('Keep screen on'),
            subtitle: const Text('Stop the screen dimming or locking'),
            trailing: DropdownButton<KeepScreenOn>(
              value: s.keepScreenOn,
              onChanged: (v) => v == null
                  ? null
                  : notifier.update(s.copyWith(keepScreenOn: v)),
              items: [
                for (final k in KeepScreenOn.values)
                  DropdownMenuItem(value: k, child: Text(k.label)),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Show stream details'),
            subtitle: const Text(
              'Player and codecs on the video (for troubleshooting)',
            ),
            value: s.showStreamInfo,
            onChanged: (v) => notifier.update(s.copyWith(showStreamInfo: v)),
          ),
          const _SectionTitle('About'),
          ValueListenableBuilder<EngineState>(
            valueListenable: engine.state,
            builder: (context, st, _) => ListTile(
              title: const Text('Media engine and diagnostics'),
              subtitle: Text(
                'go2rtc ${st.version ?? '1.9.15'} · ${st.stage.name}'
                '${st.error == null ? '' : ' · ${st.error}'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/log'),
            ),
          ),
          ListTile(
            title: const Text('About and licences'),
            subtitle: const Text('CamStation $appVersion · MIT licence'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'CamStation',
              applicationVersion: appVersion,
              applicationIcon: Image.asset(
                'assets/logo/camstation-256.png',
                width: 64,
                height: 64,
              ),
              applicationLegalese:
                  'Open-source IP camera viewer. Media engine: go2rtc by '
                  'AlexxIT (MIT).',
            ),
          ),
        ],
      ),
    );
  }
}

/// What the app and the media engine did, for troubleshooting. Redacted;
/// "Copy" puts both logs on the clipboard for a bug report.
class EngineLogScreen extends ConsumerWidget {
  const EngineLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    return ValueListenableBuilder<int>(
      valueListenable: AppLog.changes,
      builder: (context, _, _) {
        final app = AppLog.lines;
        final eng = engine.logLines;
        final text = [
          'CamStation $appVersion on ${Platform.operatingSystem} '
              '${Platform.operatingSystemVersion}',
          '--- app ---',
          ...app,
          '--- engine ---',
          ...eng,
        ].join('\n');
        return Scaffold(
          appBar: AppBar(
            title: const Text('Diagnostics'),
            actions: [
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Diagnostics copied')),
                    );
                  }
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              for (final line in text.split('\n'))
                Text(
                  line,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
            ],
          ),
        );
      },
    );
  }
}

const accentColors = <int>[
  0xFF2E7D6B, // teal
  0xFF1E88E5, // blue
  0xFF5E35B1, // purple
  0xFFD81B60, // pink
  0xFFE53935, // red
  0xFFF4511E, // orange
  0xFFF9A825, // amber
  0xFF43A047, // green
  0xFF546E7A, // slate
];

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 18)
            : null,
      ),
    ),
  );
}
