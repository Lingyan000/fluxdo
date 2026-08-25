/// 加解密工具箱 —— 算法抽象层。
///
/// 分层：
/// - 本文件：算法分类、调用参数、统一抽象 [CryptoAlgorithm]。
/// - `algorithms/`：各分类算法实现（编码/哈希/经典/对称/RSA）。
/// - `crypto_cipher_format.dart`：ENC1 自描述格式 + OpenSSL Salted 兼容格式。
/// - `crypto_toolbox.dart`：高层入口（注册表 + encrypt/decrypt + 密文识别）。
library;

/// 算法分类（UI 按此分组展示）
enum CryptoAlgorithmCategory {
  /// 编码转换（免密钥、可逆）：Base64 / Hex / URL / ROT13
  encoding,

  /// 对称加密（密码派生密钥）：AES / DES / 3DES / RC4 / ChaCha20 / SM4
  symmetric,

  /// 单向哈希：MD5 / SHA 系列 / SM3（不可逆）
  hash,

  /// 非对称：RSA-OAEP（PEM 公钥加密 / 私钥解密）
  asymmetric,

  /// 经典密码：凯撒 / 维吉尼亚 / 栅栏 / 摩斯电码
  classic,
}

/// 加解密操作失败（密码错误、密文损坏、密钥格式不对等）。
///
/// [message] 为面向用户的技术性描述（中文），UI 可直接展示或包一层 l10n。
class CryptoException implements Exception {
  const CryptoException(this.message);

  final String message;

  @override
  String toString() => 'CryptoException: $message';
}

/// 算法调用参数。
///
/// 不同算法取用不同字段：对称算法用 [password]，RSA 用 [rsaPem]，
/// 经典密码用 [caesarShift] / [vigenereKey] / [railCount]。
class CryptoParams {
  const CryptoParams({
    this.password,
    this.rsaPem,
    this.caesarShift = 3,
    this.vigenereKey,
    this.railCount = 2,
  });

  /// 对称加密密码（口令）
  final String? password;

  /// RSA PEM 密钥文本（加密=公钥，解密=私钥；PKCS#1/PKCS#8/SPKI 均可）
  final String? rsaPem;

  /// 凯撒密码移位数（正值右移）
  final int caesarShift;

  /// 维吉尼亚密码密钥（字母）
  final String? vigenereKey;

  /// 栅栏密码栏数
  final int railCount;
}

/// 单个加解密算法的统一描述。
///
/// 文本进出；[encrypt] 返回密文（对称/RSA 为裸 base64 密文，
/// 最终 ENC1/OpenSSL 打包由 CryptoToolbox 完成）。
abstract class CryptoAlgorithm {
  const CryptoAlgorithm();

  /// 稳定 id（持久化/ENC1 内嵌标识，如 `aes-256-cbc`）
  String get id;

  CryptoAlgorithmCategory get category;

  /// 显示名（技术名词不翻译，默认大写 id）
  String get displayName => id.toUpperCase();

  /// 是否可逆（哈希不可逆）
  bool get isReversible => category != CryptoAlgorithmCategory.hash;

  /// 是否需要密码（对称算法）
  bool get requiresPassword => category == CryptoAlgorithmCategory.symmetric;

  /// 是否需要 PEM 密钥（RSA）
  bool get requiresPem => category == CryptoAlgorithmCategory.asymmetric;

  /// 加密（编码类=编码；哈希类=摘要 hex 小写；对称/RSA=裸 base64 密文）
  ///
  /// 抛 [CryptoException]；不可逆算法调用 [decrypt] 抛错。
  String encrypt(String plaintext, CryptoParams params);

  String decrypt(String ciphertext, CryptoParams params);
}
