import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Agent 配置守卫：规则只有 AGENTS.md 一份，skill 只有 .agents/skills 一份，
/// 其他工具的入口文件只做导入或软链。
void main() {
  test('CLAUDE.md、GEMINI.md 只导入 AGENTS.md', () {
    expect(File('AGENTS.md').existsSync(), isTrue);
    for (final name in ['CLAUDE.md', 'GEMINI.md']) {
      expect(
        File(name).readAsStringSync().trim(),
        '@AGENTS.md',
        reason: '$name 只能包含 @AGENTS.md，规则请写进 AGENTS.md',
      );
    }
  });

  test('.claude/skills 是指向 .agents/skills 的软链', () {
    final type = FileSystemEntity.typeSync(
      '.claude/skills',
      followLinks: false,
    );
    expect(
      type,
      FileSystemEntityType.link,
      reason:
          '.claude/skills 应是软链，当前检出成了 $type。Windows 上请开启开发者模式，'
          '执行 git config core.symlinks true 后再执行 git checkout -- .claude',
    );
    expect(
      Link('.claude/skills').targetSync().replaceAll(r'\', '/'),
      '../.agents/skills',
    );
  });

  test('skill 的 frontmatter 只用标准字段，name 与目录名一致', () {
    const standardFields = {
      'name',
      'description',
      'license',
      'compatibility',
      'metadata',
      'allowed-tools',
    };
    final skills = Directory('.agents/skills')
        .listSync()
        .whereType<Directory>()
        .toList();
    expect(skills, isNotEmpty);
    for (final dir in skills) {
      final dirName = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final file = File('${dir.path}/SKILL.md');
      expect(file.existsSync(), isTrue, reason: '$dirName 缺少 SKILL.md');
      final lines = file.readAsLinesSync();
      expect(lines.first, '---', reason: '$dirName/SKILL.md 缺少 frontmatter');
      final end = lines.indexOf('---', 1);
      expect(end, greaterThan(0), reason: '$dirName/SKILL.md frontmatter 未闭合');
      final fields = <String, String>{};
      for (final line in lines.sublist(1, end)) {
        // 只看顶层键；缩进行属于上一个键的值（如 metadata 的子项）
        final match = RegExp(r'^([A-Za-z][\w-]*):\s*(.*)$').firstMatch(line);
        if (match != null) fields[match[1]!] = match[2]!;
      }
      expect(
        fields.keys.toSet().difference(standardFields),
        isEmpty,
        reason: '$dirName 使用了非标准字段，其他 agent 会忽略它们',
      );
      expect(fields['name'], dirName);
      expect(fields['description'], isNotEmpty);
    }
  });
}
