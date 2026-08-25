/// RSA-OAEP(SHA-256) 算法（PEM 密钥）。
///
/// - 加密：粘贴**公钥** PEM（`PUBLIC KEY` SPKI / `RSA PUBLIC KEY` PKCS#1）。
/// - 解密：粘贴**私钥** PEM（`PRIVATE KEY` PKCS#8 / `RSA PRIVATE KEY`
///   PKCS#1）。加密私钥（`ENCRYPTED PRIVATE KEY`）不支持。
/// - 长明文自动分块（每块独立 OAEP，块密文 = 模长字节，直接拼接）。
///   这是 fluxdo 的 ENC1 自有约定；单块场景与外部工具 OAEP 输出一致。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../crypto_algorithm.dart';
import 'symmetric_algorithms.dart' show normalizeBase64Input;

/// 解析后的 RSA 密钥（公钥或私钥之一）
sealed class RsaParsedKey {
  const RsaParsedKey();
}

class RsaParsedPublicKey extends RsaParsedKey {
  const RsaParsedPublicKey(this.key);

  final RSAPublicKey key;
}

class RsaParsedPrivateKey extends RsaParsedKey {
  const RsaParsedPrivateKey(this.key);

  final RSAPrivateKey key;
}

/// PEM 文本 → RSA 密钥。
///
/// 支持公钥（SPKI / PKCS#1）与私钥（PKCS#8 / PKCS#1）；
/// 无法识别时抛 [CryptoException]。
RsaParsedKey parseRsaPem(String pemText) {
  final header = RegExp(r'-----BEGIN ([A-Z ]+)-----').firstMatch(pemText);
  if (header == null) {
    throw const CryptoException('未找到 PEM 密钥（缺少 -----BEGIN 行）');
  }
  final label = header.group(1)!.trim();

  final body = pemText
      .replaceAll(RegExp(r'-----[A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  final Uint8List der;
  try {
    der = base64.decode(body);
  } catch (_) {
    throw const CryptoException('PEM 内容不是有效的 Base64');
  }

  switch (label) {
    case 'PUBLIC KEY':
      return RsaParsedPublicKey(_parseSpki(der));
    case 'RSA PUBLIC KEY':
      return RsaParsedPublicKey(_parsePkcs1PublicKey(der));
    case 'PRIVATE KEY':
      return RsaParsedPrivateKey(_parsePkcs8PrivateKey(der));
    case 'RSA PRIVATE KEY':
      return RsaParsedPrivateKey(_parsePkcs1PrivateKey(der));
    case 'ENCRYPTED PRIVATE KEY':
      throw const CryptoException(
          '暂不支持加密私钥，请先用 openssl 去除口令（openssl pkcs8 -topk8 -nocrypt）');
    default:
      throw CryptoException('不支持的 PEM 类型: $label');
  }
}

ASN1Sequence _parseSequence(Uint8List der) {
  final obj = ASN1Parser(der).nextObject();
  if (obj is! ASN1Sequence || obj.elements == null) {
    throw const CryptoException('PEM 结构异常（顶层不是 ASN.1 序列）');
  }
  return obj;
}

BigInt _intAt(ASN1Sequence seq, int index) {
  if (index >= seq.elements!.length) {
    throw const CryptoException('PEM 结构异常（序列元素缺失）');
  }
  final el = seq.elements![index];
  if (el is! ASN1Integer || el.integer == null) {
    throw const CryptoException('PEM 结构异常（预期 INTEGER 字段）');
  }
  return el.integer!;
}

/// SPKI: SEQ{ SEQ{OID, NULL}, BITSTRING{ SEQ{n, e} } }
RSAPublicKey _parseSpki(Uint8List der) {
  final seq = _parseSequence(der);
  if (seq.elements!.length < 2 || seq.elements![1] is! ASN1BitString) {
    throw const CryptoException('公钥 PEM 结构异常');
  }
  final bits = seq.elements![1] as ASN1BitString;
  final inner = Uint8List.fromList(bits.stringValues ?? const []);
  return _parsePkcs1PublicKey(inner);
}

/// PKCS#1 公钥: SEQ{n, e}
RSAPublicKey _parsePkcs1PublicKey(Uint8List der) {
  final seq = _parseSequence(der);
  return RSAPublicKey(_intAt(seq, 0), _intAt(seq, 1));
}

/// PKCS#8: SEQ{ version, SEQ{OID, NULL}, OCTETSTRING{ PKCS#1 私钥 } }
RSAPrivateKey _parsePkcs8PrivateKey(Uint8List der) {
  final seq = _parseSequence(der);
  if (seq.elements!.length < 3 || seq.elements![2] is! ASN1OctetString) {
    throw const CryptoException('私钥 PEM 结构异常');
  }
  final inner = (seq.elements![2] as ASN1OctetString).octets!;
  return _parsePkcs1PrivateKey(inner);
}

/// PKCS#1 私钥: SEQ{ v, n, e, d, p, q, dp, dq, qinv }
RSAPrivateKey _parsePkcs1PrivateKey(Uint8List der) {
  final seq = _parseSequence(der);
  if (seq.elements!.length < 9) {
    throw const CryptoException('私钥 PEM 结构异常（字段缺失）');
  }
  return RSAPrivateKey(
    _intAt(seq, 1),
    _intAt(seq, 3),
    _intAt(seq, 4),
    _intAt(seq, 5),
  );
}

/// RSA-OAEP(SHA-256)。
class RsaOaepAlgorithm extends CryptoAlgorithm {
  const RsaOaepAlgorithm();

  @override
  String get id => 'rsa-oaep-sha256';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.asymmetric;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    final pem = params.rsaPem;
    if (pem == null || pem.trim().isEmpty) {
      throw const CryptoException('请粘贴 RSA 公钥（PEM）');
    }
    final key = parseRsaPem(pem);
    if (key is! RsaParsedPublicKey) {
      throw const CryptoException('加密需要公钥，粘贴的是私钥');
    }
    final modulusBytes = (key.key.modulus!.bitLength + 7) ~/ 8;
    final maxBlock = modulusBytes - 2 * 32 - 2; // OAEP-SHA256 开销
    if (maxBlock <= 0) {
      throw const CryptoException('RSA 密钥长度过短');
    }
    try {
      final input = Uint8List.fromList(utf8.encode(plaintext));
      final out = <int>[];
      var start = 0;
      while (true) {
        final end =
            start + maxBlock > input.length ? input.length : start + maxBlock;
        final block = Uint8List.fromList(input.sublist(start, end));
        final cipher = OAEPEncoding.withSHA256(RSAEngine())
          ..init(true, PublicKeyParameter<RSAPublicKey>(key.key));
        out.addAll(cipher.process(block));
        if (end >= input.length) break;
        start = end;
      }
      return base64.encode(Uint8List.fromList(out));
    } on CryptoException {
      rethrow;
    } catch (e) {
      throw CryptoException('RSA 加密失败: $e');
    }
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final pem = params.rsaPem;
    if (pem == null || pem.trim().isEmpty) {
      throw const CryptoException('请粘贴 RSA 私钥（PEM）');
    }
    final key = parseRsaPem(pem);
    if (key is! RsaParsedPrivateKey) {
      throw const CryptoException('解密需要私钥，粘贴的是公钥');
    }
    final modulusBytes = (key.key.modulus!.bitLength + 7) ~/ 8;
    final Uint8List input;
    try {
      input = base64.decode(normalizeBase64Input(ciphertext));
    } catch (_) {
      throw const CryptoException('密文不是有效的 Base64');
    }
    if (input.isEmpty || input.length % modulusBytes != 0) {
      throw CryptoException(
          '密文长度异常（应为模长 $modulusBytes 字节的整数倍）');
    }
    final out = <int>[];
    try {
      for (var start = 0; start < input.length; start += modulusBytes) {
        final block =
            Uint8List.fromList(input.sublist(start, start + modulusBytes));
        final cipher = OAEPEncoding.withSHA256(RSAEngine())
          ..init(false, PrivateKeyParameter<RSAPrivateKey>(key.key));
        final pt = cipher.process(block);
        out.addAll(pt);
      }
    } on CryptoException {
      rethrow;
    } catch (_) {
      throw const CryptoException('RSA 解密失败：私钥不匹配或密文已损坏');
    }
    return utf8.decode(out, allowMalformed: true);
  }
}

const List<CryptoAlgorithm> rsaAlgorithms = [RsaOaepAlgorithm()];
