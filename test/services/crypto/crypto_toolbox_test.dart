/// 加解密工具箱单元测试。
///
/// 覆盖：
/// - 全部算法往返（对称/编码/经典/RSA，含中文与 emoji）
/// - ENC1 自描述格式打包/解析/路由
/// - OpenSSL Salted 兼容：解密 openssl enc 生成的真值向量（互操作证明）
/// - RSA PEM 解析（SPKI/PKCS#8/PKCS#1）+ openssl pkeyutl OAEP 真值解密
/// - 划词嗅探器
/// - 错误路径（错密码/坏密文/缺参数）
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/crypto/algorithms/rsa_algorithm.dart';
import 'package:fluxdo/services/crypto/crypto_algorithm.dart';
import 'package:fluxdo/services/crypto/crypto_cipher_format.dart';
import 'package:fluxdo/services/crypto/crypto_toolbox.dart';

const String _openSslPassword = 'fluxdo-test-\u5bc6\u7801123';
const String _plainText =
    'Hello fluxdo \u52a0\u89e3\u5bc6\u5de5\u5177\u7bb1 \ud83c\udf89 '
    '\u2014 round trip';

/// `openssl enc -<cipher> -salt -pass pass:...` 生成（OpenSSL 3.6.3）
const Map<String, String> _openSslVectors = {
  'aes-128-cbc':
      'U2FsdGVkX18tREhnE5mtSerQ1kWcPcBJ/7K+2y2IxV5oFhDjOLxdTO2Ah6vsBYCGGm0PZmNHh7VDkUQso2idqj8Kpe7XVk8x6S+awWb33hc=',
  'aes-192-cbc':
      'U2FsdGVkX18ncuZ/pjWCnEsz2/ARnXJ2aEP4RRy/XHvIgJfrmGL1N38EWXzTrUmLwE6dAHcWsJlHepoaLgtC76KCZYTtnD8zb2YtiWZMcYc=',
  'aes-256-cbc':
      'U2FsdGVkX18sm48IX40hWrvIY5sgvpWSqLbey9fLkF2vsgNyucZFoNlUrgFa5hZc8D2a1ntiZh65rvUa9hhyXofRi+Hm+WMon5VCv9AyHv0=',
  '3des-cbc':
      'U2FsdGVkX1+0MTSJWDggRsAze4r3TCCH3DcRr5EdxcE6rw/f3ELtCXW0ox99J/+P5tAdiRQg1dyedK6zBE1Z95ob7Qoi4V/i',
  'blowfish-cbc':
      'U2FsdGVkX19OiNhio4gHI61ZHoRKHjkODnV9TOf/tNVbts1Su/8I8Kl1p5s8U7vAkRnxtj6YfoORTB6Oi2s7BrLnKN2LLYOr',
  'rc4':
      'U2FsdGVkX18y1WaE5lVLHwX+oD4+wrt4wN5/eMR+3OpEcaLLs4C69KhuT/YHtkGz+k3yzMYCs8Vh/RNC88WHyUccCA==',
};

/// `openssl enc -<cipher> -salt -md md5` 生成（OpenSSL 1.x 经典 KDF 真值，
/// 也是 CyberChef 「OpenSSL EVP_BytesToKey」选项的行为）
const Map<String, String> _openSslMd5Vectors = {
  'aes-128-cbc':
      'U2FsdGVkX19L/n6A+JktMgLX3Jhwqh4Ojjax09uVU2/C1ZPnmguPo9QrGIvnA0E85/5QPe9m5YA0LRciUac/ZXeSZE7Qp7Uv58NrtG6dyQ0=',
  'aes-256-cbc':
      'U2FsdGVkX19WATWv3OBpXyLMUdfkLcuLXQ9fhOvv72Sq7g06ozgDcSeRTltE436jRXkXP2/qruDgPjXuD1VdQ4BxfkugghHRRyeq2n/taw8=',
  '3des-cbc':
      'U2FsdGVkX19j5Q0B6hXNi7ela7x2CP/u0JF/KoCCK58c7OcJYtjdMNKW+d/SBpdU8EnyffY0VS3Ew30oXuRA+W92vvji+Qw+',
};

/// openssl pkeyutl -encrypt -pubin -pkeyopt rsa_padding_mode:oaep
/// -pkeyopt rsa_oaep_md:sha256 的真值密文（明文见 [rsaInteropPlainText]）
const String _rsaOaepVector =
    'KIglorvZ7yR126mTRCzitfqnL6yd0v87+bzkPCkQK5UZXK+s4WWVmg6JqED1aFrz1+CJgGnVZiPBrD+9Izw1HgX+LvvhEDUpj4WwXzCS9PWHRIOD7Nk7RPLEqQYS6etx9q8KVWVCTwieaARC8y3KCtEwvLt/yqQP97yxALdjbuvGsjUWCmDNoycbFBkeXgBGp7ldxGHv4plephwyX79OfUDGODCgAPnlWABt1p4EVioEEoZLyWs/KGLz84pXnf+2srOWC8QG9CozEBGgENSY6JzNg23rQWTSmagei7N8cEmFOlKBEfGadFy4XlQwp9mtZapgmljYgFIaex/06pyWCg==';
const String rsaInteropPlainText = 'RSA OAEP SHA256 interop test 123';

const List<String> _rsaPublicKeyPem = [
    '-----BEGIN PUBLIC KEY-----'
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyBDlRpDFrQXY79ze3UqI'
    'FFOzY2E30IQDSiDXsTDHJR3pcvycLjhJV5w7SqVHYv9RCX2QkH2j9IEvo47sxykT'
    'gKjqE95I52hzXj+J6iIEiI+gUlU9LblZWv0J/WzvqVSXlpraAlkus0otU/gJeZ76'
    '2MDZw9KatgF9DiC6WHlNjzLgi79Z3zsZcjJVf4T+Hk7fIcyaWSZIbBClvavHETYW'
    'VMsAhFIDds1cOGI4JyX2PL7Nrq+RrRJrOm4SZzCH0mY5lA2OSiTt311VAc4t24tU'
    'fNDEff9jK+h5aQU/i0oOlKF9xNpqs0WT9YBVKtJSn9gbVPqeNdmY7yTCiwOpLU2G'
    'GQIDAQAB'
    '-----END PUBLIC KEY-----',
];

const List<String> _rsaPrivateKeyPkcs1Pem = [
    '-----BEGIN RSA PRIVATE KEY-----'
    'MIIEowIBAAKCAQEAyBDlRpDFrQXY79ze3UqIFFOzY2E30IQDSiDXsTDHJR3pcvyc'
    'LjhJV5w7SqVHYv9RCX2QkH2j9IEvo47sxykTgKjqE95I52hzXj+J6iIEiI+gUlU9'
    'LblZWv0J/WzvqVSXlpraAlkus0otU/gJeZ762MDZw9KatgF9DiC6WHlNjzLgi79Z'
    '3zsZcjJVf4T+Hk7fIcyaWSZIbBClvavHETYWVMsAhFIDds1cOGI4JyX2PL7Nrq+R'
    'rRJrOm4SZzCH0mY5lA2OSiTt311VAc4t24tUfNDEff9jK+h5aQU/i0oOlKF9xNpq'
    's0WT9YBVKtJSn9gbVPqeNdmY7yTCiwOpLU2GGQIDAQABAoIBACt7oJlptc0ZTEE1'
    '3Cp0nIbuejrLUno7dwuRf8+/Lkle6vJW/Qr+qNIl3q0mpxFZNJ+/bsA4zn3B5jzC'
    'P6w5vUdlbxrKYUYKaai+XpdItXuI2+uJIzbg5g7kmFtAZgaDoD7XgTKpd4D4SknJ'
    'yyVn7FVX9PyetYmBYVDExDuegcDxh31ltfALoLylpCtTMdZzXfWdbLOSuG4i1Wpy'
    'MFPBOuuFvkNddb6wSoN2NMVvrxa9bCTqaHEVYoIwBytEYtgxRBdPmEXgcmccRpI6'
    'Xrz7RENl/B0fwsntpqEpx90skDJ1g7NMWVN3xtIlQGsAyOmMvdKWdgneo4vh5K2a'
    'z4zxpUECgYEA55m1E2nhZiUqfF43qpVTvKisr2q224lQ6IPRsEnuPi9XL+TCKz/o'
    'EOsw5FkhCb0ca3aAL8ice82PPMkXeIILvHINKsZMGalPNa8hKOYyQ+TriJJae4Rf'
    'pz2SC8h5rU9xpp1M9vP5rLDuSbi6Oy8S37TWlU47KMcYjzRYJof/7G0CgYEA3SSz'
    'cbRepZCi5mmQF1VqDa3nJ6kSZlQPi4bszWpxWT8/vAr4bKoZP7tQqsxJI06YoG8i'
    'j8Rv1Po7eeYRVGPDAvtCLOyT4ambI+EAQCKspoIAITGF/mnF6tlqjpOlgkkJxZlI'
    'ETCA2Foi21jEacjOTWT4YuetuaeN86cyI678nN0CgYAfSuZrfBfnbEgkS7qrwsdw'
    'qz3B6eJRIWmcMQtpDWQyZMUcBIWzwEvD1XNityQ+o52ua3GAg1OZarna1bTlJHUf'
    'fi2HRQnNQdIhB8usMgZCpDCq4FN3cvhVqX0NOIYwQ5awk3ptt6NZkQJxVZNcIc0k'
    'CtQfklVt+hC4cLMkaaXLtQKBgD4awX5MPkxW6zi0KrAy357J2OHtfGpabycrFDO4'
    'Ee8TcS25Ev1JY9/fFg9xYZTVzM05iMZBT3rLb4qTTwiZH7oln/cH1ZwJSrVvyec5'
    'Fa2JUsn/o3bIc7m5p1A1LMUDCAiDPJb/PSAFaEabjkV7DFz13z+/eq1p3dawfMdC'
    'rFTNAoGBAK7jG6V5jXr86jmrWGdKPkASxwpKx6pX13xBLbMKVEsTnS9buuNZH1ZK'
    'BYEevyHNEyLcpqmoYSoraZ8/PaCQ8GnWpT5XO3dT1wJOiUjvN10jbCpqpzKqpdEr'
    '0JDaHEd7RQWUodp0clEmTnao/OxppIhoy+d2g0x8WujuuQzxTqwi'
    '-----END RSA PRIVATE KEY-----',
];

const List<String> _rsaPrivateKeyPkcs8Pem = [
    '-----BEGIN PRIVATE KEY-----'
    'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDIEOVGkMWtBdjv'
    '3N7dSogUU7NjYTfQhANKINexMMclHely/JwuOElXnDtKpUdi/1EJfZCQfaP0gS+j'
    'juzHKROAqOoT3kjnaHNeP4nqIgSIj6BSVT0tuVla/Qn9bO+pVJeWmtoCWS6zSi1T'
    '+Al5nvrYwNnD0pq2AX0OILpYeU2PMuCLv1nfOxlyMlV/hP4eTt8hzJpZJkhsEKW9'
    'q8cRNhZUywCEUgN2zVw4YjgnJfY8vs2ur5GtEms6bhJnMIfSZjmUDY5KJO3fXVUB'
    'zi3bi1R80MR9/2Mr6HlpBT+LSg6UoX3E2mqzRZP1gFUq0lKf2BtU+p412ZjvJMKL'
    'A6ktTYYZAgMBAAECggEAK3ugmWm1zRlMQTXcKnSchu56OstSejt3C5F/z78uSV7q'
    '8lb9Cv6o0iXerSanEVk0n79uwDjOfcHmPMI/rDm9R2VvGsphRgppqL5el0i1e4jb'
    '64kjNuDmDuSYW0BmBoOgPteBMql3gPhKScnLJWfsVVf0/J61iYFhUMTEO56BwPGH'
    'fWW18AugvKWkK1Mx1nNd9Z1ss5K4biLVanIwU8E664W+Q111vrBKg3Y0xW+vFr1s'
    'JOpocRVigjAHK0Ri2DFEF0+YReByZxxGkjpevPtEQ2X8HR/Cye2moSnH3SyQMnWD'
    's0xZU3fG0iVAawDI6Yy90pZ2Cd6ji+HkrZrPjPGlQQKBgQDnmbUTaeFmJSp8Xjeq'
    'lVO8qKyvarbbiVDog9GwSe4+L1cv5MIrP+gQ6zDkWSEJvRxrdoAvyJx7zY88yRd4'
    'ggu8cg0qxkwZqU81ryEo5jJD5OuIklp7hF+nPZILyHmtT3GmnUz28/mssO5JuLo7'
    'LxLftNaVTjsoxxiPNFgmh//sbQKBgQDdJLNxtF6lkKLmaZAXVWoNrecnqRJmVA+L'
    'huzNanFZPz+8Cvhsqhk/u1CqzEkjTpigbyKPxG/U+jt55hFUY8MC+0Is7JPhqZsj'
    '4QBAIqymggAhMYX+acXq2WqOk6WCSQnFmUgRMIDYWiLbWMRpyM5NZPhi5625p43z'
    'pzIjrvyc3QKBgB9K5mt8F+dsSCRLuqvCx3CrPcHp4lEhaZwxC2kNZDJkxRwEhbPA'
    'S8PVc2K3JD6jna5rcYCDU5lqudrVtOUkdR9+LYdFCc1B0iEHy6wyBkKkMKrgU3dy'
    '+FWpfQ04hjBDlrCTem23o1mRAnFVk1whzSQK1B+SVW36ELhwsyRppcu1AoGAPhrB'
    'fkw+TFbrOLQqsDLfnsnY4e18alpvJysUM7gR7xNxLbkS/Ulj398WD3FhlNXMzTmI'
    'xkFPestvipNPCJkfuiWf9wfVnAlKtW/J5zkVrYlSyf+jdshzubmnUDUsxQMICIM8'
    'lv89IAVoRpuORXsMXPXfP796rWnd1rB8x0KsVM0CgYEAruMbpXmNevzqOatYZ0o+'
    'QBLHCkrHqlfXfEEtswpUSxOdL1u641kfVkoFgR6/Ic0TItymqahhKitpnz89oJDw'
    'adalPlc7d1PXAk6JSO83XSNsKmqnMqql0SvQkNocR3tFBZSh2nRyUSZOdqj87Gmk'
    'iGjL53aDTHxa6O65DPFOrCI='
    '-----END PRIVATE KEY-----',
];

String _joinPem(List<String> lines) => '${lines.join('\n')}\n';

CryptoParams _paramsFor(CryptoAlgorithm algo, {String? password}) {
  return CryptoParams(
    password: password ?? _openSslPassword,
    rsaPem: algo.category == CryptoAlgorithmCategory.asymmetric
        ? _joinPem(_rsaPublicKeyPem)
        : null,
    vigenereKey: 'SECRET',
    railCount: 3,
    caesarShift: 3,
  );
}

CryptoParams _paramsPrivateKey({String? pem}) => CryptoParams(
      rsaPem: pem ?? _joinPem(_rsaPrivateKeyPkcs8Pem),
    );

void main() {
  group('全算法往返（含中文/emoji/空文本）', () {
    test('所有可逆算法 encrypt→decrypt 还原', () {
      for (final algo in CryptoToolbox.all) {
        if (!algo.isReversible) continue;
        // 摩斯只支持字母数字与常用标点，单独用例
        if (algo.id == 'morse') continue;
        for (final text in [_plainText, '', 'a']) {
          final params = _paramsFor(algo);
          final ct = CryptoToolbox.encrypt(
            plaintext: text,
            algorithmId: algo.id,
            params: params,
          );
          final back = CryptoToolbox.decrypt(
            ciphertext: ct,
            algorithmId: algo.id,
            params: algo.category == CryptoAlgorithmCategory.asymmetric
                ? _paramsPrivateKey()
                : params,
          );
          expect(back, text, reason: '${algo.id} 往返失败');
        }
      }
    });

    test('摩斯电码字母数字往返', () {
      const algoId = 'morse';
      const text = 'HELLO WORLD 123';
      final ct = CryptoToolbox.encrypt(
          plaintext: text,
          algorithmId: algoId,
          params: const CryptoParams());
      final back = CryptoToolbox.decrypt(
          ciphertext: ct, algorithmId: algoId, params: const CryptoParams());
      expect(back, text);
    });

    test('哈希确定且长度正确', () {
      final cases = {
        'md5': 32,
        'sha1': 40,
        'sha256': 64,
        'sha512': 128,
        'sm3': 64,
      };
      for (final e in cases.entries) {
        final a = CryptoToolbox.encrypt(
            plaintext: 'abc',
            algorithmId: e.key,
            params: const CryptoParams());
        expect(a.length, e.value, reason: e.key);
        expect(RegExp('^[0-9a-f]{${e.value}}\$').hasMatch(a), isTrue,
            reason: e.key);
      }
      // 已知向量
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'abc',
            algorithmId: 'md5',
            params: const CryptoParams()),
        '900150983cd24fb0d6963f7d28e17f72',
      );
    });
  });

  group('ENC1 自描述格式', () {
    test('打包结构正确且可自动识别算法', () {
      final ct = CryptoToolbox.encrypt(
        plaintext: _plainText,
        algorithmId: 'aes-256-gcm',
        params: const CryptoParams(password: 'pw'),
      );
      expect(ct.startsWith('ENC1:aes-256-gcm:'), isTrue);
      final sniffed = sniffCipher(ct);
      expect(sniffed?.kind, SniffedCipherKind.enc1);
      expect(sniffed?.algorithmId, 'aes-256-gcm');
      final suggestion = CryptoToolbox.suggestDecrypt(ct);
      expect(suggestion.algorithmId, 'aes-256-gcm');
      // 识别后用建议算法解密（划词场景主路径）
      final back = CryptoToolbox.decrypt(
        ciphertext: ct,
        algorithmId: suggestion.algorithmId!,
        params: const CryptoParams(password: 'pw'),
      );
      expect(back, _plainText);
    });

    test('ENC1 长明文（分块 RSA）', () {
      final long = _plainText * 30; // ~1.9KB，RSA-2048 多块
      final ct = CryptoToolbox.encrypt(
        plaintext: long,
        algorithmId: 'rsa-oaep-sha256',
        params: CryptoParams(rsaPem: _joinPem(_rsaPublicKeyPem)),
      );
      expect(ct.startsWith('ENC1:rsa-oaep-sha256:'), isTrue);
      final back = CryptoToolbox.decrypt(
        ciphertext: ct,
        algorithmId: 'rsa-oaep-sha256',
        params: _paramsPrivateKey(),
      );
      expect(back, long);
    });

    test('ENC1 解析容忍折行与空白', () {
      final parsed = enc1TryParse('  ENC1:aes-128-cbc:\n  QUJD\r\n  ');
      expect(parsed?.algorithmId, 'aes-128-cbc');
      expect(parsed?.payloadBase64, 'QUJD');
    });
  });

  group('OpenSSL Salted 互操作（openssl enc 真值向量）', () {
    for (final e in _openSslVectors.entries) {
      test('解密 openssl enc（3.x 默认 SHA-256 KDF）${e.key} 真值', () {
        final back = CryptoToolbox.decrypt(
          ciphertext: e.value,
          algorithmId: e.key,
          params: const CryptoParams(password: _openSslPassword),
        );
        expect(back, _plainText);
      });
    }

    for (final e in _openSslMd5Vectors.entries) {
      test('解密 openssl enc -md md5（1.x 经典 KDF）${e.key} 真值', () {
        final back = CryptoToolbox.decrypt(
          ciphertext: e.value,
          algorithmId: e.key,
          params: const CryptoParams(password: _openSslPassword),
        );
        expect(back, _plainText);
      });
    }

    test('openssl 格式输出可被自身解回（往返）', () {
      for (final algoId in _openSslVectors.keys) {
        final ct = CryptoToolbox.encrypt(
          plaintext: _plainText,
          algorithmId: algoId,
          params: const CryptoParams(password: _openSslPassword),
          format: CryptoOutputFormat.openssl,
        );
        expect(ct.startsWith('U2FsdGVkX1'), isTrue, reason: algoId);
        final back = CryptoToolbox.decrypt(
          ciphertext: ct,
          algorithmId: algoId,
          params: const CryptoParams(password: _openSslPassword),
        );
        expect(back, _plainText, reason: algoId);
      }
    });

    test('嗅探 OpenSSL 格式并建议默认算法', () {
      final sniffed = sniffCipher(_openSslVectors['aes-256-cbc']!);
      expect(sniffed?.kind, SniffedCipherKind.opensslSalted);
      final suggestion = CryptoToolbox.suggestDecrypt(
          _openSslVectors['aes-256-cbc']!);
      expect(suggestion.algorithmId, 'aes-256-cbc');
    });

    test('纯 base64 内容探测：UTF-8 文本建议 base64、二进制建议对称算法', () {
      // UTF-8 可读 → base64 编码
      expect(
          CryptoToolbox.suggestDecrypt(
                  base64.encode(utf8.encode('你好，世界')).toString())
              .algorithmId,
          'base64');
      // ENC1 裸 payload（剥前缀，二进制）→ 建议对称默认算法
      final enc1 = CryptoToolbox.encrypt(
        plaintext: '秘密内容',
        algorithmId: 'aes-256-cbc',
        params: const CryptoParams(password: 'pw'),
      );
      final naked = enc1.substring('ENC1:aes-256-cbc:'.length);
      expect(sniffCipher(naked)?.kind, SniffedCipherKind.plainBase64);
      expect(CryptoToolbox.suggestDecrypt(naked).algorithmId,
          CryptoToolbox.defaultAlgorithmId);
      // Hex 同理
      expect(
          CryptoToolbox.suggestDecrypt('e4bda0e5a5bde4bda0e5a5bd').algorithmId, 'hex');
    });
  });

  group('RSA PEM 解析与互操作', () {
    test('解析 SPKI 公钥', () {
      final key = parseRsaPem(_joinPem(_rsaPublicKeyPem));
      expect(key, isA<RsaParsedPublicKey>());
      expect((key as RsaParsedPublicKey).key.modulus!.bitLength, 2048);
    });

    test('解析 PKCS#1 与 PKCS#8 私钥', () {
      expect(parseRsaPem(_joinPem(_rsaPrivateKeyPkcs1Pem)),
          isA<RsaParsedPrivateKey>());
      expect(parseRsaPem(_joinPem(_rsaPrivateKeyPkcs8Pem)),
          isA<RsaParsedPrivateKey>());
    });

    test('公钥加密 → 两种私钥均可解密', () {
      final ct = CryptoToolbox.encrypt(
        plaintext: '跨 PEM 格式解密',
        algorithmId: 'rsa-oaep-sha256',
        params: CryptoParams(rsaPem: _joinPem(_rsaPublicKeyPem)),
      );
      for (final pem in [_rsaPrivateKeyPkcs1Pem, _rsaPrivateKeyPkcs8Pem]) {
        final back = CryptoToolbox.decrypt(
          ciphertext: ct,
          algorithmId: 'rsa-oaep-sha256',
          params: _paramsPrivateKey(pem: _joinPem(pem)),
        );
        expect(back, '跨 PEM 格式解密');
      }
    });

    test('解密 openssl pkeyutl OAEP-SHA256 真值（互操作）', () {
      final back = CryptoToolbox.decrypt(
        ciphertext: _rsaOaepVector,
        algorithmId: 'rsa-oaep-sha256',
        params: _paramsPrivateKey(),
      );
      expect(back, rsaInteropPlainText);
    });

    test('加密需要公钥/解密需要私钥的错误提示', () {
      expect(
        () => CryptoToolbox.encrypt(
          plaintext: 'x',
          algorithmId: 'rsa-oaep-sha256',
          params: _paramsPrivateKey(),
        ),
        throwsA(isA<CryptoException>()),
      );
      expect(
        () => CryptoToolbox.decrypt(
          ciphertext: _rsaOaepVector,
          algorithmId: 'rsa-oaep-sha256',
          params: CryptoParams(rsaPem: _joinPem(_rsaPublicKeyPem)),
        ),
        throwsA(isA<CryptoException>()),
      );
    });
  });

  group('划词嗅探器', () {
    test('识别各类密文特征', () {
      expect(sniffCipher('ENC1:aes-256-cbc:QUJDRA==')?.kind,
          SniffedCipherKind.enc1);
      expect(sniffCipher(_openSslVectors['aes-256-cbc']!)?.kind,
          SniffedCipherKind.opensslSalted);
      expect(sniffCipher('SGVsbG8gRmx1eGRvIQ==')?.kind,
          SniffedCipherKind.plainBase64);
      expect(sniffCipher('48656c6c6f2c20776f726c64')?.kind,
          SniffedCipherKind.plainHex);
      expect(sniffCipher('.... -- ..')?.kind, SniffedCipherKind.morse);
      // Unicode 变体（en dash / 间隔号）应识别
      expect(sniffCipher('.... –– ··')?.kind, SniffedCipherKind.morse);
      // 混入非法符号（… 省略号）不识别 —— 不合法输入宁缺毋滥
      expect(sniffCipher('.–. .-.. . .- … .- -.'), isNull);
      // URL 百分号编码
      expect(sniffCipher('%E4%BD%A0%E5%A5%BD')?.kind,
          SniffedCipherKind.urlEncoded);
      expect(CryptoToolbox.suggestDecrypt('%E4%BD%A0%E5%A5%BD').algorithmId,
          'url');
      // MIME 折行 Base64（多行纯 base64）
      expect(
          sniffCipher('TG9yZW0gaXBzdW0gZG9sb3Igc2l0IGFtZXQ=\n'
                  'Y29uc2VjdGV0dXIgYWRpcGlzY2luZw==')
              ?.kind,
          SniffedCipherKind.plainBase64);
      // 分隔 Hex（MAC/指纹风格）
      expect(sniffCipher('48:65:6c:6c:6f:20:77:6f')?.kind,
          SniffedCipherKind.plainHex);
      expect(sniffCipher('48-65-6c-6c-6f-20-77-6f')?.kind,
          SniffedCipherKind.plainHex);
      // Base32（大写 + 2-7 数字 + 8 倍数长度）
      expect(sniffCipher('NBSWY3DPEB3W64TMMQQGM33PEBRGC4Q=')?.kind,
          SniffedCipherKind.plainBase32);
      // 含 2-7 数字的大写长串按 base32 认（纯字母则落入 base64 分支）
      expect(sniffCipher('HELLOWORLDHELLOWORLDHELLOWORLD23')?.kind,
          SniffedCipherKind.plainBase32);
      // 纯大写英文词（无数字）被 base64 规则接住（不误报 base32）
      expect(sniffCipher('HELLOWORLDHELLOWORLDABCDEFGH')?.kind,
          SniffedCipherKind.plainBase64);

      // ```enc 代码块语言信号：内容无特征也显示（只选中密文片段场景）
      expect(isDecryptableText('任意片段', codeLanguage: 'enc'), isTrue);
      expect(isDecryptableText('任意片段', codeLanguage: 'dart'), isFalse);
      expect(isDecryptableText('ENC1:aes-256-cbc:QUJDRA=='), isTrue);
      // 普通文本不误报
      expect(sniffCipher('这是一段普通的中文文本'), isNull);
      expect(sniffCipher('The quick brown fox'), isNull);
      expect(sniffCipher('hello world 123'), isNull);
      expect(sniffCipher(''), isNull);
      // 纯 base64 猜测建议算法
      expect(CryptoToolbox.suggestDecrypt('SGVsbG8gRmx1eGRvIQ==').algorithmId,
          'base64');
    });
  });

  group('错误路径', () {
    test('错误密码抛 CryptoException', () {
      // 用 GCM（认证加密）：tag 校验确定失败，无 CBC padding 碰撞概率
      final ct = CryptoToolbox.encrypt(
        plaintext: _plainText,
        algorithmId: 'aes-256-gcm',
        params: const CryptoParams(password: 'right'),
      );
      expect(
        () => CryptoToolbox.decrypt(
          ciphertext: ct,
          algorithmId: 'aes-256-gcm',
          params: const CryptoParams(password: 'wrong'),
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('GCM 错误密码抛异常（tag 校验）', () {
      final ct = CryptoToolbox.encrypt(
        plaintext: _plainText,
        algorithmId: 'aes-256-gcm',
        params: const CryptoParams(password: 'right'),
      );
      expect(
        () => CryptoToolbox.decrypt(
          ciphertext: ct,
          algorithmId: 'aes-256-gcm',
          params: const CryptoParams(password: 'wrong'),
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('坏密文抛异常', () {
      expect(
        () => CryptoToolbox.decrypt(
          ciphertext: '!!!not-base64!!!',
          algorithmId: 'aes-256-cbc',
          params: const CryptoParams(password: 'pw'),
        ),
        throwsA(isA<CryptoException>()),
      );
      expect(
        () => CryptoToolbox.decrypt(
          ciphertext: 'QUJD', // 过短
          algorithmId: 'aes-256-cbc',
          params: const CryptoParams(password: 'pw'),
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('缺密码/缺密钥提示', () {
      expect(
        () => CryptoToolbox.encrypt(
          plaintext: 'x',
          algorithmId: 'aes-256-cbc',
          params: const CryptoParams(),
        ),
        throwsA(isA<CryptoException>()),
      );
      expect(
        () => CryptoToolbox.encrypt(
          plaintext: 'x',
          algorithmId: 'vigenere',
          params: const CryptoParams(),
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('哈希不可逆', () {
      expect(
        () => CryptoToolbox.decrypt(
          ciphertext: 'abc',
          algorithmId: 'sha256',
          params: const CryptoParams(),
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('未知算法抛异常', () {
      expect(
        () => CryptoToolbox.encrypt(
          plaintext: 'x',
          algorithmId: 'no-such-algo',
          params: const CryptoParams(),
        ),
        throwsA(isA<CryptoException>()),
      );
    });
  });

  group('经典密码', () {
    test('凯撒移位', () {
      const params = CryptoParams(caesarShift: 3);
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'abc XYZ', algorithmId: 'caesar', params: params),
        'def ABC',
      );
      expect(
        CryptoToolbox.decrypt(
            ciphertext: 'def ABC', algorithmId: 'caesar', params: params),
        'abc XYZ',
      );
    });

    test('维吉尼亚', () {
      const params = CryptoParams(vigenereKey: 'LEMON');
      final ct = CryptoToolbox.encrypt(
          plaintext: 'ATTACKATDAWN', algorithmId: 'vigenere', params: params);
      expect(ct, 'LXFOPVEFRNHR'); // 经典教科书向量
      expect(
        CryptoToolbox.decrypt(
            ciphertext: ct, algorithmId: 'vigenere', params: params),
        'ATTACKATDAWN',
      );
    });

    test('摩斯 Unicode 变体解码（en dash / 间隔号 / 项目符号）', () {
      const params = CryptoParams();
      // 标准编码输出
      final standard = CryptoToolbox.encrypt(
          plaintext: 'SOS', algorithmId: 'morse', params: params);
      expect(standard, '... --- ...');
      // 变体输入解码等价
      expect(
        CryptoToolbox.decrypt(
            ciphertext: '... ——— ...', algorithmId: 'morse', params: params),
        'SOS',
      );
      expect(
        CryptoToolbox.decrypt(
            ciphertext: '··· −−− ···', algorithmId: 'morse', params: params),
        'SOS',
      );
    });

    test('栅栏往返', () {
      const params = CryptoParams(railCount: 3);
      const text = 'WEAREDISCOVEREDFLEEATONCE';
      final ct = CryptoToolbox.encrypt(
          plaintext: text, algorithmId: 'railfence', params: params);
      expect(ct, 'WECRLTEERDSOEEFEAOCAIVDEN'); // 经典教科书向量
      expect(
        CryptoToolbox.decrypt(
            ciphertext: ct, algorithmId: 'railfence', params: params),
        text,
      );
    });
  });

  group('编码算法已知向量', () {
    test('base64', () {
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'hello',
            algorithmId: 'base64',
            params: const CryptoParams()),
        'aGVsbG8=',
      );
      // URL-safe 输入兼容
      expect(
        CryptoToolbox.decrypt(
            ciphertext: 'aGVsbG8', algorithmId: 'base64', params: const CryptoParams()),
        'hello',
      );
    });

    test('hex', () {
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'hi', algorithmId: 'hex', params: const CryptoParams()),
        '6869',
      );
      expect(
        CryptoToolbox.decrypt(
            ciphertext: '68 69',
            algorithmId: 'hex',
            params: const CryptoParams()),
        'hi',
      );
    });

    test('base32（RFC 4648 向量）', () {
      const params = CryptoParams();
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'foo', algorithmId: 'base32', params: params),
        'MZXW6===',
      );
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'foobar', algorithmId: 'base32', params: params),
        'MZXW6YTBOI======',
      );
      // 解码容忍小写与缺 padding
      expect(
        CryptoToolbox.decrypt(
            ciphertext: 'mzxw6ytboi', algorithmId: 'base32', params: params),
        'foobar',
      );
      expect(
        CryptoToolbox.decrypt(
            ciphertext: 'MZXW6YTBOI======',
            algorithmId: 'base32',
            params: params),
        'foobar',
      );
    });

    test('rot13', () {
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'Hello', algorithmId: 'rot13', params: const CryptoParams()),
        'Uryyb',
      );
    });

    test('url', () {
      expect(
        CryptoToolbox.encrypt(
            plaintext: 'a b&c',
            algorithmId: 'url',
            params: const CryptoParams()),
        'a%20b%26c',
      );
    });
  });

  test('ENC1 payload 裸格式（剥前缀后仍可解）', () {
    final ct = CryptoToolbox.encrypt(
      plaintext: _plainText,
      algorithmId: 'chacha20',
      params: const CryptoParams(password: 'pw'),
    );
    final naked = ct.substring('ENC1:chacha20:'.length);
    final back = CryptoToolbox.decrypt(
      ciphertext: naked,
      algorithmId: 'chacha20',
      params: const CryptoParams(password: 'pw'),
    );
    expect(back, _plainText);
  });

  test('EVP_BytesToKey 与 openssl 1 轮 MD5 派生一致（间接由向量覆盖）', () {
    // 直接来自 OpenSSL 向量解密成功即可证明；此处验证派生长度
    final derived = evpBytesToKey('pw', [1, 2, 3, 4, 5, 6, 7, 8], 32, 16);
    expect(derived.key.length, 32);
    expect(derived.iv.length, 16);
  });
}
