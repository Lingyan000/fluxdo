import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import '../../l10n/s.dart';

/// 折叠态的帖子条（纯 UI 组件）
///
/// 显示：[⊕] username · N 条回复
/// 点击展开帖子及子树
///
/// 对应 Discourse CSS: `nested-post__collapsed-bar`
class NestedCollapsedBar extends StatelessWidget {
  final String username;
  final int replyCount;
  final VoidCallback onTap;

  const NestedCollapsedBar({
    super.key,
    required this.username,
    required this.replyCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.add_circle_rounded,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              username,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '·',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
              ),
            ),
            Text(
              context.l10n.nested_repliesCount(replyCount),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
