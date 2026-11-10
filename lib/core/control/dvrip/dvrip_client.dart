import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// DVRIP ("Sofia") control protocol over TCP 34567.
///
/// Packet: 20-byte little-endian header
///   [0]=0xFF magic, [1]=version, [4..8]=session, [8..12]=sequence,
///   [14..16]=message id, [16..20]=payload length
/// then a JSON payload terminated by "\n\0". Each request gets exactly one
/// reply (header + full body). Message ids and payloads follow
/// OpenIPC/python-dvr.
class DvripClient {
  DvripClient(this.host, {this.port = 34567});

  final String host;
  final int port;

  static const msgLogin = 1000;
  static const msgLogout = 1001;
  static const msgKeepAlive = 1006;
  static const msgSystemInfo = 1020;
  static const msgConfigSet = 1040;
  static const msgConfigGet = 1042;
  static const msgConfigDefault = 1044;
  static const msgAbility = 1360;
  static const msgPtz = 1400;
  static const msgOpMachine = 1450; // also OPTimeSetting
  static const msgTimeQuery = 1452;
  static const msgModifyPassword = 1488;

  /// Ret codes that mean success (150 = OK, restart required).
  static const okCodes = {100, 150, 515};

  static const _codes = {
    101: 'Unknown error',
    102: 'Unsupported version',
    103: 'Request not permitted',
    104: 'User already logged in',
    105: 'User is not logged in',
    106: 'Wrong username or password',
    107: 'No permission',
    108: 'Timeout',
    117: 'Message format error',
    118: 'PTZ protocol not set',
    124: 'Login method not supported by this client',
    202: 'User not logged in',
    203: 'Wrong username or password',
    204: 'User is invalid',
    205: 'Locked after too many failed logins; wait and retry',
    206: 'User is blacklisted',
    207: 'Blacklisted',
    208: 'Input is invalid',
  };

  Socket? _socket;
  final _rx = BytesBuilder(copy: false);
  final _waiters = <Completer<void>>[];
  int _session = 0;
  int _seq = 0;
  Timer? _keepAlive;
  Future<void> _queue = Future.value();
  bool _closed = false;

  bool get isLoggedIn => _session != 0 && _socket != null;

  /// DVRIP password hash: MD5, then 8 chars from summed byte pairs mod 62.
  static String sofiaHash(String password) {
    const chars =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    final d = md5.convert(utf8.encode(password)).bytes;
    return String.fromCharCodes([
      for (var i = 0; i < 16; i += 2) chars.codeUnitAt((d[i] + d[i + 1]) % 62),
    ]);
  }

  static Uint8List encode(int session, int seq, int msg, Object? body) {
    final payload = body == null
        ? Uint8List(0)
        : Uint8List.fromList([...utf8.encode(jsonEncode(body)), 0x0A, 0x00]);
    final h = ByteData(20)
      ..setUint8(0, 0xFF)
      ..setUint32(4, session, Endian.little)
      ..setUint32(8, seq, Endian.little)
      ..setUint16(14, msg, Endian.little)
      ..setUint32(16, payload.length, Endian.little);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...payload]);
  }

  /// Decodes a reply body: JSON with a trailing "\n\0", sometimes with stray
  /// control characters inside strings.
  static Map<String, Object?> decodeBody(List<int> body) {
    final clean = body
        .where((b) => b >= 32 || b == 9 || b == 10 || b == 13)
        .toList();
    final text = latin1.decode(clean).trim();
    if (text.isEmpty) return const {};
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end < start) return {'_raw': text};
    // Latin-1 → bytes → UTF-8 keeps non-ASCII names intact.
    final s = utf8.decode(
      latin1.encode(text.substring(start, end + 1)),
      allowMalformed: true,
    );
    return jsonDecode(s) as Map<String, Object?>;
  }

  Future<void> _connect() async {
    final s = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _closed = false;
    s.listen(
      (data) {
        _rx.add(data);
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      onError: (Object _) {
        _closed = true;
        _wake();
      },
    );
  }

  void _wake() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<Uint8List> _read(int n, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_rx.length < n) {
      if (_closed) throw const SocketException('connection closed');
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('DVRIP reply timeout');
      final w = Completer<void>();
      _waiters.add(w);
      await w.future.timeout(left, onTimeout: () {});
    }
    final all = _rx.takeBytes();
    final out = Uint8List.sublistView(all, 0, n);
    if (all.length > n) _rx.add(Uint8List.sublistView(all, n));
    return Uint8List.fromList(out);
  }

  /// Sends one request and returns the decoded reply. Requests are
  /// serialised: the protocol has one reply per request, in order.
  Future<Map<String, Object?>> request(
    int msg,
    Map<String, Object?>? body, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    final c = Completer<Map<String, Object?>>();
    _queue = _queue.then((_) async {
      try {
        final s = _socket;
        if (s == null) throw const SocketException('not connected');
        s.add(encode(_session, _seq++, msg, body));
        await s.flush();
        final head = ByteData.sublistView(await _read(20, timeout));
        if (head.getUint8(0) != 0xFF) throw const FormatException('bad magic');
        final sid = head.getUint32(4, Endian.little);
        if (sid != 0) _session = sid;
        final len = head.getUint32(16, Endian.little);
        c.complete(decodeBody(await _read(len, timeout)));
      } on Object catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  String get _sid =>
      '0x${_session.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static int? _ret(Map<String, Object?> r) => r['Ret'] as int?;

  static void _check(Map<String, Object?> r, String what) {
    final ret = _ret(r);
    if (ret != null && !okCodes.contains(ret)) {
      throw DvripException(ret, '$what: ${_codes[ret] ?? 'error $ret'}');
    }
  }

  /// Connects and logs in. Throws [DvripException] on bad credentials or
  /// unsupported login methods.
  Future<void> login(String user, String password) async {
    await _connect();
    final r = await request(msgLogin, {
      'EncryptType': 'MD5',
      'LoginType': 'DVRIP-Web',
      'PassWord': sofiaHash(password),
      'UserName': user,
    });
    _check(r, 'Login');
    _session = int.parse(
      ((r['SessionID'] as String?) ?? '0').replaceFirst(RegExp('^0x'), ''),
      radix: 16,
    );
    final alive = (r['AliveInterval'] as int?) ?? 20;
    _keepAlive = Timer.periodic(Duration(seconds: alive.clamp(5, 60)), (_) {
      request(msgKeepAlive, {
        'Name': 'KeepAlive',
        'SessionID': _sid,
      }).catchError((Object _) => <String, Object?>{});
    });
  }

  /// Reads a config section, e.g. `Simplify.Encode`, `Camera.Param`.
  Future<Object?> getConfig(String name, {bool defaults = false}) async {
    final r = await request(defaults ? msgConfigDefault : msgConfigGet, {
      'Name': name,
      'SessionID': _sid,
    });
    _check(r, 'Read $name');
    return r[name];
  }

  /// Writes a config section. Returns true when the camera needs a restart.
  Future<bool> setConfig(String name, Object? value) async {
    final r = await request(msgConfigSet, {
      'Name': name,
      'SessionID': _sid,
      name: value,
    });
    _check(r, 'Save $name');
    return _ret(r) == 150;
  }

  /// Capability tables, e.g. `EncodeCapability`, `SystemFunction`.
  Future<Object?> getAbility(String name) async {
    final r = await request(msgAbility, {'Name': name, 'SessionID': _sid});
    _check(r, 'Read $name');
    return r[name];
  }

  Future<Map<String, Object?>> systemInfo() async {
    final r = await request(msgSystemInfo, {
      'Name': 'SystemInfo',
      'SessionID': _sid,
    });
    _check(r, 'Read SystemInfo');
    return (r['SystemInfo'] as Map<String, Object?>?) ?? const {};
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<DateTime?> getTime() async {
    final r = await request(msgTimeQuery, {
      'Name': 'OPTimeQuery',
      'SessionID': _sid,
    });
    _check(r, 'Read time');
    return DateTime.tryParse('${r['OPTimeQuery']}'.replaceFirst(' ', 'T'));
  }

  /// Sets the camera clock (local time, as the camera has no time zone
  /// awareness in this call).
  Future<void> setTime(DateTime localTime) async {
    final r = await request(msgOpMachine, {
      'Name': 'OPTimeSetting',
      'SessionID': _sid,
      'OPTimeSetting': _fmt(localTime),
    });
    _check(r, 'Set time');
  }

  Future<void> changePassword({
    required String user,
    required String oldPassword,
    required String newPassword,
  }) async {
    final r = await request(msgModifyPassword, {
      'EncryptType': 'MD5',
      'NewPassWord': sofiaHash(newPassword),
      'PassWord': sofiaHash(oldPassword),
      'SessionID': _sid,
      'UserName': user,
    });
    _check(r, 'Change password');
  }

  /// PTZ command, e.g. `DirectionUp`, `ZoomTile`, `GotoPreset`. Movement
  /// continues until the same command is sent with `stop: true`
  /// (Preset -1, Step 0) or another command.
  Future<void> ptz(
    String command, {
    int channel = 0,
    int step = 5,
    int preset = -1,
    bool stop = false,
  }) async {
    final r = await request(msgPtz, {
      'Name': 'OPPTZControl',
      'SessionID': _sid,
      'OPPTZControl': {
        'Command': command,
        'Parameter': {
          'AUX': {'Number': 0, 'Status': 'On'},
          'Channel': channel,
          'MenuOpts': 'Enter',
          'Pattern': stop ? 'Stop' : 'Start',
          'Preset': preset,
          'Step': stop ? 0 : step,
          'Tour': command.contains('Tour') ? 1 : 0,
        },
      },
    });
    _check(r, 'PTZ');
  }

  /// Reboots. The camera acknowledges, then reboots ~10 s later, and
  /// *cancels* the reboot if this connection closes first, so we hold the
  /// connection until the camera drops it (or [wait] passes).
  Future<void> reboot({Duration wait = const Duration(seconds: 20)}) async {
    final r = await request(msgOpMachine, {
      'Name': 'OPMachine',
      'SessionID': _sid,
      'OPMachine': {'Action': 'Reboot'},
    });
    _check(r, 'Reboot');
    _keepAlive?.cancel();
    final deadline = DateTime.now().add(wait);
    while (!_closed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await close(logout: false);
  }

  Future<void> close({bool logout = true}) async {
    _keepAlive?.cancel();
    _keepAlive = null;
    if (logout && isLoggedIn && !_closed) {
      try {
        await request(msgLogout, {
          'Name': '',
          'SessionID': _sid,
        }, timeout: const Duration(seconds: 2));
      } on Object {
        // best effort
      }
    }
    await _socket?.close();
    _socket?.destroy();
    _socket = null;
    _session = 0;
  }
}

class DvripException implements Exception {
  DvripException(this.code, this.message);
  final int code;
  final String message;

  bool get isAuth => code == 106 || code == 203 || code == 204;
  bool get isLocked => code == 205;

  @override
  String toString() => message;
}
