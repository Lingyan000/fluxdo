import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 签署固定结构的资源摘要。设计依据: docs/plugins/automatic-updates.md 的发布者信任约定。
class MetaversePackageSignature {
  const MetaversePackageSignature(this.fingerprint, {this.previousFingerprint});
  final String fingerprint;
  final String? previousFingerprint;

  static MetaversePackageSignature? verify(Map<String, dynamic> bundle) {
    final raw = bundle['publisher'];
    if (raw == null) return null;
    if (raw is! Map || raw['algorithm'] != 'RSA-SHA256') {
      throw const FormatException('插件签名格式无效');
    }
    final key = _key(raw['key']);
    final fingerprint = _fingerprint(raw['key'] as Map);
    final manifest = bundle['manifest'] as Map;
    final files = bundle['files'] as Map;
    final payload = utf8.encode(
      'fluxdo-package-v1\n${sha256.convert(utf8.encode(_canonical(manifest)))}\n'
      '${sha256.convert(utf8.encode(files[manifest['ui']] as String))}\n'
      '${sha256.convert(utf8.encode(files[manifest['script']] as String))}\n',
    );
    _check(key, payload, raw['signature']);
    String? previous;
    if (raw.containsKey('rotation')) {
      final rotation = raw['rotation'];
      if (rotation is! Map) throw const FormatException('插件密钥轮换无效');
      _check(
        _key(rotation['key']),
        utf8.encode('fluxdo-key-v1\n$fingerprint\n'),
        rotation['signature'],
      );
      previous = _fingerprint(rotation['key'] as Map);
    }
    return MetaversePackageSignature(
      fingerprint,
      previousFingerprint: previous,
    );
  }

  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(value[k])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonical).join(',')}]';
    if (value is num && (value is! int || value.abs() > 9007199254740991)) {
      throw const FormatException('签名清单包含非整数');
    }
    return jsonEncode(value);
  }

  static Uint8List _bytes(Object? value, int max) {
    if (value is! String ||
        value.length > max * 2 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw const FormatException('签名编码无效');
    }
    final bytes = base64Url.decode(base64Url.normalize(value));
    if (bytes.length > max) throw const FormatException('签名编码过长');
    return bytes;
  }

  static RSAPublicKey _key(Object? raw) {
    if (raw is! Map || raw['kty'] != 'RSA') {
      throw const FormatException('发布者公钥无效');
    }
    BigInt number(Object? value, int max) => BigInt.parse(
      _bytes(value, max).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
    final n = number(raw['n'], 512), e = number(raw['e'], 4);
    if (n.bitLength < 2048 || n.bitLength > 4096 || e != BigInt.from(65537)) {
      throw const FormatException('发布者公钥参数无效');
    }
    return RSAPublicKey(n, e);
  }

  static String _fingerprint(Map key) => sha256
      .convert(
        utf8.encode(_canonical({'kty': 'RSA', 'n': key['n'], 'e': key['e']})),
      )
      .toString();
  static void _check(RSAPublicKey key, List<int> message, Object? signature) {
    final signer = Signer('SHA-256/RSA')
      ..init(false, PublicKeyParameter<RSAPublicKey>(key));
    if (!signer.verifySignature(
      Uint8List.fromList(message),
      RSASignature(_bytes(signature, 512)),
    )) {
      throw const FormatException('插件签名校验失败');
    }
  }
}
