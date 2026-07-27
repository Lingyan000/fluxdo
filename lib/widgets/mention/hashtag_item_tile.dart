import 'package:flutter/material.dart';

import '../../models/hashtag_item.dart';

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
            if (isCategory)
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _parseColor(item.colorHex, theme),
                  borderRadius: BorderRadius.circular(3),
                ),
              )
            else
              Icon(
                Icons.sell_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
