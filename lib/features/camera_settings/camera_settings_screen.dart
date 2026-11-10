import 'dart:async';

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/control/camera_control.dart';
import 'package:camstation/core/control/control_factory.dart';
import 'package:camstation/core/control/dvrip/dvrip_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Camera settings over the camera's control protocol. Sections appear only
/// for features the camera reports.
class CameraSettingsScreen extends ConsumerStatefulWidget {
  const CameraSettingsScreen({required this.cameraId, super.key});
  final String cameraId;

  @override
  ConsumerState<CameraSettingsScreen> createState() =>
      _CameraSettingsScreenState();
}

class _CameraSettingsScreenState extends ConsumerState<CameraSettingsScreen> {
  Camera? _cam;
  CameraControl? _control;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  DeviceInfo? _info;
  List<VideoEncoderConfig> _encoders = const [];
  final _options = <String, VideoEncoderOptions>{};
  ImageSettings? _image;
  DateTime? _cameraTime;

  @override
  void initState() {
    super.initState();
    _cam = ref.read(camerasProvider.notifier).byId(widget.cameraId);
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_control?.close());
    super.dispose();
  }

  Future<void> _load() async {
    final cam = _cam;
    if (cam == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _control?.close();
    try {
      final pw = await ref.read(camerasProvider.notifier).password(cam.id);
      final c = controlFor(cam, pw);
      _control = c;
      await c.connect();
      final f = c.features;
      final info = await c.deviceInfo();
      final encs = f.contains(ControlFeature.video)
          ? await c.encoders()
          : const <VideoEncoderConfig>[];
      for (final e in encs) {
        _options[e.id] = await c.encoderOptions(e.id);
      }
      final img = f.contains(ControlFeature.image) ? await c.image() : null;
      final t = f.contains(ControlFeature.time) ? await c.time() : null;
      if (!mounted) return;
      setState(() {
        _info = info;
        _encoders = encs;
        _image = img;
        _cameraTime = t;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(String done, Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  bool _has(ControlFeature f) => _control?.features.contains(f) ?? false;

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    return Scaffold(
      appBar: AppBar(
        title: Text(cam == null ? 'Camera settings' : '${cam.name} settings'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: cam == null
          ? const Center(child: Text('Camera not found'))
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(error: _error!, onRetry: _load)
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _deviceCard(),
                for (final e in _encoders)
                  _EncoderCard(
                    key: ValueKey(e.id),
                    config: e,
                    options: _options[e.id] ?? const VideoEncoderOptions(),
                    showAudio: _has(ControlFeature.audioToggle),
                    sizeLabel: _control!.protocol == 'DVRIP'
                        ? (r) => DvripControl.resolutionSizes[r]
                        : (_) => null,
                    onSave: (c) => _saveEncoder(c),
                  ),
                if (_image != null) _imageCard(_image!),
                if (_has(ControlFeature.ptz)) _PtzCard(control: _control!),
                if (_has(ControlFeature.password)) _securityCard(),
                if (_has(ControlFeature.reboot)) _maintenanceCard(),
              ],
            ),
    );
  }

  Widget _deviceCard() {
    final i = _info;
    String row(String k, String? v) => v == null || v.isEmpty ? '' : '$k: $v\n';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '${row('Model', i?.model)}${row('Manufacturer', i?.manufacturer)}'
                      '${row('Firmware', i?.firmware)}'
                      'Settings via ${_control!.protocol}'
                  .trim(),
            ),
            if (_has(ControlFeature.time)) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Camera clock: ${_fmt(_cameraTime)}\n'
                      'This device:  ${_fmt(DateTime.now())}',
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy
                        ? null
                        : () => _run('Camera clock set', () async {
                            await _control!.setTime(DateTime.now());
                            final t = await _control!.time();
                            if (mounted) setState(() => _cameraTime = t);
                          }),
                    child: const Text('Sync time'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _fmt(DateTime? t) {
    if (t == null) return 'unknown';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<void> _saveEncoder(VideoEncoderConfig c) async {
    final ok = await _confirm(
      'Apply ${c.label} settings?',
      'The stream restarts on the camera; live views reconnect by themselves.',
      'Apply',
    );
    if (!ok) return;
    await _run('${c.label} saved', () async {
      final restart = await _control!.setEncoder(c);
      _encoders = await _control!.encoders();
      // Engine streams and cached codecs are stale now.
      await ref.read(streamRegistryProvider).refresh(_cam!);
      if (mounted) setState(() {});
      if (restart && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The camera needs a restart to apply')),
        );
      }
    });
  }

  Widget _imageCard(ImageSettings img) {
    Widget slider(String label, double? v, ImageSettings Function(double) set) {
      if (v == null) return const SizedBox.shrink();
      return Row(
        children: [
          SizedBox(width: 96, child: Text(label)),
          Expanded(
            child: Slider(
              value: v,
              max: 100,
              divisions: 100,
              label: v.round().toString(),
              onChanged: (x) => setState(() => _image = set(x)),
            ),
          ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Image', style: Theme.of(context).textTheme.titleMedium),
            if (img.flip != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Flip vertically'),
                value: img.flip!,
                onChanged: (v) =>
                    setState(() => _image = img.copyWith(flip: v)),
              ),
            if (img.mirror != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mirror horizontally'),
                value: img.mirror!,
                onChanged: (v) =>
                    setState(() => _image = img.copyWith(mirror: v)),
              ),
            slider(
              'Brightness',
              img.brightness,
              (x) => img.copyWith(brightness: x),
            ),
            slider('Contrast', img.contrast, (x) => img.copyWith(contrast: x)),
            slider(
              'Saturation',
              img.saturation,
              (x) => img.copyWith(saturation: x),
            ),
            slider(
              'Sharpness',
              img.sharpness,
              (x) => img.copyWith(sharpness: x),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run('Image settings saved', () async {
                        await _control!.setImage(_image!);
                        final fresh = await _control!.image();
                        if (mounted) setState(() => _image = fresh);
                      }),
                child: const Text('Save image settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _securityCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.password),
      title: const Text('Change camera password'),
      subtitle: Text('For user "${_cam!.username}"'),
      trailing: const Icon(Icons.chevron_right),
      onTap: _busy ? null : _changePassword,
    ),
  );

  Future<void> _changePassword() async {
    final next = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (next == null) return;
    final notifier = ref.read(camerasProvider.notifier);
    await _run('Password changed', () async {
      final old = await notifier.password(_cam!.id);
      await _control!.changePassword(oldPassword: old, newPassword: next);
      // Keep CamStation in step with the camera.
      await notifier.save(_cam!, password: next);
    });
  }

  Widget _maintenanceCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.restart_alt),
      title: const Text('Restart camera'),
      subtitle: const Text('The camera is offline for about a minute'),
      onTap: _busy
          ? null
          : () async {
              final ok = await _confirm(
                'Restart the camera?',
                'Video stops until the camera is back (about a minute).',
                'Restart',
              );
              if (ok) {
                await _run('Camera is restarting', () => _control!.reboot());
              }
            },
    ),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.settings_remote_outlined, size: 48),
          const SizedBox(height: 12),
          const Text('Could not open camera settings'),
          const SizedBox(height: 4),
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class _EncoderCard extends StatefulWidget {
  const _EncoderCard({
    required this.config,
    required this.options,
    required this.showAudio,
    required this.sizeLabel,
    required this.onSave,
    super.key,
  });

  final VideoEncoderConfig config;
  final VideoEncoderOptions options;
  final bool showAudio;
  final String? Function(String resolution) sizeLabel;
  final Future<void> Function(VideoEncoderConfig) onSave;

  @override
  State<_EncoderCard> createState() => _EncoderCardState();
}

class _EncoderCardState extends State<_EncoderCard> {
  late VideoEncoderConfig _c = widget.config;
  late final _bitrate = TextEditingController(
    text: widget.config.bitrateKbps?.toString() ?? '',
  );

  @override
  void didUpdateWidget(_EncoderCard old) {
    super.didUpdateWidget(old);
    if (old.config != widget.config) {
      _c = widget.config;
      _bitrate.text = widget.config.bitrateKbps?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _bitrate.dispose();
    super.dispose();
  }

  List<String> _with(List<String> list, String? current) =>
      {if (current != null) current, ...list}.toList();

  @override
  Widget build(BuildContext context) {
    final o = widget.options;
    final codecs = _with(o.codecs, _c.codec);
    final res = _with(o.resolutions, _c.resolution);
    final summary = [
      _c.codec,
      _c.resolution,
      if (_c.fps != null) '${_c.fps} fps',
      if (_c.bitrateKbps != null) '${_c.bitrateKbps} kbps',
      if (_c.audioEnabled != null) _c.audioEnabled! ? 'audio on' : 'audio off',
    ].whereType<String>().join(' · ');

    return Card(
      child: ExpansionTile(
        title: Text(widget.config.label),
        subtitle: Text(summary),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (codecs.length > 1)
            DropdownButtonFormField<String>(
              initialValue: _c.codec,
              decoration: const InputDecoration(labelText: 'Codec'),
              items: [
                for (final v in codecs)
                  DropdownMenuItem(value: v, child: Text(v)),
              ],
              onChanged: (v) => setState(() => _c = _c.copyWith(codec: v)),
            ),
          if (res.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: _c.resolution,
              decoration: const InputDecoration(labelText: 'Resolution'),
              items: [
                for (final v in res)
                  DropdownMenuItem(
                    value: v,
                    child: Text(
                      widget.sizeLabel(v) == null
                          ? v
                          : '$v (${widget.sizeLabel(v)})',
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _c = _c.copyWith(resolution: v)),
            ),
          if (_c.fps != null)
            Row(
              children: [
                SizedBox(width: 110, child: Text('Frame rate ${_c.fps}')),
                Expanded(
                  child: Slider(
                    value: _c.fps!.clamp(1, o.maxFps).toDouble(),
                    min: 1,
                    max: o.maxFps.toDouble(),
                    divisions: (o.maxFps - 1).clamp(1, 120),
                    onChanged: (v) =>
                        setState(() => _c = _c.copyWith(fps: v.round())),
                  ),
                ),
              ],
            ),
          if (_c.bitrateKbps != null)
            TextFormField(
              controller: _bitrate,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Bitrate (kbps, max ${o.maxBitrateKbps})',
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0 && n <= o.maxBitrateKbps) {
                  _c = _c.copyWith(bitrateKbps: n);
                }
              },
            ),
          if (_c.bitrateMode != null && o.bitrateModes.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SegmentedButton<String>(
                segments: [
                  for (final m in o.bitrateModes)
                    ButtonSegment(value: m, label: Text(m)),
                ],
                selected: {_c.bitrateMode!},
                onSelectionChanged: (s) =>
                    setState(() => _c = _c.copyWith(bitrateMode: s.first)),
              ),
            ),
          if (_c.gopSeconds != null)
            DropdownButtonFormField<int>(
              initialValue: _c.gopSeconds!.clamp(1, 12),
              decoration: const InputDecoration(
                labelText: 'Keyframe interval (shorter = faster start)',
              ),
              items: [
                for (final s in [1, 2, 3, 4, 5, 6, 8, 10, 12])
                  DropdownMenuItem(value: s, child: Text('$s s')),
              ],
              onChanged: (v) => setState(() => _c = _c.copyWith(gopSeconds: v)),
            ),
          if (widget.showAudio && _c.audioEnabled != null && o.hasAudio)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Audio'),
              subtitle: const Text(
                'Send the camera microphone with this stream',
              ),
              value: _c.audioEnabled!,
              onChanged: (v) =>
                  setState(() => _c = _c.copyWith(audioEnabled: v)),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => widget.onSave(_c),
              child: const Text('Apply'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PtzCard extends StatelessWidget {
  const _PtzCard({required this.control});
  final CameraControl control;

  Widget _pad(IconData icon, PtzMove move, String tip) => Listener(
    onPointerDown: (_) => control.ptz(move).ignore(),
    onPointerUp: (_) => control.ptzStop().ignore(),
    onPointerCancel: (_) => control.ptzStop().ignore(),
    child: IconButton.filledTonal(
      tooltip: tip,
      onPressed: () {},
      icon: Icon(icon),
    ),
  );

  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      leading: const Icon(Icons.control_camera),
      title: const Text('Pan / tilt / zoom'),
      subtitle: const Text('Hold a button to move'),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(
                children: [
                  _pad(Icons.keyboard_arrow_up, PtzMove.up, 'Up'),
                  Row(
                    children: [
                      _pad(Icons.keyboard_arrow_left, PtzMove.left, 'Left'),
                      const SizedBox(width: 48),
                      _pad(Icons.keyboard_arrow_right, PtzMove.right, 'Right'),
                    ],
                  ),
                  _pad(Icons.keyboard_arrow_down, PtzMove.down, 'Down'),
                ],
              ),
              const SizedBox(width: 32),
              Column(
                children: [
                  _pad(Icons.zoom_in, PtzMove.zoomIn, 'Zoom in'),
                  const SizedBox(height: 8),
                  _pad(Icons.zoom_out, PtzMove.zoomOut, 'Zoom out'),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New camera password'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _a,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'New password'),
        ),
        TextField(
          controller: _b,
          obscureText: true,
          decoration: InputDecoration(labelText: 'Repeat', errorText: _err),
        ),
        const SizedBox(height: 8),
        const Text(
          'CamStation saves the new password too. Other apps using this '
          'camera will need it.',
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_a.text.length < 6) {
            setState(() => _err = 'Use at least 6 characters');
          } else if (_a.text != _b.text) {
            setState(() => _err = 'The passwords differ');
          } else {
            Navigator.pop(context, _a.text);
          }
        },
        child: const Text('Change'),
      ),
    ],
  );
}
