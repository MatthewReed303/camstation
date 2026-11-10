import 'package:camstation/core/control/camera_control.dart';
import 'package:camstation/core/control/dvrip/dvrip_client.dart';

/// [CameraControl] over DVRIP. Config sections: `Simplify.Encode` (video and
/// audio per stream), `Camera.Param` (image), plus capability tables
/// `EncodeCapability`.
class DvripControl implements CameraControl {
  DvripControl({
    required String host,
    required this.username,
    required this.password,
    int port = 34567,
    this.channel = 0,
  }) : _client = DvripClient(host, port: port);

  final String username;
  final String password;
  final int channel;
  final DvripClient _client;

  Map<String, Object?> _encodeCap = const {};
  Set<ControlFeature> _features = const {};

  /// DVRIP capture-size enum (bit index in ResolutionMask) → config name.
  /// From the vendor SDK header (`SDK_CAPTURE_SIZE_*`).
  static const resolutionBits = <int, String>{
    0: 'D1',
    1: 'HD1',
    2: 'BCIF',
    3: 'CIF',
    4: 'QCIF',
    5: 'VGA',
    6: 'QVGA',
    7: 'SVCD',
    8: 'QQVGA',
    9: 'ND1',
    10: '650TVL',
    11: '720P',
    12: '1_3M',
    13: 'UXGA',
    14: '1080P',
    15: 'WUXGA',
    16: '2_5M',
    17: '3M',
    18: '5M',
    19: '1080N',
    20: '4M',
    21: '6M',
    22: '8M',
    23: '12M',
    24: '4K',
    25: '720N',
    26: 'WSVGA',
    27: 'NHD',
    28: '3M_N',
    29: '4M_N',
    30: '5M_N',
    31: '4K_N',
  };

  /// Human-readable sizes for the picker.
  static const resolutionSizes = <String, String>{
    'D1': '720×576',
    'HD1': '352×576',
    'BCIF': '720×288',
    'CIF': '352×288',
    'QCIF': '176×144',
    'VGA': '640×480',
    'QVGA': '320×240',
    'SVCD': '480×480',
    'QQVGA': '160×128',
    'ND1': '240×192',
    '650TVL': '926×576',
    '720P': '1280×720',
    '1_3M': '1280×960',
    'UXGA': '1600×1200',
    '1080P': '1920×1080',
    'WUXGA': '1920×1200',
    '2_5M': '1872×1408',
    '3M': '2048×1536',
    '5M': '3744×1408',
    '1080N': '960×1080',
    '4M': '2592×1520',
    '6M': '3072×2048',
    '8M': '3264×2448',
    '12M': '4000×3000',
    '4K': '3840×2160',
    '720N': '640×720',
    'WSVGA': '1024×576',
    'NHD': '640×360',
  };

  /// Compression enum bit → codec (`SDK_CAPTURE_COMP_*`).
  static const codecBits = <int, String>{
    0: 'DIVX_MPEG4',
    1: 'MS_MPEG4',
    2: 'MPEG2',
    3: 'MPEG1',
    4: 'H.263',
    5: 'MJPG',
    6: 'FCC_MPEG4',
    7: 'H.264',
    8: 'H.265',
  };

  static List<String> decodeMask(Object? mask, Map<int, String> table) {
    final v = int.tryParse(
      '${mask ?? 0}'.replaceFirst(RegExp('^0[xX]'), ''),
      radix: 16,
    );
    if (v == null) return const [];
    return [
      for (final e in table.entries)
        if (v & (1 << e.key) != 0) e.value,
    ];
  }

  static const _streams = {
    'MainFormat': ('Main stream (HD)', 'MainStream'),
    'ExtraFormat': ('Sub stream (SD)', 'ExtraStream2'),
  };

  @override
  String get protocol => 'DVRIP';

  @override
  Set<ControlFeature> get features => _features;

  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on DvripException catch (e) {
      throw ControlException(e.message, isAuth: e.isAuth);
    }
  }

  @override
  Future<void> connect() => _guard(() async {
    await _client.login(username, password);
    try {
      _encodeCap =
          (await _client.getAbility('EncodeCapability')
              as Map<String, Object?>?) ??
          const {};
    } on Object {
      _encodeCap = const {};
    }
    Map<String, Object?> fn = const {};
    try {
      fn =
          (await _client.getAbility('SystemFunction')
              as Map<String, Object?>?) ??
          const {};
    } on Object {
      // older firmware: assume the basics
    }
    _features = {
      ControlFeature.video,
      ControlFeature.audioToggle,
      ControlFeature.image,
      ControlFeature.time,
      ControlFeature.password,
      ControlFeature.reboot,
      // PTZ: DVRIP has no reliable capability flag; ONVIF PTZ covers it.
    };
  });

  @override
  Future<DeviceInfo> deviceInfo() => _guard(() async {
    final i = await _client.systemInfo();
    String? name;
    try {
      final g =
          await _client.getConfig('General.General') as Map<String, Object?>?;
      name = g?['MachineName'] as String?;
    } on Object {
      // optional
    }
    return DeviceInfo(
      model: (i['DeviceModel'] ?? i['HardWare']) as String?,
      firmware: i['SoftWareVersion'] as String?,
      name: name,
    );
  });

  Future<List<Map<String, Object?>>> _encode() async {
    final all = await _client.getConfig('Simplify.Encode') as List<Object?>?;
    if (all == null || all.length <= channel) {
      throw ControlException('Camera returned no encoder settings');
    }
    return [for (final c in all) Map<String, Object?>.from(c! as Map)];
  }

  @override
  Future<List<VideoEncoderConfig>> encoders() => _guard(() async {
    final ch = (await _encode())[channel];
    return [
      for (final e in _streams.entries)
        if (ch[e.key] case final Map<String, Object?> f)
          _toConfig(e.key, e.value.$1, f),
    ];
  });

  static VideoEncoderConfig _toConfig(
    String id,
    String label,
    Map<String, Object?> f,
  ) {
    final v = (f['Video'] as Map<String, Object?>?) ?? const {};
    return VideoEncoderConfig(
      id: id,
      label: label,
      codec: v['Compression'] as String?,
      resolution: v['Resolution'] as String?,
      fps: v['FPS'] as int?,
      bitrateKbps: v['BitRate'] as int?,
      bitrateMode: v['BitRateControl'] as String?,
      gopSeconds: v['GOP'] as int?,
      quality: v['Quality'] as int?,
      audioEnabled: f['AudioEnable'] as bool?,
    );
  }

  @override
  Future<VideoEncoderOptions> encoderOptions(String encoderId) async {
    final type = _streams[encoderId]?.$2;
    Map<String, Object?>? info;
    for (final e in (_encodeCap['EncodeInfo'] as List<Object?>?) ?? const []) {
      final m = e! as Map<String, Object?>;
      if (m['StreamType'] == type) info = m;
    }
    final maxBitrate = (_encodeCap['MaxBitrate'] as int?) ?? 16384;
    return VideoEncoderOptions(
      codecs: decodeMask(
        info?['CompressionMask'],
        codecBits,
      ).where((c) => c == 'H.264' || c == 'H.265').toList(),
      resolutions: decodeMask(info?['ResolutionMask'], resolutionBits),
      maxFps: 30,
      maxBitrateKbps: maxBitrate.clamp(512, 32768),
      hasAudio: (info?['HaveAudio'] as bool?) ?? true,
    );
  }

  @override
  Future<bool> setEncoder(VideoEncoderConfig c) => _guard(() async {
    // Writing an unchanged config is not harmless: some cameras re-validate
    // and clamp values (e.g. fps above their advertised maximum) on any write.
    final current = (await encoders()).where((x) => x.id == c.id).firstOrNull;
    if (current != null && _same(current, c)) return false;
    // Read-modify-write the whole section so unknown fields are preserved.
    final all = await _encode();
    final ch = Map<String, Object?>.from(all[channel]);
    final f = Map<String, Object?>.from(ch[c.id]! as Map);
    final v = Map<String, Object?>.from(f['Video']! as Map);
    if (c.codec != null) v['Compression'] = c.codec;
    if (c.resolution != null) v['Resolution'] = c.resolution;
    if (c.fps != null) v['FPS'] = c.fps;
    if (c.bitrateKbps != null) v['BitRate'] = c.bitrateKbps;
    if (c.bitrateMode != null) v['BitRateControl'] = c.bitrateMode;
    if (c.gopSeconds != null) v['GOP'] = c.gopSeconds;
    if (c.quality != null) v['Quality'] = c.quality;
    f['Video'] = v;
    if (c.audioEnabled != null) f['AudioEnable'] = c.audioEnabled;
    ch[c.id] = f;
    all[channel] = ch;
    return _client.setConfig('Simplify.Encode', all);
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

  static bool _hexFlag(Object? v) =>
      (int.tryParse(
            '${v ?? 0}'.replaceFirst(RegExp('^0[xX]'), ''),
            radix: 16,
          ) ??
          0) !=
      0;

  static String _hex(bool b) => b ? '0x00000001' : '0x00000000';

  @override
  Future<ImageSettings> image() => _guard(() async {
    final p =
        (await _client.getConfig('Camera.Param') as List<Object?>?)?[channel]
            as Map<String, Object?>?;
    return ImageSettings(
      flip: p == null ? null : _hexFlag(p['PictureFlip']),
      mirror: p == null ? null : _hexFlag(p['PictureMirror']),
    );
  });

  @override
  Future<void> setImage(ImageSettings s) => _guard(() async {
    final all = [
      for (final c
          in (await _client.getConfig('Camera.Param') as List<Object?>?) ??
              const [])
        Map<String, Object?>.from(c! as Map),
    ];
    if (all.length <= channel) throw ControlException('No image settings');
    if (s.flip != null) all[channel]['PictureFlip'] = _hex(s.flip!);
    if (s.mirror != null) all[channel]['PictureMirror'] = _hex(s.mirror!);
    await _client.setConfig('Camera.Param', all);
  });

  @override
  Future<DateTime?> time() => _guard(_client.getTime);

  @override
  Future<void> setTime(DateTime localTime) =>
      _guard(() => _client.setTime(localTime));

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) => _guard(
    () => _client.changePassword(
      user: username,
      oldPassword: oldPassword,
      newPassword: newPassword,
    ),
  );

  @override
  Future<void> reboot() => _guard(_client.reboot);

  static const _ptzCommands = {
    PtzMove.up: 'DirectionUp',
    PtzMove.down: 'DirectionDown',
    PtzMove.left: 'DirectionLeft',
    PtzMove.right: 'DirectionRight',
    PtzMove.zoomIn: 'ZoomTile',
    PtzMove.zoomOut: 'ZoomWide',
  };

  String? _lastPtz;

  @override
  Future<void> ptz(PtzMove move, {double speed = 0.5}) => _guard(() async {
    _lastPtz = _ptzCommands[move];
    await _client.ptz(
      _lastPtz!,
      channel: channel,
      step: (speed * 8).round().clamp(1, 8),
    );
  });

  @override
  Future<void> ptzStop() => _guard(() async {
    final cmd = _lastPtz;
    if (cmd == null) return;
    await _client.ptz(cmd, channel: channel, stop: true);
  });

  @override
  Future<void> close() => _client.close();
}
