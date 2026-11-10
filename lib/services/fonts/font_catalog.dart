import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 字体槽位。
enum FontSlot {
  /// 正文
  body,

  /// 代码等宽
  mono,
}

/// 可下载字体条目。
///
/// 字体文件来自公开 npm 包：大陆走 npmmirror 整包（tgz），其余走 jsDelivr /
/// unpkg 单文件。[sha256] 是字体文件本身的哈希，[tarballIntegrity] 是整包的
/// npm 完整性串（sha512），两者都在安装前校验。
@immutable
class FontEntry {
  const FontEntry({
    required this.id,
    required this.family,
    required this.slot,
    required this.name,
    required this.license,
    required this.package,
    required this.version,
    required this.file,
    required this.size,
    required this.sha256,
    required this.tarballSize,
    required this.tarballIntegrity,
  });

  /// 稳定标识，用于持久化。
  final String id;

  /// 注册给引擎的字族名（TextStyle.fontFamily）。
  final String family;
  final FontSlot slot;

  /// 显示名（按语言代码）。
  final Map<String, String> name;
  final String license;

  /// npm 包名与版本（版本固定，内容不可变）。
  final String package;
  final String version;

  /// 字体文件在包内的路径（不含 `package/` 前缀）。
  final String file;

  /// 字体文件字节数与 sha256（十六进制小写）。
  final int size;
  final String sha256;

  /// 整包 tgz 字节数与 npm 完整性串（`sha512-<base64>`）。
  final int tarballSize;
  final String tarballIntegrity;

  /// 包名去掉 scope 的部分（tarball 文件名用）。
  String get packageBaseName => package.split('/').last;

  factory FontEntry.fromJson(Map<String, dynamic> json) {
    final tarball = json['tarball'] as Map<String, dynamic>;
    return FontEntry(
      id: json['id'] as String,
      family: json['family'] as String,
      slot: FontSlot.values.byName(json['slot'] as String),
      name: {
        for (final e in (json['name'] as Map).entries)
          e.key as String: e.value as String,
      },
      license: json['license'] as String,
      package: json['package'] as String,
      version: json['version'] as String,
      file: json['file'] as String,
      size: json['size'] as int,
      sha256: json['sha256'] as String,
      tarballSize: tarball['size'] as int,
      tarballIntegrity: tarball['integrity'] as String,
    );
  }
}

/// 内置字体目录（`assets/fonts/catalog.json`）。
class FontCatalog {
  FontCatalog._();

  static const String assetPath = 'assets/fonts/catalog.json';

  static List<FontEntry> _fonts = const [];

  static List<FontEntry> get all => _fonts;

  static List<FontEntry> ofSlot(FontSlot slot) =>
      _fonts.where((f) => f.slot == slot).toList();

  static FontEntry? byId(String? id) {
    for (final font in _fonts) {
      if (font.id == id) return font;
    }
    return null;
  }

  static Future<void> load([AssetBundle? bundle]) async {
    try {
      final raw = await (bundle ?? rootBundle).loadString(assetPath);
      setAll(parse(raw));
    } catch (e) {
      debugPrint('[FontCatalog] 字体目录加载失败: $e');
    }
  }

  static List<FontEntry> parse(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return [
      for (final f in json['fonts'] as List)
        FontEntry.fromJson(f as Map<String, dynamic>),
    ];
  }

  @visibleForTesting
  static void setAll(List<FontEntry> fonts) {
    _fonts = List.unmodifiable(fonts);
  }
}
