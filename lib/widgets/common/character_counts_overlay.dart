import 'package:flutter/material.dart';

import '../../plugins/plugins.dart';

/// 悬浮在输入区右下角的「字数不足」提示
///
/// 对齐网页端：主题组件只输出 `<div class="character-counts">`，
/// 悬浮定位由主题 CSS 完成。这里用 [Positioned] 叠在输入区之上实现同样效果。
///
/// 只在**字数不足**时出现（对齐 `missingReplyCharacters > 0`），达标即消失 ——
/// 字数充足时用户不需要任何提示，常驻计数只是噪音。
///
/// 纯文字无背景：这是辅助提示而非主体内容，加底色/圆角会喧宾夺主。
class CharacterCountsOverlay extends StatelessWidget {
  /// 当前字数
  final int length;

  /// 最小字数；null 或 <= 0 时不显示
  final int? minimumLength;

  /// 是否展示站点插件提供的警告文案（如「勿用各类字数补丁」）
  ///
  /// 对齐主题组件的 `showWarning`：正文传 true，标题不传。
  final bool showWarning;

  const CharacterCountsOverlay({
    super.key,
    required this.length,
    this.minimumLength,
    this.showWarning = true,
  });

  @override
  Widget build(BuildContext context) {
    final min = minimumLength;
    if (min == null || min <= 0 || length >= min) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final warning = showWarning
        ? PluginRegistry.charCountWarning(context)
        : null;

    return IgnorePointer(
      child: Text(
        warning == null ? '$length / $min' : '$length / $min  $warning',
        textAlign: TextAlign.end,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
