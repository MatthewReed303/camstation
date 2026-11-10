import 'dart:convert';
import 'dart:io';

import 'package:camstation/core/cameras/camera.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where camera passwords live. Never on disk in plaintext.
abstract interface class SecretStore {
  Future<String?> read(String cameraId);
  Future<void> write(String cameraId, String password);
  Future<void> delete(String cameraId);
}

/// Android Keystore / Windows Credential Manager / Linux Secret Service.
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;
  static String _key(String id) => 'camera.$id.password';

  @override
  Future<String?> read(String cameraId) => _s.read(key: _key(cameraId));

  @override
  Future<void> write(String cameraId, String password) =>
      _s.write(key: _key(cameraId), value: password);

  @override
  Future<void> delete(String cameraId) => _s.delete(key: _key(cameraId));
}

class MemorySecretStore implements SecretStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String cameraId) async => _m[cameraId];
  @override
  Future<void> write(String cameraId, String password) async =>
      _m[cameraId] = password;
  @override
  Future<void> delete(String cameraId) async => _m.remove(cameraId);
}

/// Camera list (metadata only) as a small JSON file in app-private storage.
/// A database would be overkill for tens of cameras.
class CameraStore {
  CameraStore(this.file);
  final File file;

  Future<List<Camera>> load() async {
    if (!file.existsSync()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final j = jsonDecode(raw) as Map<String, Object?>;
    return [
      for (final c in (j['cameras'] as List?) ?? const [])
        Camera.fromJson(c as Map<String, Object?>),
    ];
  }

  /// Atomic write: temp file + rename, so a crash never leaves half a file.
  Future<void> save(List<Camera> cameras) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'cameras': [for (final c in cameras) c.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
