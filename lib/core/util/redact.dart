/// Masks credentials in any text before it is logged or shown.
///
/// Covers the forms seen in practice:
/// - URL userinfo: `rtsp://user:pass@host` → `rtsp://***@host`
/// - Query/path params: `password=…`, `pass=…`, `pwd=…` (DVRIP-style RTSP puts the
///   password, or its Sofia hash, in the path: `/user=admin&password=xyz&channel=1`)
/// - Basic auth headers.
/// - Any extra secrets registered at runtime (e.g. the engine API password).
final class Redactor {
  Redactor._();

  static final Set<String> _secrets = <String>{};

  static final RegExp _userinfo = RegExp(r'://[^/@\s]+@');
  static final RegExp _passParam = RegExp(
    // Lookbehind instead of \b: `_` counts as a word char, and go2rtc logs
    // render credential-in-path RTSP URLs as `user=admin_password=…`.
    r'(?<![A-Za-z0-9])(password|passwd|pass|pwd)=[^&\s;_/#]*',
    caseSensitive: false,
  );
  static final RegExp _basicAuth = RegExp(
    r'(Authorization:\s*Basic\s+)\S+',
    caseSensitive: false,
  );

  /// Registers a runtime secret (e.g. generated engine password) so it is
  /// masked wherever it appears. Short values are ignored to avoid masking
  /// common substrings.
  static void addSecret(String secret) {
    if (secret.length >= 6) _secrets.add(secret);
  }

  static void removeSecret(String secret) => _secrets.remove(secret);

  static String redact(String input) {
    var out = input
        .replaceAll(_userinfo, '://***@')
        .replaceAllMapped(_passParam, (m) => '${m[1]}=***')
        .replaceAllMapped(_basicAuth, (m) => '${m[1]}***');
    for (final s in _secrets) {
      out = out.replaceAll(s, '***');
    }
    return out;
  }
}
