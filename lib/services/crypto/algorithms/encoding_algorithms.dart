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
      return decodeUtf8Compat(base64.decode(normalized));
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

/// 编码文本类 payload 的 UTF-8 兼容解码（Base64 / Hex / Base32 共用）。
///
/// 依次容忍三种上游怪癖：
/// 1. CESU-8/WTF-8：emoji 等 BMP 外字符被拆成 UTF-16 代理对、各按 3 字节编码
///    （Java JNI、`writeUTF`、MySQL utf8mb3 等会这么干）；
/// 2. 个别字节损坏（如划词把 base64 尾巴选漏）：只把坏字节替成 U+FFFD，
///    保住其余正文，不再整段改换编码；
/// 3. 整段本就不是 UTF-8（Latin-1 等）：回退 Latin-1（CyberChef 行为）。
///
/// 2 与 3 的取舍不看长度、不拍阈值：两个候选各数一次「可疑字符」后取优。
/// 真 UTF-8 被 Latin-1 硬解会漏出成片 C1 控制字符，真 Latin-1 文本几乎没有，
/// 两者天然可分——否则「几个重音字母」和「几个截断字节」只能靠长度瞎猜。
String decodeUtf8Compat(List<int> bytes) {
  final normalized = _normalizeCesu8SurrogatePairs(bytes);
  try {
    return utf8.decode(normalized);
  } on FormatException {
    final repaired = utf8.decode(normalized, allowMalformed: true);
    final fallback = latin1.decode(bytes, allowInvalid: true);
    return _countSuspiciousRunes(repaired) <= _countSuspiciousRunes(fallback)
        ? repaired
        : fallback;
  }
}

/// 嗅探端判据：payload 按 UTF-8 解出来是否像人类可读文本。
///
/// 用于「这段 base64/hex 是真文本编码，还是加密后的裸 payload」二选一。
/// 刻意只看 UTF-8 解释：Latin-1 是解码端的补救手段，不能拿来给二进制洗白
/// 身份——随机字节硬解 Latin-1 也能凑出「没有控制字符」的假象（实测 16 字节
/// 随机 payload 有约 1.8% 会蒙混过关）。
bool looksLikeReadableText(List<int> bytes) {
  if (bytes.isEmpty) return false;
  final decoded =
      utf8.decode(_normalizeCesu8SurrogatePairs(bytes), allowMalformed: true);
  if (decoded.isEmpty) return false;
  var runeCount = 0;
  var replacements = 0;
  var firstReplacementAt = -1;
  for (final rune in decoded.runes) {
    // 控制字符是二进制内容最强的信号，出现即判非文本
    if (_isC0Control(rune) || _isC1Control(rune)) return false;
    if (rune == 0xfffd) {
      if (firstReplacementAt < 0) firstReplacementAt = runeCount;
      replacements++;
    }
    runeCount++;
  }
  if (replacements == 0) return true;
  // CESU-8 已在归一化阶段还原，这里只需再容忍「划词把 base64 尾巴选漏」。
  // 截断只会毁掉末尾那一个多字节序列，所以要求替换符紧贴结尾——散落在正文
  // 中间的损坏按二进制处理。不按占比放宽：占比会随文本变长越放越松，长文本
  // 能静默吞掉几十个坏字节，且随机字节能靠「凑出几个合法多字节序列」蒙过去。
  return replacements <= _maxTruncatedTailReplacements &&
      firstReplacementAt >= runeCount - _maxTruncatedTailReplacements;
}

/// 尾部截断最多毁掉一个多字节序列，留一点余量
const int _maxTruncatedTailReplacements = 2;

/// 可疑字符：U+FFFD 替换符、C0 控制字符、C1 控制区。
///
/// C1（U+0080-009F）是关键项：正常文本几乎不用，但 UTF-8 多字节序列被
/// Latin-1 硬解时后续字节会成片落进这里，正是「谁解错了」的指纹。
bool _isSuspiciousRune(int rune) =>
    rune == 0xfffd || _isC0Control(rune) || _isC1Control(rune);

bool _isC0Control(int rune) =>
    rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d;

bool _isC1Control(int rune) => rune >= 0x80 && rune <= 0x9f;

int _countSuspiciousRunes(String text) {
  var count = 0;
  for (final rune in text.runes) {
    if (_isSuspiciousRune(rune)) count++;
  }
  return count;
}

/// CESU-8 代理序列的首字节
const int _cesu8Lead = 0xed;

/// 把成对的 CESU-8 代理序列（6 字节）还原成标准 UTF-8（4 字节）。
///
/// 合法 UTF-8 里 `0xED` 后接 `0xA0-0xBF` 恰好落在 U+D800-DFFF 代理区，
/// 而该区在 UTF-8 中永远非法，所以这个还原不可能误伤正常内容。
Uint8List _normalizeCesu8SurrogatePairs(List<int> bytes) {
  final firstLead = bytes.indexOf(_cesu8Lead);
  // 绝大多数 payload 不含 CESU-8：零拷贝原样返回
  if (firstLead < 0) {
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }
  final out = BytesBuilder()..add(bytes.sublist(0, firstLead));
  var i = firstLead;
  while (i < bytes.length) {
    if (i + 5 < bytes.length && _isCesu8SurrogatePair(bytes, i)) {
      out.add(utf8.encode(String.fromCharCode(_decodeCesu8Pair(bytes, i))));
      i += 6;
      continue;
    }
    out.addByte(bytes[i]);
    i++;
  }
  return out.takeBytes();
}

/// `ED A0-AF xx` + `ED B0-BF xx`：高代理 + 低代理各一段 3 字节
bool _isCesu8SurrogatePair(List<int> b, int i) =>
    b[i] == _cesu8Lead &&
    b[i + 1] >= 0xa0 &&
    b[i + 1] <= 0xaf &&
    _isUtf8Continuation(b[i + 2]) &&
    b[i + 3] == _cesu8Lead &&
    b[i + 4] >= 0xb0 &&
    b[i + 4] <= 0xbf &&
    _isUtf8Continuation(b[i + 5]);

/// 两段 3 字节代理还原成单个码点（首字节固定 0xED 即高 4 位 0xD）
int _decodeCesu8Pair(List<int> b, int i) {
  final high = 0xd000 | ((b[i + 1] & 0x3f) << 6) | (b[i + 2] & 0x3f);
  final low = 0xd000 | ((b[i + 4] & 0x3f) << 6) | (b[i + 5] & 0x3f);
  return 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);
}

bool _isUtf8Continuation(int byte) => byte >= 0x80 && byte <= 0xbf;

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
      return decodeUtf8Compat(_hexDecode(text));
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
      return decodeUtf8Compat(out);
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
