import 'package:camstation/core/control/camera_control.dart';
import 'package:camstation/core/control/onvif/onvif_soap.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// One media profile's video encoder configuration, parsed from ONVIF.
class _Encoder {
  _Encoder(this.el, this.profileName);
  final XmlElement el; // tt:VideoEncoderConfiguration / Configuration
  final String profileName;

  String get token => el.getAttribute('token') ?? '';
}

/// [CameraControl] over ONVIF (Device, Media ver10, Imaging ver20, PTZ
/// ver20) with a small built-in SOAP client.
class OnvifControl implements CameraControl {
  OnvifControl({
    required this.host,
    required this.port,
    required String username,
    required String password,
    http.Client? client,
  }) : _soap = OnvifSoap(
         username: username,
         password: password,
         client: client,
       ),
       _username = username;

  final String host;
  final int port;
  final String _username;
  final OnvifSoap _soap;

  Uri get _device => Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: '/onvif/device_service',
  );
  Uri? _media;
  Uri? _imaging;
  Uri? _ptz;
  final _profiles = <XmlElement>[];
  Set<ControlFeature> _features = const {};

  @override
  String get protocol => 'ONVIF';

  @override
  Set<ControlFeature> get features => _features;

  /// Cameras often advertise service URLs with an internal IP/port; keep
  /// the path but always talk to the address the user configured.
  Uri? _rebase(String? xaddr) {
    final u = Uri.tryParse(xaddr ?? '');
    if (u == null || u.path.isEmpty) return null;
    return Uri(scheme: 'http', host: host, port: port, path: u.path);
  }

  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on OnvifFault catch (e) {
      throw ControlException(
        e.isAuth ? 'Wrong username or password' : 'ONVIF: ${e.message}',
        isAuth: e.isAuth,
      );
    }
  }

  @override
  Future<void> connect() => _guard(() async {
    // Unauthenticated: learn the camera clock first (digest timestamps).
    try {
      final b = await _soap.call(
        _device,
        '<tds:GetSystemDateAndTime/>',
        auth: false,
      );
      final cam = _utc(b.el('UTCDateTime'));
      if (cam != null)
        _soap.timeOffset = cam.difference(DateTime.now().toUtc());
    } on Object {
      // Some cameras require auth here too; carry on without an offset.
    }
    final caps = await _soap.call(
      _device,
      '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>',
    );
    _media = _rebase(caps.el('Media')?.textOf('XAddr'));
    _imaging = _rebase(caps.el('Imaging')?.textOf('XAddr'));
    _ptz = _rebase(caps.el('PTZ')?.textOf('XAddr'));

    _profiles.clear();
    if (_media != null) {
      final p = await _soap.call(_media!, '<trt:GetProfiles/>');
      _profiles.addAll(p.findAllElements('Profiles', namespaceUri: '*'));
    }
    final hasPtzProfile = _profiles.any(
      (p) => p.child('PTZConfiguration') != null,
    );
    _features = {
      if (_profiles.isNotEmpty) ControlFeature.video,
      if (_imaging != null && _videoSourceToken != null) ControlFeature.image,
      ControlFeature.time,
      ControlFeature.password,
      ControlFeature.reboot,
      if (_ptz != null && hasPtzProfile) ControlFeature.ptz,
    };
  });

  static DateTime? _utc(XmlElement? dt) {
    if (dt == null) return null;
    int n(String parent, String f) =>
        int.tryParse(dt.el(parent)?.textOf(f) ?? '') ?? 0;
    return DateTime.utc(
      n('Date', 'Year'),
      n('Date', 'Month'),
      n('Date', 'Day'),
      n('Time', 'Hour'),
      n('Time', 'Minute'),
      n('Time', 'Second'),
    );
  }

  String? get _videoSourceToken => _profiles
      .map((p) => p.child('VideoSourceConfiguration')?.textOf('SourceToken'))
      .whereType<String>()
      .firstOrNull;

  String? get _ptzProfileToken => _profiles
      .where((p) => p.child('PTZConfiguration') != null)
      .map((p) => p.getAttribute('token'))
      .whereType<String>()
      .firstOrNull;

  @override
  Future<DeviceInfo> deviceInfo() => _guard(() async {
    final b = await _soap.call(_device, '<tds:GetDeviceInformation/>');
    return DeviceInfo(
      manufacturer: b.textOf('Manufacturer'),
      model: b.textOf('Model'),
      firmware: b.textOf('FirmwareVersion'),
    );
  });

  List<_Encoder> get _encoders {
    final seen = <String>{};
    final out = <_Encoder>[];
    for (final p in _profiles) {
      final e = p.child('VideoEncoderConfiguration');
      if (e == null) continue;
      final t = e.getAttribute('token') ?? '';
      if (seen.add(t)) out.add(_Encoder(e, p.textOf('Name') ?? t));
    }
    return out;
  }

  static String _codec(String? enc) => switch (enc?.toUpperCase()) {
    'H264' => 'H.264',
    'H265' || 'HEVC' => 'H.265',
    'JPEG' => 'MJPEG',
    _ => enc ?? '?',
  };

  @override
  Future<List<VideoEncoderConfig>> encoders() async {
    final list = _encoders;
    return [
      for (var i = 0; i < list.length; i++)
        _toConfig(
          list[i],
          i == 0
              ? 'Main stream (HD)'
              : i == 1
              ? 'Sub stream (SD)'
              : list[i].profileName,
        ),
    ];
  }

  /// GovLength is frames per the spec, but some cameras report seconds
  /// (e.g. 2 at 15 fps). Values below the frame rate are read as seconds.
  static int? _gopSeconds(int? gov, int? fps) {
    if (gov == null || gov <= 0) return null;
    if (fps == null || fps <= 0 || gov < fps) return gov.clamp(1, 60);
    return (gov / fps).round().clamp(1, 60);
  }

  static VideoEncoderConfig _toConfig(_Encoder e, String label) {
    final el = e.el;
    final fps = el.child('RateControl')?.number('FrameRateLimit')?.round();
    final gov = el.child('H264')?.number('GovLength')?.round();
    final w = el.child('Resolution')?.textOf('Width');
    final h = el.child('Resolution')?.textOf('Height');
    return VideoEncoderConfig(
      id: e.token,
      label: label,
      codec: _codec(el.child('Encoding')?.innerText.trim()),
      resolution: w == null || h == null ? null : '$w×$h',
      fps: fps,
      bitrateKbps: el.child('RateControl')?.number('BitrateLimit')?.round(),
      gopSeconds: _gopSeconds(gov, fps),
    );
  }

  @override
  Future<VideoEncoderOptions> encoderOptions(
    String encoderId,
  ) => _guard(() async {
    final b = await _soap.call(
      _media!,
      '<trt:GetVideoEncoderConfigurationOptions>'
      '<trt:ConfigurationToken>${OnvifSoap.esc(encoderId)}</trt:ConfigurationToken>'
      '</trt:GetVideoEncoderConfigurationOptions>',
    );
    final h264 = b.el('H264');
    final res = [
      for (final r in (h264 ?? b).findAllElements(
        'ResolutionsAvailable',
        namespaceUri: '*',
      ))
        '${r.textOf('Width')}×${r.textOf('Height')}',
    ];
    final current = _encoders.where((e) => e.token == encoderId).firstOrNull;
    return VideoEncoderOptions(
      // Media ver10 can't switch codec families reliably: keep current.
      codecs: [
        if (current != null)
          _codec(current.el.child('Encoding')?.innerText.trim()),
      ],
      resolutions: res.toSet().toList(),
      // Some cameras report nonsense (e.g. -102, or below the current
      // setting): never offer less than the current fps; cap at 60.
      maxFps: _sanitizeMaxFps(
        h264?.el('FrameRateRange')?.number('Max')?.round(),
        current == null ? null : _toConfig(current, '').fps,
      ),
      maxBitrateKbps: b.el('BitrateRange')?.number('Max')?.round() ?? 16384,
      bitrateModes: const [],
    );
  });

  @override
  Future<bool> setEncoder(VideoEncoderConfig c) => _guard(() async {
    // Writing an unchanged config is not harmless: some cameras re-validate
    // and clamp values (e.g. fps above their advertised maximum) on any write.
    final current = (await encoders()).where((x) => x.id == c.id).firstOrNull;
    if (current != null && _same(current, c)) return false;
    final e = _encoders.where((x) => x.token == c.id).firstOrNull;
    if (e == null) throw ControlException('Unknown encoder ${c.id}');
    // Read-modify-write: copy the camera's own element, change fields.
    final cfg = e.el.copy();
    void setText(XmlElement? parent, String local, Object? v) {
      if (parent == null || v == null) return;
      final n = parent.child(local);
      if (n != null) {
        n.children
          ..clear()
          ..add(XmlText('$v'));
      }
    }

    if (c.resolution != null && c.resolution!.contains('×')) {
      final wh = c.resolution!.split('×');
      setText(cfg.child('Resolution'), 'Width', wh[0]);
      setText(cfg.child('Resolution'), 'Height', wh[1]);
    }
    setText(cfg.child('RateControl'), 'FrameRateLimit', c.fps);
    setText(cfg.child('RateControl'), 'BitrateLimit', c.bitrateKbps);
    final before = _toConfig(e, '');
    if (c.gopSeconds != null && c.gopSeconds != before.gopSeconds) {
      final gov = cfg.child('H264')?.number('GovLength')?.round();
      final fps = c.fps ?? before.fps ?? 1;
      final inSeconds = gov != null && gov < (before.fps ?? 1);
      setText(
        cfg.child('H264'),
        'GovLength',
        inSeconds ? c.gopSeconds : c.gopSeconds! * fps,
      );
    }
    // Re-serialise with the tt namespace on every child.
    final inner = cfg.children.map(_withSchemaPrefix).join();
    final attrs = cfg.attributes
        .where((a) => !a.name.qualified.startsWith('xmlns'))
        .map((a) => ' ${a.name.local}="${OnvifSoap.esc(a.value)}"')
        .join();
    await _soap.call(
      _media!,
      '<trt:SetVideoEncoderConfiguration>'
      '<trt:Configuration$attrs>$inner</trt:Configuration>'
      '<trt:ForcePersistence>true</trt:ForcePersistence>'
      '</trt:SetVideoEncoderConfiguration>',
    );
    // Refresh our copy of the profiles.
    final p = await _soap.call(_media!, '<trt:GetProfiles/>');
    _profiles
      ..clear()
      ..addAll(p.findAllElements('Profiles', namespaceUri: '*'));
    return false;
  });

  static bool _same(VideoEncoderConfig a, VideoEncoderConfig b) =>
      a.codec == b.codec &&
      a.resolution == b.resolution &&
      a.fps == b.fps &&
      a.bitrateKbps == b.bitrateKbps &&
      a.bitrateMode == b.bitrateMode &&
      a.gopSeconds == b.gopSeconds &&
      a.quality == b.quality &&
      a.audioEnabled == b.audioEnabled;

  static int _sanitizeMaxFps(int? reported, int? current) {
    final r = (reported == null || reported < 1 || reported > 120)
        ? 30
        : reported;
    final c = current ?? 0;
    return (r > c ? r : c).clamp(1, 60);
  }

  /// Serialises a node, forcing elements into the `tt:` (schema) prefix.
  static String _withSchemaPrefix(XmlNode n) {
    if (n is XmlText) return OnvifSoap.esc(n.value);
    if (n is! XmlElement) return '';
    final name = 'tt:${n.name.local}';
    final attrs = n.attributes
        .where((a) => !a.name.qualified.startsWith('xmlns'))
        .map((a) => ' ${a.name.local}="${OnvifSoap.esc(a.value)}"')
        .join();
    return '<$name$attrs>${n.children.map(_withSchemaPrefix).join()}</$name>';
  }

  // Imaging levels are normalised to 0–100 using the camera's ranges.
  final _ranges = <String, (double, double)>{};

  @override
  Future<ImageSettings> image() => _guard(() async {
    final src = _videoSourceToken;
    if (_imaging == null || src == null) return const ImageSettings();
    try {
      final o = await _soap.call(
        _imaging!,
        '<timg:GetOptions><timg:VideoSourceToken>${OnvifSoap.esc(src)}</timg:VideoSourceToken></timg:GetOptions>',
      );
      for (final k in [
        'Brightness',
        'Contrast',
        'ColorSaturation',
        'Sharpness',
      ]) {
        final r = o.el(k);
        final min = r?.number('Min');
        final max = r?.number('Max');
        if (min != null && max != null && max > min) _ranges[k] = (min, max);
      }
    } on OnvifFault {
      // No options: assume 0–100.
    }
    final b = await _soap.call(
      _imaging!,
      '<timg:GetImagingSettings><timg:VideoSourceToken>${OnvifSoap.esc(src)}</timg:VideoSourceToken></timg:GetImagingSettings>',
    );
    final s = b.el('ImagingSettings');
    double? norm(String k) {
      final v = s?.child(k) == null
          ? null
          : double.tryParse(s!.child(k)!.innerText.trim());
      if (v == null) return null;
      final (min, max) = _ranges[k] ?? (0.0, 100.0);
      return ((v - min) / (max - min) * 100).clamp(0, 100);
    }

    return ImageSettings(
      brightness: norm('Brightness'),
      contrast: norm('Contrast'),
      saturation: norm('ColorSaturation'),
      sharpness: norm('Sharpness'),
    );
  });

  @override
  Future<void> setImage(ImageSettings s) => _guard(() async {
    final src = _videoSourceToken;
    if (_imaging == null || src == null) return;
    String f(String k, double? v) {
      if (v == null) return '';
      final (min, max) = _ranges[k] ?? (0.0, 100.0);
      final raw = min + (v.clamp(0, 100) / 100) * (max - min);
      return '<tt:$k>${raw.toStringAsFixed(1)}</tt:$k>';
    }

    await _soap.call(
      _imaging!,
      '<timg:SetImagingSettings><timg:VideoSourceToken>${OnvifSoap.esc(src)}</timg:VideoSourceToken>'
      '<timg:ImagingSettings>${f('Brightness', s.brightness)}'
      '${f('ColorSaturation', s.saturation)}${f('Contrast', s.contrast)}'
      '${f('Sharpness', s.sharpness)}</timg:ImagingSettings>'
      '<timg:ForcePersistence>true</timg:ForcePersistence></timg:SetImagingSettings>',
    );
  });

  @override
  Future<DateTime?> time() => _guard(() async {
    final b = await _soap.call(_device, '<tds:GetSystemDateAndTime/>');
    return _utc(b.el('UTCDateTime'))?.toLocal();
  });

  @override
  Future<void> setTime(DateTime localTime) => _guard(() async {
    final u = localTime.toUtc();
    await _soap.call(
      _device,
      '<tds:SetSystemDateAndTime><tds:DateTimeType>Manual</tds:DateTimeType>'
      '<tds:DaylightSavings>false</tds:DaylightSavings>'
      '<tds:UTCDateTime><tt:Date><tt:Year>${u.year}</tt:Year><tt:Month>${u.month}</tt:Month>'
      '<tt:Day>${u.day}</tt:Day></tt:Date><tt:Time><tt:Hour>${u.hour}</tt:Hour>'
      '<tt:Minute>${u.minute}</tt:Minute><tt:Second>${u.second}</tt:Second></tt:Time>'
      '</tds:UTCDateTime></tds:SetSystemDateAndTime>',
    );
    _soap.timeOffset = Duration.zero;
  });

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) => _guard(() async {
    // Keep the user's existing level.
    final users = await _soap.call(_device, '<tds:GetUsers/>');
    var level = 'Administrator';
    for (final u in users.findAllElements('User', namespaceUri: '*')) {
      if (u.textOf('Username') == _username)
        level = u.textOf('UserLevel') ?? level;
    }
    await _soap.call(
      _device,
      '<tds:SetUser><tds:User><tt:Username>${OnvifSoap.esc(_username)}</tt:Username>'
      '<tt:Password>${OnvifSoap.esc(newPassword)}</tt:Password>'
      '<tt:UserLevel>$level</tt:UserLevel></tds:User></tds:SetUser>',
    );
  });

  @override
  Future<void> reboot() =>
      _guard(() async => _soap.call(_device, '<tds:SystemReboot/>'));

  @override
  Future<void> ptz(PtzMove move, {double speed = 0.5}) => _guard(() async {
    final token = _ptzProfileToken;
    if (_ptz == null || token == null) return;
    final v = speed.clamp(0.1, 1.0).toStringAsFixed(2);
    final (x, y, z) = switch (move) {
      PtzMove.left => ('-$v', '0', null),
      PtzMove.right => (v, '0', null),
      PtzMove.up => ('0', v, null),
      PtzMove.down => ('0', '-$v', null),
      PtzMove.zoomIn => (null, null, v),
      PtzMove.zoomOut => (null, null, '-$v'),
    };
    await _soap.call(
      _ptz!,
      '<tptz:ContinuousMove><tptz:ProfileToken>${OnvifSoap.esc(token)}</tptz:ProfileToken>'
      '<tptz:Velocity>${x == null ? '' : '<tt:PanTilt x="$x" y="$y"/>'}'
      '${z == null ? '' : '<tt:Zoom x="$z"/>'}</tptz:Velocity></tptz:ContinuousMove>',
    );
  });

  @override
  Future<void> ptzStop() => _guard(() async {
    final token = _ptzProfileToken;
    if (_ptz == null || token == null) return;
    await _soap.call(
      _ptz!,
      '<tptz:Stop><tptz:ProfileToken>${OnvifSoap.esc(token)}</tptz:ProfileToken>'
      '<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>',
    );
  });

  @override
  Future<void> close() async => _soap.close();
}
