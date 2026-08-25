/// 加解密工具箱高层入口。
///
/// - [CryptoToolbox.encrypt] / [decrypt]：统一加解密（自动路由
///   ENC1 / OpenSSL Salted / 裸 payload / 纯文本转换）。
/// - [CryptoToolbox.suggestDecrypt]：给解密面板的初始建议
///   （划词嗅探 → 自动选算法）。
/// - UI 按分类取算法列表：[CryptoToolbox.algorithmsByCategory]。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'algorithms/classic_algorithms.dart';
import 'algorithms/encoding_algorithms.dart';
import 'algorithms/rsa_algorithm.dart';
import 'algorithms/symmetric_algorithms.dart';
import 'crypto_algorithm.dart';
import 'crypto_cipher_format.dart';

/// 加密输出格式
enum CryptoOutputFormat {
  /// ENC1 自描述（默认）：`ENC1:<algo>:<b64(salt|iv|ct)>`
  enc1,

  /// OpenSSL Salted 兼容：`U2FsdGVkX1...`（openssl enc / CyberChef 可解）
  openssl,
}

/// 全部算法注册表（不可变）
class CryptoToolbox {
  CryptoToolbox._();

  /// 默认算法（加密面板初始选择）
  static const String defaultAlgorithmId = 'aes-256-cbc';

  static final Map<String, CryptoAlgorithm> _registry = {
    for (final a in [
      ...encodingAlgorithms,
      ...symmetricAlgorithms,
      ...hashAlgorithms,
      ...rsaAlgorithms,
      ...classicAlgorithms,
    ])
      a.id: a,
  };

  /// 全部算法（注册顺序：编码 → 对称 → 哈希 → RSA → 经典）
  static List<CryptoAlgorithm> get all =>
      List.unmodifiable(_registry.values);

  static CryptoAlgorithm? byId(String id) => _registry[id];

  /// 按分类取算法（UI 分组下拉）
  static List<CryptoAlgorithm> algorithmsByCategory(
      CryptoAlgorithmCategory category) {
    final algorithms = _registry.values
        .where((a) => a.category == category)
        .toList(growable: false);
    if (category == CryptoAlgorithmCategory.symmetric) {
      // CBC 系列排前（常用），其余按注册顺序
      algorithms.sort((a, b) {
        int rank(CryptoAlgorithm x) =>
            x.id.endsWith('-cbc') ? 0 : (x.id.contains('gcm') ? 1 : 2);
        return rank(a) == rank(b)
            ? _registryOrder(a.id).compareTo(_registryOrder(b.id))
            : rank(a).compareTo(rank(b));
      });
    }
    return algorithms;
  }

  static int _registryOrder(String id) =>
      all.indexWhere((a) => a.id == id);

  // ---- 加密 ----

  /// 加密。
  ///
  /// - 编码/哈希/经典算法：直接返回转换文本（[format] 忽略）。
  /// - 对称/RSA：按 [format] 打包（enc1 / openssl；
  ///   openssl 仅 [SymmetricAlgorithm.openSslCompatible] 算法支持）。
  static String encrypt({
    required String plaintext,
    required String algorithmId,
    required CryptoParams params,
    CryptoOutputFormat format = CryptoOutputFormat.enc1,
  }) {
    final algo = _registry[algorithmId];
    if (algo == null) {
      throw CryptoException('未知算法: $algorithmId');
    }
    switch (algo.category) {
      case CryptoAlgorithmCategory.encoding:
      case CryptoAlgorithmCategory.hash:
      case CryptoAlgorithmCategory.classic:
        return algo.encrypt(plaintext, params);
      case CryptoAlgorithmCategory.asymmetric:
        return enc1Pack(algo.id, algo.encrypt(plaintext, params));
      case CryptoAlgorithmCategory.symmetric:
        final sym = algo as SymmetricAlgorithm;
        if (format == CryptoOutputFormat.openssl) {
          if (!sym.openSslCompatible) {
            throw CryptoException(
                '${sym.displayName} 不支持 OpenSSL 兼容输出（仅 CBC 系列与 RC4）');
          }
          return _openSslEncrypt(sym, plaintext, params);
        }
        return enc1Pack(sym.id, sym.encrypt(plaintext, params));
    }
  }

  static String _openSslEncrypt(
      SymmetricAlgorithm sym, String plaintext, CryptoParams params) {
    final pw = params.password;
    if (pw == null || pw.isEmpty) {
      throw const CryptoException('请输入加密密码');
    }
    final salt = cryptoRandomBytes(8);
    // OpenSSL 3.x enc 默认（SHA-256 EVP_BytesToKey）；解密端双摘要兼容
    final derived = evpBytesToKey(pw, salt, sym.keyLength, sym.ivLength);
    final ct = sym.processBytes(
      Uint8List.fromList(utf8.encode(plaintext)),
      Uint8List.fromList(derived.key),
      Uint8List.fromList(derived.iv),
      true,
    );
    return openSslPack(salt, ct);
  }

  // ---- 解密 ----

  /// 解密。自动识别输入格式：
  /// 1. `ENC1:<algo>:<b64>` → 内嵌算法（[algorithmId] 仅作回退）
  /// 2. `U2FsdGVkX1...`（OpenSSL Salted）→ 按 [algorithmId] 解
  /// 3. 裸 `base64(salt|iv|ct)` / 编码文本 / 经典密码 → 按 [algorithmId] 解
  static String decrypt({
    required String ciphertext,
    required String algorithmId,
    required CryptoParams params,
  }) {
    final algo = _registry[algorithmId];
    if (algo == null) {
      throw CryptoException('未知算法: $algorithmId');
    }
    switch (algo.category) {
      case CryptoAlgorithmCategory.encoding:
      case CryptoAlgorithmCategory.hash:
      case CryptoAlgorithmCategory.classic:
        return algo.decrypt(ciphertext, params);
      case CryptoAlgorithmCategory.asymmetric:
        final enc1 = enc1TryParse(ciphertext);
        return algo.decrypt(enc1?.payloadBase64 ?? ciphertext, params);
      case CryptoAlgorithmCategory.symmetric:
        return _symmetricDecrypt(algo as SymmetricAlgorithm, ciphertext, params);
    }
  }

  static String _symmetricDecrypt(SymmetricAlgorithm sym,
      String ciphertext, CryptoParams params) {
    // 1. ENC1 自描述
    final enc1 = enc1TryParse(ciphertext);
    if (enc1 != null) {
      // 内嵌算法存在且可用 → 直接用它；否则按用户所选算法解 payload
      final inner = _registry[enc1.algorithmId];
      if (inner is SymmetricAlgorithm) {
        if (inner.id != sym.id) {
          // 用户手动改过算法：尊重用户选择，仅剥前缀解 payload
          return sym.decrypt(enc1.payloadBase64, params);
        }
        return inner.decrypt(enc1.payloadBase64, params);
      }
      return sym.decrypt(enc1.payloadBase64, params);
    }

    // 2. OpenSSL Salted：无法从密文分辨 KDF 摘要，先试 OpenSSL 3.x
    //    默认的 SHA-256，失败再试经典 MD5（OpenSSL 1.x / CyberChef）。
    final ossl = openSslTryParse(ciphertext);
    if (ossl != null) {
      if (!sym.openSslCompatible) {
        throw CryptoException(
            'OpenSSL Salted 密文需要 CBC 系列或 RC4 算法（当前: ${sym.displayName}）');
      }
      final pw = params.password;
      if (pw == null || pw.isEmpty) {
        throw const CryptoException('请输入加密密码');
      }
      Object? lastError;
      for (final useSha256 in [true, false]) {
        try {
          final derived = evpBytesToKey(
              pw, ossl.salt, sym.keyLength, sym.ivLength,
              useSha256: useSha256);
          final pt = sym.processBytes(
            Uint8List.fromList(ossl.ciphertext),
            Uint8List.fromList(derived.key),
            Uint8List.fromList(derived.iv),
            false,
          );
          return utf8.decode(pt, allowMalformed: true);
        } catch (e) {
          lastError = e;
        }
      }
      throw translateCipherError(lastError ?? 'unknown');
    }

    return sym.decrypt(ciphertext, params);
  }

  // ---- 解密建议（划词面板初始状态）----

  /// 根据密文特征给出解密面板建议算法与格式提示。
  static DecryptSuggestion suggestDecrypt(String ciphertext) {
    final sniffed = sniffCipher(ciphertext);
    if (sniffed == null) {
      return const DecryptSuggestion(null, null);
    }
    switch (sniffed.kind) {
      case SniffedCipherKind.enc1:
        // 内嵌算法未知时回退默认
        final known =
            sniffed.algorithmId != null && _registry.containsKey(sniffed.algorithmId);
        return DecryptSuggestion(
          known ? sniffed.algorithmId : defaultAlgorithmId,
          sniffed.kind,
        );
      case SniffedCipherKind.opensslSalted:
        // Salted 不内嵌算法，AES-256-CBC 是 openssl 最常用默认
        return const DecryptSuggestion(
          'aes-256-cbc',
          SniffedCipherKind.opensslSalted,
        );
      case SniffedCipherKind.plainBase64:
        // 内容探测：解码后是 UTF-8 可读文本 → 真是 base64 编码；
        // 二进制 → 更像加密密文裸 payload（对称算法自解析 salt|iv|ct）
        final bytes = _tryDecodeBase64(ciphertext);
        if (bytes != null && !_looksLikeUtf8Text(bytes)) {
          return const DecryptSuggestion(
              defaultAlgorithmId, SniffedCipherKind.plainBase64);
        }
        return const DecryptSuggestion('base64', SniffedCipherKind.plainBase64);
      case SniffedCipherKind.plainHex:
        final bytes = _tryDecodeHex(ciphertext);
        if (bytes != null && !_looksLikeUtf8Text(bytes)) {
          return const DecryptSuggestion(
              defaultAlgorithmId, SniffedCipherKind.plainHex);
        }
        return const DecryptSuggestion('hex', SniffedCipherKind.plainHex);
      case SniffedCipherKind.plainBase32:
        return const DecryptSuggestion('base32', SniffedCipherKind.plainBase32);
      case SniffedCipherKind.urlEncoded:
        return const DecryptSuggestion('url', SniffedCipherKind.urlEncoded);
      case SniffedCipherKind.morse:
        return const DecryptSuggestion('morse', SniffedCipherKind.morse);
    }
  }

  static Uint8List? _tryDecodeBase64(String text) {
    try {
      final bytes =
          base64.decode(normalizeBase64Input(text.replaceAll(RegExp(r'\s'), '')));
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _tryDecodeHex(String text) {
    final clean = text.replaceAll(RegExp(r'[\s:,-]'), '');
    if (clean.isEmpty || clean.length.isOdd) return null;
    try {
      final out = Uint8List(clean.length ~/ 2);
      for (var i = 0; i < out.length; i++) {
        out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 解码内容是否像 UTF-8 可读文本（无明显控制字符/替换符）
  static bool _looksLikeUtf8Text(Uint8List bytes) {
    final String decoded;
    try {
      decoded = utf8.decode(bytes); // 严格模式：坏序列直接失败
    } catch (_) {
      return false;
    }
    var control = 0;
    for (final unit in decoded.codeUnits) {
      // C0 控制字符（排除 \t\n\r）与 U+FFFD 替换符计入「不像文本」
      if ((unit < 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0d) ||
          unit == 0xfffd) {
        control++;
      }
    }
    return control == 0;
  }
}

/// 解密面板建议
class DecryptSuggestion {
  const DecryptSuggestion(this.algorithmId, this.kind);

  /// 建议算法 id（null = 无法识别，用户自选）
  final String? algorithmId;

  /// 嗅探到的密文类型（null = 不像密文）
  final SniffedCipherKind? kind;
}
