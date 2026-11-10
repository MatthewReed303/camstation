import 'dart:io';

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/camera_probe.dart';
import 'package:camstation/core/cameras/stream_sources.dart';
import 'package:camstation/core/discovery/discovered_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Connection type picked in the form. `auto` is UI-only: probing decides
/// the real [SourceKind] (and DVRIP media transport).
enum _Choice {
  auto('Auto-detect (recommended)'),
  dvrip('DVRIP'),
  onvif('ONVIF'),
  rtsp('RTSP URL'),
  url('Other stream URL (RTMP, HTTP, HLS, ISAPI, Tapo…)');

  const _Choice(this.label);
  final String label;

  SourceKind? get kind => switch (this) {
    _Choice.auto => null,
    _Choice.dvrip => SourceKind.dvrip,
    _Choice.onvif => SourceKind.onvif,
    _Choice.rtsp => SourceKind.rtsp,
    _Choice.url => SourceKind.url,
  };

  static _Choice of(SourceKind k) => switch (k) {
    SourceKind.dvrip => _Choice.dvrip,
    SourceKind.onvif => _Choice.onvif,
    SourceKind.rtsp => _Choice.rtsp,
    SourceKind.url => _Choice.url,
  };
}

class AddCameraScreen extends ConsumerStatefulWidget {
  const AddCameraScreen({super.key, this.discovered, this.cameraId});

  final DiscoveredCamera? discovered;
  final String? cameraId;

  @override
  ConsumerState<AddCameraScreen> createState() => _AddCameraScreenState();
}

class _AddCameraScreenState extends ConsumerState<AddCameraScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  final _rtspPort = TextEditingController(text: '554');
  final _dvripPort = TextEditingController(text: '34567');
  final _onvifPort = TextEditingController(text: '80');
  final _channel = TextEditingController(text: '1');
  final _urlMain = TextEditingController();
  final _urlSub = TextEditingController();

  _Choice _choice = _Choice.auto;
  StartQuality _startQuality = StartQuality.last;
  StartAudio _startAudio = StartAudio.last;
  StartOrientation _startOrientation = StartOrientation.last;
  StartFullscreen _startFullscreen = StartFullscreen.last;
  Camera? _existing;
  bool _passwordTouched = false;
  bool _busy = false;
  List<ProbeResult>? _results;
  ProbeResult? _chosen;

  bool get _usesUrls => _choice.kind?.usesUrls ?? false;

  @override
  void initState() {
    super.initState();
    final id = widget.cameraId;
    if (id != null) {
      final c = ref.read(camerasProvider.notifier).byId(id);
      if (c != null) _load(c);
    } else if (widget.discovered case final d?) {
      _host.text = d.ip;
      _name.text = d.suggestedName;
      if (d.onvifPort != null) _onvifPort.text = '${d.onvifPort}';
      if (d.dvripPort != null) _dvripPort.text = '${d.dvripPort}';
    }
  }

  void _load(Camera c) {
    _existing = c;
    _name.text = c.name;
    _host.text = c.host;
    _user.text = c.username;
    _rtspPort.text = '${c.rtspPort}';
    _dvripPort.text = '${c.dvripPort}';
    _onvifPort.text = '${c.onvifPort}';
    _channel.text = '${c.channel + 1}';
    _urlMain.text = c.urlMain ?? '';
    _urlSub.text = c.urlSub ?? '';
    _choice = _Choice.of(c.source);
    _startQuality = c.startQuality;
    _startAudio = c.startAudio;
    _startOrientation = c.startOrientation;
    _startFullscreen = c.startFullscreen;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _user,
      _pass,
      _rtspPort,
      _dvripPort,
      _onvifPort,
      _channel,
      _urlMain,
      _urlSub,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  /// The camera as described by the form, for [kind].
  Camera _draft(SourceKind kind) {
    final urlMain = _text(_urlMain);
    final host = kind.usesUrls && urlMain != null
        ? (Uri.tryParse(urlMain)?.host ?? '')
        : _host.text.trim();
    return Camera(
      id: _existing?.id ?? newCameraId(),
      name: _text(_name) ?? host,
      host: host,
      source: kind,
      username: _user.text.trim(),
      rtspPort: int.tryParse(_rtspPort.text) ?? 554,
      dvripPort: int.tryParse(_dvripPort.text) ?? 34567,
      onvifPort: int.tryParse(_onvifPort.text) ?? 80,
      channel: ((int.tryParse(_channel.text) ?? 1) - 1).clamp(0, 255),
      dvripMediaViaRtsp: _existing?.dvripMediaViaRtsp ?? false,
      urlMain: kind.usesUrls ? urlMain : null,
      urlSub: kind.usesUrls ? _text(_urlSub) : null,
      supportsTalk: _existing?.supportsTalk ?? false,
      startQuality: _startQuality,
      startAudio: _startAudio,
      startOrientation: _startOrientation,
      startFullscreen: _startFullscreen,
    );
  }

  Future<String> _password() async {
    if (_existing != null && !_passwordTouched) {
      return ref.read(camerasProvider.notifier).password(_existing!.id);
    }
    return _pass.text;
  }

  Future<void> _test() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _results = null;
      _chosen = null;
    });
    try {
      final engine = ref.read(engineProvider);
      await engine.ensureStarted();
      final probe = CameraProbe(engine);
      final pw = await _password();
      final kind = _choice.kind;
      final results = kind == null
          ? await probe.autoDetect(_draft(SourceKind.onvif), pw)
          : [await probe.probe(_draft(kind), pw)];
      if (!mounted) return;
      setState(() {
        _results = results;
        _chosen = results.firstWhere((r) => r.ok, orElse: () => results.first);
      });
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _results = [
            ProbeResult(
              camera: _draft(_choice.kind ?? SourceKind.onvif),
              error: 'Test failed: $e',
            ),
          ],
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_choice == _Choice.auto && _chosen == null) {
      await _test();
      if (_chosen == null || !_chosen!.ok) return;
    }
    // Form fields (name, ports, …) win; the connection details come from
    // the tested configuration when there is one.
    final tested = _chosen?.ok ?? false ? _chosen!.camera : null;
    final base = _draft(tested?.source ?? _choice.kind!);
    final cam = tested == null
        ? base
        : base.copyWith(
            dvripMediaViaRtsp: tested.dvripMediaViaRtsp,
            supportsTalk: tested.supportsTalk,
          );
    final pw = (_existing == null || _passwordTouched) ? _pass.text : null;
    await ref.read(camerasProvider.notifier).save(cam, password: pw);
    if (mounted) context.go('/');
  }

  String? _ipValidator(String? v) {
    if (_usesUrls) return null;
    final s = v?.trim() ?? '';
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(s);
    if (m == null || m.groups([1, 2, 3, 4]).any((g) => int.parse(g!) > 255)) {
      // The engine can't resolve hostnames on Android.
      return 'Enter the camera IP address, e.g. 192.168.1.20';
    }
    return null;
  }

  String? _urlValidator(String? v, {required bool required}) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return required ? 'Enter the stream URL' : null;
    if (_choice == _Choice.rtsp &&
        !RegExp('^rtsps?x?://').hasMatch(s.toLowerCase())) {
      return 'Must start with rtsp:// (or rtsps://)';
    }
    return StreamSources.validateUrl(s);
  }

  @override
  Widget build(BuildContext context) {
    final editing = _existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit camera' : 'Add camera'),
        actions: [
          if (!editing)
            TextButton.icon(
              onPressed: () => context.pushReplacement('/discover'),
              icon: const Icon(Icons.radar),
              label: const Text('Scan network'),
            ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            DropdownButtonFormField<_Choice>(
              initialValue: _choice,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Connection type'),
              items: [
                for (final c in _Choice.values)
                  DropdownMenuItem(value: c, child: Text(c.label)),
              ],
              onChanged: (v) => setState(() {
                _choice = v ?? _Choice.auto;
                _results = null;
                _chosen = null;
              }),
            ),
            if (!_usesUrls)
              TextFormField(
                controller: _host,
                decoration: const InputDecoration(labelText: 'IP address'),
                keyboardType: TextInputType.url,
                validator: _ipValidator,
              ),
            if (_usesUrls) ...[
              TextFormField(
                controller: _urlMain,
                decoration: InputDecoration(
                  labelText: 'Main stream URL',
                  hintText: _choice == _Choice.rtsp
                      ? 'rtsp://192.168.1.20:554/stream1'
                      : 'rtmp://…, https://…/video.mjpg, isapi://…',
                  helperText: 'Without username/password: enter those below',
                ),
                validator: (v) => _urlValidator(v, required: true),
              ),
              TextFormField(
                controller: _urlSub,
                decoration: const InputDecoration(
                  labelText: 'Sub-stream URL (optional, used by the grid)',
                ),
                validator: (v) => _urlValidator(v, required: false),
              ),
            ],
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextFormField(
              controller: _pass,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: editing
                    ? 'Leave empty to keep the saved password'
                    : 'Leave empty if the camera has no password',
              ),
              onChanged: (_) => _passwordTouched = true,
            ),
            if (!_usesUrls)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Ports and channel'),
                children: [
                  _number(_rtspPort, 'RTSP port', max: 65535),
                  _number(_dvripPort, 'DVRIP port', max: 65535),
                  _number(
                    _onvifPort,
                    'ONVIF port (often 80, 8000 or 8899)',
                    max: 65535,
                  ),
                  _number(_channel, 'Channel (DVR/NVR input)', max: 256),
                ],
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('When this camera opens'),
              subtitle: Text(
                'Stream: ${_startQuality.label} · Sound: ${_startAudio.label}'
                ' · Full screen: ${_startFullscreen.label}',
              ),
              children: [
                _LabeledChoice<StartQuality>(
                  label: 'Stream',
                  values: StartQuality.values,
                  labelOf: (q) => q.label,
                  selected: _startQuality,
                  onChanged: (v) => setState(() => _startQuality = v),
                ),
                _LabeledChoice<StartAudio>(
                  label: 'Sound',
                  values: StartAudio.values,
                  labelOf: (a) => a.label,
                  selected: _startAudio,
                  onChanged: (v) => setState(() => _startAudio = v),
                ),
                _LabeledChoice<StartFullscreen>(
                  label: 'Full screen',
                  values: StartFullscreen.values,
                  labelOf: (f) => f.label,
                  selected: _startFullscreen,
                  onChanged: (v) => setState(() => _startFullscreen = v),
                ),
                if (Platform.isAndroid || Platform.isIOS)
                  _LabeledChoice<StartOrientation>(
                    label: 'Orientation',
                    values: StartOrientation.values,
                    labelOf: (o) => o.label,
                    selected: _startOrientation,
                    onChanged: (v) => setState(() => _startOrientation = v),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: Text(_busy ? 'Testing…' : 'Test'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.check),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
            RadioGroup<ProbeResult>(
              groupValue: _chosen,
              onChanged: (v) => setState(() => _chosen = v),
              child: Column(
                children: [
                  for (final r in _results ?? const <ProbeResult>[])
                    Card(
                      margin: const EdgeInsets.only(top: 12),
                      child: RadioListTile<ProbeResult>(
                        value: r,
                        enabled: r.ok,
                        title: Text(r.camera.connectionSummary),
                        subtitle: Text(r.summary),
                        secondary: Icon(
                          !r.ok
                              ? Icons.error_outline
                              : r.hasAudio
                              ? Icons.volume_up
                              : Icons.volume_off,
                          color: r.ok
                              ? null
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _number(TextEditingController c, String label, {required int max}) =>
      TextFormField(
        controller: c,
        decoration: InputDecoration(labelText: label),
        keyboardType: TextInputType.number,
        validator: (v) {
          final p = int.tryParse(v ?? '');
          return p == null || p < 1 || p > max ? 'Invalid number' : null;
        },
      );
}

/// A label with a full-width segmented choice under it (fits phones).
class _LabeledChoice<T> extends StatelessWidget {
  const _LabeledChoice({
    required this.label,
    required this.values,
    required this.labelOf,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<T> values;
  final String Function(T) labelOf;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [
              for (final v in values)
                ButtonSegment(value: v, label: Text(labelOf(v))),
            ],
            selected: {selected},
            onSelectionChanged: (v) => onChanged(v.first),
          ),
        ),
      ],
    ),
  );
}
