/// 经典密码算法：凯撒 / 维吉尼亚 / 栅栏 / 摩斯电码。
///
/// 参数化算法（移位数/密钥/栏数）从 [CryptoParams] 取值，均有默认值。
library;

import '../crypto_algorithm.dart';

/// 凯撒密码：字母移位（默认 3，正=右移），非字母原样保留。
class CaesarAlgorithm extends CryptoAlgorithm {
  const CaesarAlgorithm();

  @override
  String get id => 'caesar';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.classic;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    final shift = params.caesarShift % 26;
    return _shift(plaintext, shift);
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final shift = params.caesarShift % 26;
    return _shift(ciphertext, (26 - shift) % 26);
  }

  static String _shift(String input, int shift) {
    final sb = StringBuffer();
    for (final code in input.runes) {
      if (code >= 65 && code <= 90) {
        sb.writeCharCode(65 + (code - 65 + shift) % 26);
      } else if (code >= 97 && code <= 122) {
        sb.writeCharCode(97 + (code - 97 + shift) % 26);
      } else {
        sb.writeCharCode(code);
      }
    }
    return sb.toString();
  }
}

/// 维吉尼亚密码：按密钥字母逐位移位（A=0..Z=25，大小写均可作密钥）。
class VigenereAlgorithm extends CryptoAlgorithm {
  const VigenereAlgorithm();

  @override
  String get id => 'vigenere';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.classic;

  @override
  String encrypt(String plaintext, CryptoParams params) =>
      _process(plaintext, params, decrypt: false);

  @override
  String decrypt(String ciphertext, CryptoParams params) =>
      _process(ciphertext, params, decrypt: true);

  static String _process(String input, CryptoParams params,
      {required bool decrypt}) {
    final keyRaw = params.vigenereKey?.replaceAll(RegExp(r'[^A-Za-z]'), '') ??
        '';
    if (keyRaw.isEmpty) {
      throw const CryptoException('维吉尼亚密码需要字母密钥');
    }
    final key = keyRaw.toUpperCase().codeUnits;
    final sb = StringBuffer();
    var keyIndex = 0;
    for (final code in input.runes) {
      if (code >= 65 && code <= 90) {
        final shift = key[keyIndex % key.length] - 65;
        sb.writeCharCode(
            65 + (code - 65 + (decrypt ? 26 - shift : shift)) % 26);
        keyIndex++;
      } else if (code >= 97 && code <= 122) {
        final shift = key[keyIndex % key.length] - 65;
        sb.writeCharCode(
            97 + (code - 97 + (decrypt ? 26 - shift : shift)) % 26);
        keyIndex++;
      } else {
        sb.writeCharCode(code);
      }
    }
    return sb.toString();
  }
}

/// 栅栏密码：按 [CryptoParams.railCount] 栏之字形排布后逐行读取。
class RailFenceAlgorithm extends CryptoAlgorithm {
  const RailFenceAlgorithm();

  @override
  String get id => 'railfence';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.classic;

  @override
  String encrypt(String plaintext, CryptoParams params) {
    final rails = params.railCount;
    if (rails < 2) throw const CryptoException('栅栏数至少为 2');
    if (plaintext.length < 2) return plaintext;

    final rows = List.generate(rails, (_) => StringBuffer());
    var row = 0;
    var down = true;
    for (final ch in plaintext.runes) {
      rows[row].writeCharCode(ch);
      if (down) {
        row++;
        if (row == rails - 1) down = false;
      } else {
        row--;
        if (row == 0) down = true;
      }
    }
    return rows.map((r) => r.toString()).join();
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final rails = params.railCount;
    if (rails < 2) throw const CryptoException('栅栏数至少为 2');
    final n = ciphertext.length;
    if (n < 2) return ciphertext;

    // 计算每个字符落在哪一栏，再按密文顺序恢复
    final pattern = List<int>.filled(n, 0);
    var row = 0;
    var down = true;
    for (var i = 0; i < n; i++) {
      pattern[i] = row;
      if (down) {
        row++;
        if (row == rails - 1) down = false;
      } else {
        row--;
        if (row == 0) down = true;
      }
    }
    // 每栏的长度 → 密文中各栏的连续区间
    final counts = List<int>.filled(rails, 0);
    for (final r in pattern) {
      counts[r]++;
    }
    final offsets = List<int>.filled(rails, 0);
    var acc = 0;
    for (var r = 0; r < rails; r++) {
      offsets[r] = acc;
      acc += counts[r];
    }
    final cursor = List<int>.of(offsets);
    final units = ciphertext.runes.toList();
    final out = List<int>.filled(units.length, 0);
    for (var i = 0; i < pattern.length && i < units.length; i++) {
      out[i] = units[cursor[pattern[i]]++];
    }
    return String.fromCharCodes(out);
  }
}

/// 摩斯字形规范化：把常见 Unicode 横线/点变体统一到 `.` `-`。
///
/// 从网页/IM 复制的摩斯电码常带排版变体：en dash `–`、em dash `—`、
/// 一字线 `―`、减号 `−`、连接符 `‐` → `-`；间隔号 `·`、项目符号 `•`、
/// 黑点 `●`、点号 `․` → `.`。
String normalizeMorseGlyphs(String text) => text
    .replaceAll(RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]'), '-')
    .replaceAll(RegExp(r'[\u00b7\u2022\u25cf\u2024\u2027]'), '.');

/// 摩斯电码：26 字母 + 数字 + 常用标点。
///
/// 编码：字母间单空格、词间 ` / `；解码容忍多空格与 `-`/`–` 混用。
class MorseAlgorithm extends CryptoAlgorithm {
  const MorseAlgorithm();

  @override
  String get id => 'morse';

  @override
  CryptoAlgorithmCategory get category => CryptoAlgorithmCategory.classic;

  static const Map<String, String> _toMorse = {
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.', 'F': '..-.',
    'G': '--.', 'H': '....', 'I': '..', 'J': '.---', 'K': '-.-', 'L': '.-..',
    'M': '--', 'N': '-.', 'O': '---', 'P': '.--.', 'Q': '--.-', 'R': '.-.',
    'S': '...', 'T': '-', 'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-',
    'Y': '-.--', 'Z': '--..',
    '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
    '.': '.-.-.-', ',': '--..--', '?': '..--..', '!': '-.-.--', "'": '.----.',
    '"': '.-..-.', '/': '-..-.', '(': '-.--.', ')': '-.--.-', '&': '.-...',
    ':': '---...', ';': '-.-.-.', '=': '-...-', '+': '.-.-.', '-': '-....-',
    '@': '.--.-.',
  };

  static final Map<String, String> _fromMorse = {
    for (final e in _toMorse.entries) e.value: e.key,
  };

  @override
  String encrypt(String plaintext, CryptoParams params) {
    final words = plaintext.toUpperCase().split(' ');
    final encodedWords = <String>[];
    for (final word in words) {
      final parts = <String>[];
      for (final ch in word.runes) {
        final s = String.fromCharCode(ch);
        final code = _toMorse[s];
        if (code != null) {
          parts.add(code);
        }
      }
      encodedWords.add(parts.join(' '));
    }
    return encodedWords.join(' / ');
  }

  @override
  String decrypt(String ciphertext, CryptoParams params) {
    final sb = StringBuffer();
    final tokens = normalizeMorseGlyphs(ciphertext)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    for (final token in tokens) {
      if (token == '/') {
        sb.write(' ');
        continue;
      }
      final ch = _fromMorse[token];
      if (ch == null) {
        throw CryptoException('无法识别的摩斯码: $token');
      }
      sb.write(ch);
    }
    return sb.toString();
  }
}

const List<CryptoAlgorithm> classicAlgorithms = [
  CaesarAlgorithm(),
  VigenereAlgorithm(),
  RailFenceAlgorithm(),
  MorseAlgorithm(),
];
