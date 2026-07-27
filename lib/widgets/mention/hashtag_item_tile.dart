import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../models/hashtag_item.dart';
import '../../utils/font_awesome_name_mapping.dart';

/// `#` 补全浮层里的一行候选(分类带色块、标签带话题数)。
///
/// 两个编辑器(源码版 MarkdownEditor 与富文本 RichComposer)共用同一行样式,
/// 免得两边视觉漂移。
class HashtagItemTile extends StatelessWidget {
  const HashtagItemTile({
    super.key,
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final HashtagItem item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCategory = item.kind == HashtagKind.category;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.1)
            : null,
        child: Row(
          children: [
            _buildIcon(theme, isCategory),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.label,
                style: theme.textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (item.secondaryText?.isNotEmpty ?? false)
              Text(
                item.secondaryText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 图标口径对齐网页端:用服务端给的 `icon`(站点 hashtag_icons,分类
  /// 默认 folder、标签默认 tag,分类可自定义)映射到 Font Awesome;
  /// 认不出来的名字按类型兜底。分类的图标用分类色,标签用次要色。
  Widget _buildIcon(ThemeData theme, bool isCategory) {
    final name = item.icon;
    final fa = name == null || name.isEmpty
        ? null
        : faIconNameMapping['solid $name'];
    final color = isCategory
        ? _parseColor(item.colorHex, theme)
        : theme.colorScheme.onSurfaceVariant;
    if (fa != null) {
      return FaIcon(fa, size: 14, color: color);
    }
    return Icon(
      isCategory ? Icons.folder : Icons.sell_outlined,
      size: 14,
      color: color,
    );
  }

  Color _parseColor(String? hex, ThemeData theme) {
    final raw = hex?.replaceAll('#', '').trim();
    if (raw == null || raw.length != 6) {
      return theme.colorScheme.outlineVariant;
    }
    final value = int.tryParse(raw, radix: 16);
    if (value == null) return theme.colorScheme.outlineVariant;
    return Color(0xFF000000 | value);
  }
}
