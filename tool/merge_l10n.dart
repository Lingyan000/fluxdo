import 'dart:convert';
import 'dart:io';

/// 多语言模块合并工具
///
/// 将 lib/l10n/modules/ 下各模块的 ARB 文件合并为 lib/l10n/merged/ 下的
/// 单个 ARB 文件，供 flutter gen-l10n 使用。
///
/// 用法:
///   dart run tool/merge_l10n.dart          # 合并
///   dart run tool/merge_l10n.dart --check  # 仅校验，不写入文件
void main(List<String> args) {
  final checkOnly = args.contains('--check');
  final projectRoot = Directory.current.path;
  final modulesDir = Directory(_join(projectRoot, 'lib', 'l10n', 'modules'));
  final mergedDir = Directory(_join(projectRoot, 'lib', 'l10n', 'merged'));

  if (!modulesDir.existsSync()) {
    stderr.writeln('[ERROR] 模块目录不存在: ${modulesDir.path}');
    exit(1);
  }

  // 支持的 locale 列表，排序稳定
  const templateLocale = 'zh';
  const locales = ['zh', 'en', 'zh_HK', 'zh_TW'];

  // 1. 扫描模块目录
  final modules = modulesDir
      .listSync()
      .whereType<Directory>()
      .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .toList()
    ..sort();

  if (modules.isEmpty) {
    stderr.writeln('[ERROR] 未找到任何模块目录');
    exit(1);
  }

  // 2. 收集数据并校验
  // locale -> 有序 key-value 列表
  final mergedData = <String, Map<String, dynamic>>{};
  for (final locale in locales) {
    mergedData[locale] = {'@@locale': locale};
  }

  final globalKeyMap = <String, String>{}; // key -> module name（用于唯一性校验）
  final errors = <String>[];
  final warnings = <String>[];

  for (final module in modules) {
    final moduleDir =
        Directory(_join(modulesDir.path, module));

    for (final locale in locales) {
      final file = _findArbFile(moduleDir, module, locale);
      if (file == null) {
        if (locale == templateLocale) {
          errors.add('模块 "$module" 缺少模板语言 ($templateLocale) 的 ARB 文件');
        } else {
          warnings.add('模块 "$module" 缺少 $locale 翻译');
        }
        continue;
      }

      final Map<String, dynamic> data;
      try {
        data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } catch (e) {
        errors.add('模块 "$module" 的 ${file.path} 解析失败: $e');
        continue;
      }

      for (final entry in data.entries) {
        final key = entry.key;
        if (key == '@@locale') continue;

        // 唯一性校验（仅对非 @metadata 的 key，仅在模板语言中检查）
        if (!key.startsWith('@') && locale == templateLocale) {
          if (globalKeyMap.containsKey(key)) {
            errors.add(
                'Key "$key" 重复: 出现在模块 "${globalKeyMap[key]}" 和 "$module" 中');
          }
          globalKeyMap[key] = module;
        }

        mergedData[locale]![key] = entry.value;
      }
    }
  }

  // 3. Placeholder 校验（仅模板语言）
  final templateData = mergedData[templateLocale]!;
  for (final key in templateData.keys) {
    if (key.startsWith('@') || key == '@@locale') continue;
    final value = templateData[key];
    if (value is String && RegExp(r'\{[a-zA-Z]').hasMatch(value)) {
      final metaKey = '@$key';
      if (!templateData.containsKey(metaKey)) {
        errors.add('Key "$key" 含有占位符但缺少 $metaKey 元数据定义');
      }
    }
  }

  // 输出警告
  for (final w in warnings) {
    stderr.writeln('[WARN]  $w');
  }

  // 输出错误
  if (errors.isNotEmpty) {
    for (final e in errors) {
      stderr.writeln('[ERROR] $e');
    }
    stderr.writeln('\n[FAILED] 校验失败，共 ${errors.length} 个错误');
    exit(1);
  }

  // 统计
  final keyCount = globalKeyMap.length;
  stdout.writeln('[OK] 校验通过: ${modules.length} 个模块, $keyCount 个 key, '
      '${locales.length} 种语言');

  if (checkOnly) {
    exit(0);
  }

  // 4. 写入合并文件
  if (!mergedDir.existsSync()) {
    mergedDir.createSync(recursive: true);
  }

  final encoder = JsonEncoder.withIndent('  ');

  for (final locale in locales) {
    final fileName = _arbFileName(locale);
    final outputFile = File(_join(mergedDir.path, fileName));
    final content = encoder.convert(mergedData[locale]);
    outputFile.writeAsStringSync('$content\n');
  }

  stdout.writeln('[OK] 合并完成, 已写入 ${mergedDir.path}');
}

/// 在模块目录中查找指定 locale 的 ARB 文件
///
/// 文件命名规则: {模块名}_{locale}.arb
File? _findArbFile(Directory moduleDir, String module, String locale) {
  final file = File(_join(moduleDir.path, '${module}_$locale.arb'));
  if (file.existsSync()) return file;
  return null;
}

/// 根据 locale 生成合并后的 ARB 文件名
String _arbFileName(String locale) => 'app_$locale.arb';

String _join(String a, [String? b, String? c, String? d]) {
  final parts = <String?>[a, b, c, d].whereType<String>().toList();
  return parts.join(Platform.pathSeparator);
}
