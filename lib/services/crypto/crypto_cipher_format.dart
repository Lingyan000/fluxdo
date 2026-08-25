/// 密文格式层：ENC1 自描述格式、OpenSSL Salted 兼容格式、划词嗅探。
///
/// - **ENC1**（fluxdo 默认输出）：`ENC1:<algo-id>:<base64(payload)>`，
///   payload = `salt[16] | iv | ct`（对称）或 `ct`（RSA）。算法内嵌，
///   解密时自动识别。
/// - **OpenSSL**（可选输出）：`base64("Salted__" | salt[8] | ct)`，
///   KDF = EVP_BytesToKey(MD5, 1 轮)，与 `openssl enc` / CyberChef 互通。
///   算法不内嵌（解密方自选，默认 AES-256-CBC）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'algorithms/classic_algorithms.dart' show normalizeMorseGlyphs;
import 'algorithms/symmetric_algorithms.dart';
/// ENC1 前缀
const String kEnc1Prefix = 'ENC1:';

/// OpenSSL Salted 密文的 Base64 前缀（= base64("Salted__") 去掉 padding）
const String kOpenSslMagic = 'U2FsdGVkX1';

/// ENC1 打包：`ENC1:<algoId>:<payloadBase64>`
String enc1Pack(String algorithmId, String payloadBase64) =>
    '$kEnc1Prefix$algorithmId:$payloadBase64';

/// ENC1 解析结果
class Enc1Parsed {
  const Enc1Parsed(this.algorithmId, this.payloadBase64);

  final String algorithmId;
  final String payloadBase64;
}

/// 尝试解析 ENC1 格式（容忍首尾空白与折行）。
Enc1Parsed? enc1TryParse(String text) {
  var t = text.trim();
  if (!t.startsWith(kEnc1Prefix)) return null;
  t = t.substring(kEnc1Prefix.length).replaceAll(RegExp(r'\s'), '');
  final colon = t.indexOf(':');
  if (colon <= 0) return null;
  final algo = t.substring(0, colon);
  final payload = t.substring(colon + 1);
  if (algo.isEmpty || payload.isEmpty) return null;
  return Enc1Parsed(algo, payload);
}

/// OpenSSL Salted 密文解析结果
class OpenSslParsed {
  const OpenSslParsed(this.salt, this.ciphertext);

  final List<int> salt; // 8 字节
  final List<int> ciphertext;
}

/// 尝试解析 OpenSSL Salted 格式。
OpenSslParsed? openSslTryParse(String text) {
  var t = text.trim().replaceAll(RegExp(r'\s'), '');
  if (!t.startsWith(kOpenSslMagic)) return null;
  try {
    final bytes = base64.decode(normalizeBase64Input(t));
    // 需容纳 Salted__(8) + salt(8) + 至少 1 字节密文
    if (bytes.length < 8 + 8 + 1) return null;
    if (String.fromCharCodes(bytes.sublist(0, 8)) != 'Salted__') return null;
    return OpenSslParsed(
      bytes.sublist(8, 16),
      bytes.sublist(16),
    );
  } catch (_) {
    return null;
  }
}

/// OpenSSL 兼容输出：`base64("Salted__" | salt[8] | ct)`
String openSslPack(List<int> salt, List<int> ciphertext) {
  final bytes = <int>[
    ...'Salted__'.codeUnits,
    ...salt,
    ...ciphertext,
  ];
  return base64.encode(bytes);
}

/// OpenSSL EVP_BytesToKey 派生 key 与 iv。
///
/// - [useSha256]：true = SHA-256 摘要（**OpenSSL 3.x enc 默认**）；
///   false = MD5 摘要（OpenSSL 1.x / CyberChef 经典行为）。
///   解密方无从密文分辨，因此解密路径两种都要尝试。
DerivedKeyIv evpBytesToKey(
    String password, List<int> salt, int keyLength, int ivLength,
    {bool useSha256 = true}) {
  final pwd = utf8.encode(password);
  final material = <int>[];
  var prev = <int>[];
  while (material.length < keyLength + ivLength) {
    final input = [...prev, ...pwd, ...salt];
    prev = useSha256
        ? crypto.sha256.convert(input).bytes
        : crypto.md5.convert(input).bytes;
    material.addAll(prev);
  }
  return DerivedKeyIv(
    material.sublist(0, keyLength),
    ivLength == 0
        ? const <int>[]
        : material.sublist(keyLength, keyLength + ivLength),
  );
}

/// EVP_BytesToKey 派生结果（key 与 iv）
class DerivedKeyIv {
  const DerivedKeyIv(this.key, this.iv);
  final List<int> key;
  final List<int> iv;
}

// ---- 划词嗅探：判断选中文本是否像密文（决定「解密」按钮显隐）----

/// 嗅探出的密文类型
enum SniffedCipherKind {
  /// ENC1 自描述（带算法 id）
  enc1,

  /// OpenSSL Salted（算法未知）
  opensslSalted,

  /// 纯 Base64（算法未知）
  plainBase64,

  /// 纯 Hex（算法未知）
  plainHex,

  /// URL 百分号编码（%XX 模式）
  urlEncoded,

  /// Base32（A-Z2-7 字母表）
  plainBase32,

  /// 摩斯电码
  morse,
}

/// 嗅探结果
class SniffedCipher {
  const SniffedCipher(this.kind, {this.algorithmId});

  final SniffedCipherKind kind;

  /// ENC1 内嵌算法 id（其余为 null）
  final String? algorithmId;
}

/// 判断文本是否像可解密的密文。
///
/// 规则（全部要求去除首尾空白后无内部空白，避免普通句子误报）：
/// - `ENC1:` 前缀且结构合法
/// - `U2FsdGVkX1` 前缀且 Base64 解码后以 `Salted__` 开头
/// - 纯 Base64：长度 ≥ 16 且解码成功（容忍折行）
/// - 纯 Hex：长度 ≥ 16、偶数位、全十六进制字符
/// - 摩斯：仅由 `.` `-` `/` 空格组成且同时含 `.` 与 `-`
SniffedCipher? sniffCipher(String rawText) {
  final text = rawText.trim();
  if (text.isEmpty) return null;

  final enc1 = enc1TryParse(text);
  if (enc1 != null) {
    // payload 必须是合法 base64 才认
    try {
      base64.decode(normalizeBase64Input(enc1.payloadBase64));
      return SniffedCipher(SniffedCipherKind.enc1, algorithmId: enc1.algorithmId);
    } catch (_) {
      return null;
    }
  }

  final ossl = openSslTryParse(text);
  if (ossl != null) return const SniffedCipher(SniffedCipherKind.opensslSalted);

  // 纯 Base64 / Hex 判定要求**无内部空白**：ENC1/OpenSSL 有强前缀特征
  // 可容忍折行，而普通英文多词句子（去空格后恰好全是 base64 字母表
  // 字符）绝不能误报。
  final hasWhitespace = RegExp(r'\s').hasMatch(text);
  if (hasWhitespace) {
    // MIME 折行 Base64（PEM/邮件风格）：逐行校验，每行都是纯 base64
    // 字母表且 ≥16 字符、至少 2 行 —— 普通多行英文几乎不可能满足
    final lines =
        text.split(RegExp(r'\s+')).where((l) => l.isNotEmpty).toList();
    if (lines.length >= 2 &&
        lines.every((l) =>
            l.length >= 16 &&
            RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(l))) {
      return const SniffedCipher(SniffedCipherKind.plainBase64);
    }
    // 含空白的仍可能是摩斯电码（仅由 . - · / 空格组成）
    if (_looksLikeMorse(text)) {
      return const SniffedCipher(SniffedCipherKind.morse);
    }
    return null;
  }

  // URL 百分号编码：至少两段 %XX（单段 `%ab` 太容易是普通文本）
  if (RegExp(r'(%[0-9A-Fa-f]{2}){2,}').hasMatch(text)) {
    return const SniffedCipher(SniffedCipherKind.urlEncoded);
  }

  // 分隔 Hex（`48:65:6c` / `48-65-6c`，MAC 地址/证书指纹风格，≥8 字节）
  if (RegExp(r'^([0-9A-Fa-f]{2}[:-]){7,}[0-9A-Fa-f]{2}$').hasMatch(text)) {
    return const SniffedCipher(SniffedCipherKind.plainHex);
  }

  // 纯 Hex
  if (text.length >= 16 &&
      text.length.isEven &&
      RegExp(r'^[0-9A-Fa-f]+$').hasMatch(text)) {
    return const SniffedCipher(SniffedCipherKind.plainHex);
  }

  // Base32（先于纯 Base64 判定：base32 字符集 ⊂ base64，后判会被吞）。
  // 规则：A-Z2-7、长度 ≥16 且为 8 的倍数、含至少一个 2-7 数字——
  // 全大写+数字+padding 形态是 base32 的概率远高于恰好全大写的 base64；
  // 「纯大写英文单词」被数字要求挡住。
  if (text.length >= 16 &&
      text.length % 8 == 0 &&
      RegExp(r'^[A-Z2-7]+={0,6}$').hasMatch(text) &&
      RegExp(r'[2-7]').hasMatch(text)) {
    return const SniffedCipher(SniffedCipherKind.plainBase32);
  }

  // 纯 Base64（标准或 URL-safe 字母表）
  if (text.length >= 16 &&
      RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$').hasMatch(text)) {
    try {
      final bytes = base64.decode(normalizeBase64Input(text));
      if (bytes.isNotEmpty) {
        return const SniffedCipher(SniffedCipherKind.plainBase64);
      }
    } catch (_) {
      // 不是 base64，落到摩斯判断
    }
  }

  if (_looksLikeMorse(text)) {
    return const SniffedCipher(SniffedCipherKind.morse);
  }

  return null;
}

/// 判断是否为摩斯电码：先把 Unicode 横线/点变体规范化（`–—−`→`-`、
/// `·•●`→`.`），再要求仅由 `.` `-` `/` 空白组成且同时含点与划。
///
/// 规范化后仍含其他字符（如 `…` 省略号）→ 不识别：宁缺毋滥，
/// 不合法输入保持「无解密按钮」是预期行为。
bool _looksLikeMorse(String text) {
  final normalized = normalizeMorseGlyphs(text);
  return RegExp(r'^[.\-/\s]+$').hasMatch(normalized) &&
      normalized.contains('.') &&
      normalized.contains('-');
}

/// 划词「解密」按钮的统一判定（主项目注入 fluxdo_render 的 detector）。
///
/// - [codeLanguage] 为选中内容所在代码块的 fence 语言标记：编辑器加密
///   输出的 ```enc 块是最强信号，命中即显示（即使只选中了密文的一部分，
///   内容特征识别不出来也应有入口）。
/// - 其余走 [sniffCipher] 内容特征嗅探。
bool isDecryptableText(String plainText, {String? codeLanguage}) {
  if (codeLanguage == 'enc') return true;
  return sniffCipher(plainText) != null;
}
