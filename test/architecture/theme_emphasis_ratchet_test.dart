import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 主题一致性守卫：同一块区域里颜色、圆角要一致，靠 token 而不是字面量。
///
/// 两项都是只降不升的计数：存量是确认过的合理用法（链接图标、头像、
/// 状态圆点等），新增写法要走 token。主题层本身与生成代码不在约束内。
Iterable<(String, String)> _sources() sync* {
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (!path.endsWith('.dart') ||
        path.endsWith('.g.dart') ||
        path.startsWith('lib/theme/')) {
      continue;
    }
    yield (path, entity.readAsStringSync());
  }
}

List<String> _scan(RegExp pattern) => [
  for (final (path, source) in _sources())
    for (final m in pattern.allMatches(source))
      '$path:${'\n'.allMatches(source.substring(0, m.start)).length + 1}',
];

void main() {
  test('图标不直接取强调色', () {
    // 存量 3 处都是链接图标（链接本身就用强调色）
    const baseline = 3;
    final offenders = _scan(
      RegExp(
        r'(?<![A-Za-z0-9_])(Icon|FaIcon)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*?'
        r'\bcolor:\s*[^,\n]*\b(colorScheme|cs|scheme|colors)\.primary\b',
      ),
    );
    expect(
      offenders.length,
      lessThanOrEqualTo(baseline),
      reason:
          '图标颜色请按意图取 token：入口 / 区块图标用 context.emphasis.accent，'
          '选中 / 已开启用 context.emphasis.selected，普通操作图标不写颜色'
          '（图标按钮主题统一为次要色）：\n${offenders.join('\n')}',
    );
  });

  test('按钮与图标底座不写死正圆', () {
    // 存量是头像、状态圆点、色点、徽标、媒体覆盖层控件等保持圆形的元素
    const baseline = 79;
    final offenders = _scan(RegExp(r'BoxShape\.circle|CircleBorder\('));
    expect(
      offenders.length,
      lessThanOrEqualTo(baseline),
      reason:
          '圆形按钮 / 图标底座请用 context.shapes.circle()（方正风格下随主题'
          '收成圆角方）；头像、状态圆点这类始终是圆的元素才写 BoxShape.circle'
          '，并相应调整本守卫的基线：\n${offenders.join('\n')}',
    );
  });
}
