/// 对称加密算法（pointycastle 组装）。
///
/// - 文本接口（[encrypt]/[decrypt]）为**裸 payload 模式**：
///   `base64(salt[16] | iv | ciphertext)`，密钥 = PBKDF2-HMAC-SHA256
///   (password, salt, 100000 轮)。ENC1 前缀打包 / OpenSSL Salted 兼容
///   由 `crypto_cipher_format.dart` 在此之上完成。
/// - [processBytes] 为裸字节加解密入口（key/iv 由调用方派生），
///   OpenSSL 兼容路径直接复用。
///
/// 涵盖：AES-128/192/256 × CBC/ECB/GCM/CTR、3DES-CBC、Blowfish-CBC、
/// RC4、ChaCha20(RFC 7539)。pointycastle 4.0 无单 DES/SM4 引擎，故未收录。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../crypto_algorithm.dart';

/// 对称算法描述符。
class SymmetricAlgorithm extends CryptoAlgorithm {
  const SymmetricAlgorithm({
    required String id,
    required this.keyLength,
    required this.ivLength,
    required this.processBytes,
    this.openSslCompatible = false,
  }) : _id = id;

  final String _id;

  /// 密钥长度（字节）
  final int keyLength;

  /// IV/nonce 长度（字节），0 = 无 IV（ECB / RC4）
  final int ivLength;

  /// 是否支持 OpenSSL Salted 兼容输出（openssl enc 同名算法可解）
  final bool openSslCompatible;

  /// 裸字节加解密。[iv] 长度 == [ivLength]（无 IV 算法传空）。
  /// 解密失败（密码错误/密文损坏）抛 [CryptoException]。
  final Uint8List Function(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
    bool forEncryption,
  ) processBytes;

  @override
  String get id => _id;

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.symmetric;

  // ---- PBKDF2 裸 payload 文本接口 ----

  static const int kSaltLength = 16;
  static const int kPbkdf2Iterations = 100000;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    final key = _requirePassword(params);
    final salt = cryptoRandomBytes(kSaltLength);
    final iv = ivLength > 0 ? cryptoRandomBytes(ivLength) : Uint8List(0);
    final derived = pbkdf2(key, salt, keyLength, kPbkdf2Iterations);
    final ct = processBytes(
      Uint8List.fromList(utf8.encode(plaintext)),
      derived,
      iv,
      true,
    );
    return base64
        .encode(Uint8List.fromList([...salt, ...iv, ...ct]));
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final key = _requirePassword(params);
    final Uint8List payload;
    try {
      payload = base64.decode(_normalizeBase64(ciphertext));
    } catch (e) {
      throw const CryptoException('密文不是有效的 Base64');
    }
    // 流密码空明文的 ct 可为 0 字节，下界只要求 salt+iv 齐全
    if (payload.length < kSaltLength + ivLength) {
      throw const CryptoException('密文长度不完整');
    }
    final salt = payload.sublist(0, kSaltLength);
    final iv =
        payload.sublist(kSaltLength, kSaltLength + ivLength);
    final ct = payload.sublist(kSaltLength + ivLength);
    final derived = pbkdf2(key, salt, keyLength, kPbkdf2Iterations);
    final plain = processBytes(ct, derived, iv, false);
    return utf8.decode(plain, allowMalformed: true);
  }

  String _requirePassword(CryptoParams params) {
    final pw = params.password;
    if (pw == null || pw.isEmpty) {
      throw const CryptoException('请输入加密密码');
    }
    return pw;
  }
}

// ---- PBKDF2 / 随机数 / base64 规整 ----

/// PBKDF2-HMAC-SHA256 密钥派生（[iterations] 轮，输出 [length] 字节）
Uint8List pbkdf2(String password, Uint8List salt, int length,
    [int iterations = SymmetricAlgorithm.kPbkdf2Iterations]) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, length));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

final Random _secureRng = Random.secure();

/// 加密安全随机字节
Uint8List cryptoRandomBytes(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _secureRng.nextInt(256)));

/// 容忍空白与 URL-safe 字母表，补齐 padding
String normalizeBase64Input(String input) {
  var text = input.replaceAll(RegExp(r'\s'), '');
  if (text.contains('-') || text.contains('_')) {
    text = text.replaceAll('-', '+').replaceAll('_', '/');
  }
  final rem = text.length % 4;
  if (rem == 2) {
    text += '==';
  } else if (rem == 3) {
    text += '=';
  }
  return text;
}

String _normalizeBase64(String input) => normalizeBase64Input(input);

/// 把 pointycastle 抛出的底层异常转成用户可读的 [CryptoException]。
CryptoException translateCipherError(Object error) {
  if (error is CryptoException) return error;
  return const CryptoException('解密失败：密码错误或密文已损坏');
}

// ---- pointycastle 组装工具 ----

/// Padded 块密码（CBC/ECB + PKCS7）
Uint8List _runPaddedBlockCipher(
  BlockCipher blockCipher,
  bool forEncryption,
  Uint8List data,
  Uint8List key,
  Uint8List? iv,
) {
  try {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), blockCipher);
    final params = iv == null || iv.isEmpty
        ? PaddedBlockCipherParameters(KeyParameter(key), null)
        : PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(key), iv), null);
    cipher.init(forEncryption, params);
    if (data.isEmpty && forEncryption) {
      // pointycastle 4.0 process() 对空输入有 RangeError（-16 块偏移），
      // 空明文直接走 doFinal 产出 padding-only 块
      final out = Uint8List(cipher.blockSize);
      final n = cipher.doFinal(data, 0, out, 0);
      return out.sublist(0, n);
    }
    return cipher.process(data);
  } catch (e) {
    throw translateCipherError(e);
  }
}

Uint8List _processAesCbc(Uint8List data, Uint8List key, Uint8List iv,
        bool forEncryption) =>
    _runPaddedBlockCipher(
        CBCBlockCipher(AESEngine()), forEncryption, data, key, iv);

Uint8List _processAesEcb(Uint8List data, Uint8List key, Uint8List iv,
        bool forEncryption) =>
    _runPaddedBlockCipher(
        ECBBlockCipher(AESEngine()), forEncryption, data, key, null);

Uint8List _processAesGcm(Uint8List data, Uint8List key, Uint8List iv,
    bool forEncryption) {
  try {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        forEncryption,
        AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
      );
    // 加密输出 ct||tag(16B)；解密输入同结构，tag 校验失败抛异常
    return cipher.process(data);
  } on CryptoException {
    rethrow;
  } catch (e) {
    throw translateCipherError(e);
  }
}

Uint8List _processAesCtr(Uint8List data, Uint8List key, Uint8List iv,
    bool forEncryption) {
  try {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(forEncryption, ParametersWithIV(KeyParameter(key), iv));
    return cipher.process(data);
  } on CryptoException {
    rethrow;
  } catch (e) {
    throw translateCipherError(e);
  }
}

/// Blowfish-CBC（key 16 字节、8 字节块与 IV；openssl enc -bf-cbc 兼容）
Uint8List _processBlowfishCbc(Uint8List data, Uint8List key, Uint8List iv,
        bool forEncryption) =>
    _runPaddedBlockCipher(
        CBCBlockCipher(BlowfishEngine()), forEncryption, data, key, iv);

Uint8List _processDesEde3Cbc(Uint8List data, Uint8List key, Uint8List iv,
        bool forEncryption) =>
    _runPaddedBlockCipher(
        CBCBlockCipher(DESedeEngine()), forEncryption, data, key, iv);

Uint8List _processRc4(Uint8List data, Uint8List key, Uint8List iv,
    bool forEncryption) {
  try {
    final cipher = RC4Engine()..init(forEncryption, KeyParameter(key));
    return cipher.process(data);
  } catch (e) {
    throw translateCipherError(e);
  }
}

/// ChaCha20（RFC 7539 / IETF，12 字节 nonce）
Uint8List _processChaCha20(Uint8List data, Uint8List key, Uint8List iv,
    bool forEncryption) {
  try {
    final cipher = ChaCha7539Engine()
      ..init(forEncryption, ParametersWithIV(KeyParameter(key), iv));
    return cipher.process(data);
  } catch (e) {
    throw translateCipherError(e);
  }
}
// ---- 算法注册表 ----

const List<SymmetricAlgorithm> symmetricAlgorithms = [
  // AES-CBC（OpenSSL 兼容）
  SymmetricAlgorithm(
    id: 'aes-128-cbc',
    keyLength: 16,
    ivLength: 16,
    openSslCompatible: true,
    processBytes: _processAesCbc,
  ),
  SymmetricAlgorithm(
    id: 'aes-192-cbc',
    keyLength: 24,
    ivLength: 16,
    openSslCompatible: true,
    processBytes: _processAesCbc,
  ),
  SymmetricAlgorithm(
    id: 'aes-256-cbc',
    keyLength: 32,
    ivLength: 16,
    openSslCompatible: true,
    processBytes: _processAesCbc,
  ),
  // AES-ECB（无 IV，弱模式，仅兼容用途）
  SymmetricAlgorithm(
    id: 'aes-128-ecb',
    keyLength: 16,
    ivLength: 0,
    processBytes: _processAesEcb,
  ),
  SymmetricAlgorithm(
    id: 'aes-192-ecb',
    keyLength: 24,
    ivLength: 0,
    processBytes: _processAesEcb,
  ),
  SymmetricAlgorithm(
    id: 'aes-256-ecb',
    keyLength: 32,
    ivLength: 0,
    processBytes: _processAesEcb,
  ),
  // AES-GCM（AEAD，12B nonce，128 位 tag）
  SymmetricAlgorithm(
    id: 'aes-128-gcm',
    keyLength: 16,
    ivLength: 12,
    processBytes: _processAesGcm,
  ),
  SymmetricAlgorithm(
    id: 'aes-192-gcm',
    keyLength: 24,
    ivLength: 12,
    processBytes: _processAesGcm,
  ),
  SymmetricAlgorithm(
    id: 'aes-256-gcm',
    keyLength: 32,
    ivLength: 12,
    processBytes: _processAesGcm,
  ),
  // AES-CTR
  SymmetricAlgorithm(
    id: 'aes-128-ctr',
    keyLength: 16,
    ivLength: 16,
    processBytes: _processAesCtr,
  ),
  SymmetricAlgorithm(
    id: 'aes-192-ctr',
    keyLength: 24,
    ivLength: 16,
    processBytes: _processAesCtr,
  ),
  SymmetricAlgorithm(
    id: 'aes-256-ctr',
    keyLength: 32,
    ivLength: 16,
    processBytes: _processAesCtr,
  ),
  // 3DES / Blowfish（OpenSSL 兼容；pointycastle 4.0 无单 DES 引擎）
  SymmetricAlgorithm(
    id: '3des-cbc',
    keyLength: 24,
    ivLength: 8,
    openSslCompatible: true,
    processBytes: _processDesEde3Cbc,
  ),
  SymmetricAlgorithm(
    id: 'blowfish-cbc',
    keyLength: 16,
    ivLength: 8,
    openSslCompatible: true,
    processBytes: _processBlowfishCbc,
  ),
  // RC4（OpenSSL 兼容；流密码）
  SymmetricAlgorithm(
    id: 'rc4',
    keyLength: 16,
    ivLength: 0,
    openSslCompatible: true,
    processBytes: _processRc4,
  ),
  // ChaCha20（RFC 7539）
  SymmetricAlgorithm(
    id: 'chacha20',
    keyLength: 32,
    ivLength: 12,
    processBytes: _processChaCha20,
  ),
];
