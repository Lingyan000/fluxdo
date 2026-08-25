/// 编码类算法：Base64 / Base64(URL-safe) / Hex / URL / ROT13。
///
/// 免密钥、可逆、不走 ENC1/OpenSSL 打包（输出即编码文本）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import '../crypto_algorithm.dart';

/// Base64（标准字母表 + padding）
class Base64Algorithm extends CryptoAlgorithm {
  const Base64Algorithm();

  @override
  String get id => 'base64';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.encoding;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    try {
      return base64.encode(utf8.encode(plaintext));
    } catch (e) {
      throw CryptoException('Base64 编码失败: $e');
    }
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final normalized = _normalize(ciphertext);
    try {
      return utf8.decode(base64.decode(normalized));
    } on FormatException {
      // 非 UTF-8 字节也允许以 Latin-1 兜底展示（CyberChef 行为）
      try {
        return latin1.decode(base64.decode(normalized));
      } catch (_) {
        throw const CryptoException('无效的 Base64 密文');
      }
    } catch (_) {
      throw const CryptoException('无效的 Base64 密文');
    }
  }

  /// 容忍换行/空格（MIME 折行），并兼容 URL-safe 字母表输入
  static String _normalize(String input) {
    var text = input.replaceAll(RegExp(r'\s'), '');
    if (text.contains('-') || text.contains('_')) {
      text = text.replaceAll('-', '+').replaceAll('_', '/');
    }
    // 补齐 padding
    final rem = text.length % 4;
    if (rem == 2) {
      text += '==';
    } else if (rem == 3) {
      text += '=';
    }
    return text;
  }
}

/// Hex（小写输出，解码大小写均可）
class HexAlgorithm extends CryptoAlgorithm {
  const HexAlgorithm();

  @override
  String get id => 'hex';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.encoding;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    return utf8
        .encode(plaintext)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final text = ciphertext.replaceAll(RegExp(r'[\s:,]'), '');
    if (text.isEmpty) return '';
    if (text.length.isOdd ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) {
      throw const CryptoException('无效的 Hex 密文（需为偶数长度的十六进制字符）');
    }
    try {
      return utf8.decode(_hexDecode(text));
    } catch (_) {
      throw const CryptoException('Hex 解码失败：内容不是有效的 UTF-8 文本');
    }
  }

  static Uint8List _hexDecode(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// URL 百分号编码（UTF-8）
class UrlEncodeAlgorithm extends CryptoAlgorithm {
  const UrlEncodeAlgorithm();

  @override
  String get id => 'url';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.encoding;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    return Uri.encodeComponent(plaintext);
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    try {
      return Uri.decodeComponent(ciphertext);
    } on FormatException catch (e) {
      throw CryptoException('URL 解码失败: ${e.message}');
    }
  }
}

/// Base32（RFC 4648 大写字母表 + `=` padding；解码容忍小写/空白/缺 padding）
class Base32Algorithm extends CryptoAlgorithm {
  const Base32Algorithm();

  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  @override
  String get id => 'base32';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.encoding;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    final bytes = utf8.encode(plaintext);
    final sb = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_alphabet[(buffer >> bits) & 0x1f]);
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) {
      sb.write(_alphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    while (sb.length % 8 != 0) {
      sb.write('=');
    }
    return sb.toString();
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final clean = ciphertext
        .toUpperCase()
        .replaceAll(RegExp(r'[\s=]'), '');
    if (clean.isEmpty) return '';
    var buffer = 0;
    var bits = 0;
    final out = <int>[];
    for (final unit in clean.codeUnits) {
      final v = _alphabet.indexOf(String.fromCharCode(unit));
      if (v < 0) {
        throw CryptoException(
            '无效的 Base32 字符: ${String.fromCharCode(unit)}');
      }
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
      buffer &= (1 << bits) - 1;
    }
    try {
      return utf8.decode(out);
    } catch (_) {
      throw const CryptoException('Base32 解码失败：内容不是有效的 UTF-8 文本');
    }
  }
}

/// ROT13（字母旋转 13 位，自逆）
class Rot13Algorithm extends CryptoAlgorithm {
  const Rot13Algorithm();

  @override
  String get id => 'rot13';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.encoding;

  @override
  String encrypt(String plaintext, CryptoParams params) =>
      _rot13(plaintext);

  @override
  String decrypt(String ciphertext, CryptoParams params) =>
      _rot13(ciphertext);

  static String _rot13(String input) {
    final codeUnits = List<int>.from(input.codeUnits);
    for (var i = 0; i < codeUnits.length; i++) {
      final c = codeUnits[i];
      if (c >= 65 && c <= 90) {
        codeUnits[i] = 65 + (c - 65 + 13) % 26;
      } else if (c >= 97 && c <= 122) {
        codeUnits[i] = 97 + (c - 97 + 13) % 26;
      }
    }
    return String.fromCharCodes(codeUnits);
  }
}

/// 哈希类算法（单向，不可逆）：MD5 / SHA-1 / SHA-256 / SHA-512 / SM3。
/// 哈希输出为小写 hex。
class HashAlgorithm extends CryptoAlgorithm {
  const HashAlgorithm(this._id, this._digest);

  final String _id;

  /// 摘要函数（crypto 包 md5/sha1/sha256/sha512 或 pointycastle SM3）
  final List<int> Function(List<int> data) _digest;

  @override
  String get id => _id;

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.hash;

  @override
  String encrypt(String plaintext, CryptoParams params) =>
      _digest(utf8.encode(plaintext))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    throw const CryptoException('哈希是单向摘要，无法解密');
  }
}

/// SM3 中国商用哈希（GM/T 0004），pointycastle 实现
class Sm3HashAlgorithm extends CryptoAlgorithm {
  const Sm3HashAlgorithm();

  @override
  String get id => 'sm3';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.hash;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    final digest = SM3Digest();
    final input = Uint8List.fromList(utf8.encode(plaintext));
    digest.update(input, 0, input.length);
    final out = Uint8List(digest.digestSize);
    digest.doFinal(out, 0);
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    throw const CryptoException('哈希是单向摘要，无法解密');
  }
}

const List<CryptoAlgorithm> encodingAlgorithms = [
  Base64Algorithm(),
  Base32Algorithm(),
  HexAlgorithm(),
  UrlEncodeAlgorithm(),
  Rot13Algorithm(),
];

List<int> _md5(List<int> data) => crypto.md5.convert(data).bytes;
List<int> _sha1(List<int> data) => crypto.sha1.convert(data).bytes;
List<int> _sha256(List<int> data) => crypto.sha256.convert(data).bytes;
List<int> _sha512(List<int> data) => crypto.sha512.convert(data).bytes;

final List<CryptoAlgorithm> hashAlgorithms = [
  HashAlgorithm('md5', _md5),
  HashAlgorithm('sha1', _sha1),
  HashAlgorithm('sha256', _sha256),
  HashAlgorithm('sha512', _sha512),
  Sm3HashAlgorithm(),
];
