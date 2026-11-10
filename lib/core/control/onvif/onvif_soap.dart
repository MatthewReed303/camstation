import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// ONVIF namespaces used in requests.
const nsDevice = 'http://www.onvif.org/ver10/device/wsdl';
const nsMedia = 'http://www.onvif.org/ver10/media/wsdl';
const nsImaging = 'http://www.onvif.org/ver20/imaging/wsdl';
const nsPtz = 'http://www.onvif.org/ver20/ptz/wsdl';
const nsSchema = 'http://www.onvif.org/ver10/schema';

class OnvifFault implements Exception {
  OnvifFault(this.message, {this.status, this.isAuth = false});
  final String message;
  final int? status;
  final bool isAuth;
  @override
  String toString() => message;
}

/// Minimal SOAP 1.2 transport with WS-Security UsernameToken (digest).
///
/// The digest includes a timestamp, and cameras reject it when their clock
/// differs from ours, so [timeOffset] (camera minus local) is applied.
class OnvifSoap {
  OnvifSoap({
    required this.username,
    required this.password,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String username;
  final String password;
  final http.Client _client;
  Duration timeOffset = Duration.zero;

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String isoUtc(DateTime t) {
    final u = t.toUtc();
    return '${u.year}-${_two(u.month)}-${_two(u.day)}T${_two(u.hour)}:'
        '${_two(u.minute)}:${_two(u.second)}Z';
  }

  /// PasswordDigest = Base64(SHA1(nonce + created + password)).
  static String digest(List<int> nonce, String created, String password) =>
      base64.encode(
        sha1.convert([...nonce, ...utf8.encode(created + password)]).bytes,
      );

  String _security() {
    final r = Random.secure();
    final nonce = List<int>.generate(16, (_) => r.nextInt(256));
    final created = isoUtc(DateTime.now().add(timeOffset));
    return '<s:Header><wsse:Security s:mustUnderstand="1" '
        'xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" '
        'xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
        '<wsse:UsernameToken><wsse:Username>${_esc(username)}</wsse:Username>'
        '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">'
        '${digest(nonce, created, password)}</wsse:Password>'
        '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-soap-message-security-1.0#Base64Binary">'
        '${base64.encode(nonce)}</wsse:Nonce>'
        '<wsu:Created>$created</wsu:Created></wsse:UsernameToken>'
        '</wsse:Security></s:Header>';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String esc(String s) => _esc(s);

  /// Sends [body] (already namespaced, e.g. `<tds:GetDeviceInformation/>`)
  /// and returns the parsed SOAP Body element.
  Future<XmlElement> call(
    Uri url,
    String body, {
    bool auth = true,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final env =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:tds="$nsDevice" xmlns:trt="$nsMedia" xmlns:timg="$nsImaging" '
        'xmlns:tptz="$nsPtz" xmlns:tt="$nsSchema">'
        '${auth ? _security() : ''}<s:Body>$body</s:Body></s:Envelope>';
    final r = await _client
        .post(
          url,
          headers: {'Content-Type': 'application/soap+xml; charset=utf-8'},
          body: utf8.encode(env),
        )
        .timeout(timeout);
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException {
      throw OnvifFault(
        'Not an ONVIF reply (HTTP ${r.statusCode})',
        status: r.statusCode,
        isAuth: r.statusCode == 401,
      );
    }
    final bodyEl = doc.findAllElements('Body', namespaceUri: '*').firstOrNull;
    if (bodyEl == null) throw OnvifFault('Malformed SOAP reply');
    final fault = bodyEl
        .findAllElements('Fault', namespaceUri: '*')
        .firstOrNull;
    if (fault != null || r.statusCode >= 400) {
      final reason =
          fault
              ?.findAllElements('Text', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          'HTTP ${r.statusCode}';
      final codes = fault == null
          ? ''
          : fault
                .findAllElements('Value', namespaceUri: '*')
                .map((e) => e.innerText)
                .join(' ');
      final auth =
          r.statusCode == 401 ||
          RegExp(
            // `Sender` is the generic client-error code: only NotAuthorized
            // (or HTTP 401) means bad credentials.
            'NotAuthorized|not authori[sz]ed',
            caseSensitive: false,
          ).hasMatch('$codes $reason');
      final detail = codes.isEmpty ? '' : ' [$codes]';
      throw OnvifFault(
        '${reason.trim()}$detail',
        status: r.statusCode,
        isAuth: auth,
      );
    }
    return bodyEl;
  }

  void close() => _client.close();
}

/// Helpers for reading ONVIF replies regardless of namespace prefixes.
extension OnvifXml on XmlElement {
  XmlElement? el(String local) =>
      findAllElements(local, namespaceUri: '*').firstOrNull;

  XmlElement? child(String local) =>
      findElements(local, namespaceUri: '*').firstOrNull;

  String? textOf(String local) => el(local)?.innerText.trim();

  double? number(String local) => double.tryParse(textOf(local) ?? '');
}
