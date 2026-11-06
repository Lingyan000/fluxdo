import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../utils/time_utils.dart';

/// 帖子编辑指示器：铅笔图标 + 编辑次数,紧贴时间右侧。
///
/// 对齐 discourse 网页版 `post/meta-data/edits-indicator.gjs`：
/// - 图标：普通帖 [Symbols.edit_rounded]，wiki 帖 [Symbols.auto_stories_rounded]
/// - 数字：[Post.editsCount]（首次发布不显示数字）
/// - tooltip：显示最后编辑时间(wiki / 普通文案不同)
/// - 点击三分支：
///   1. wiki && version == 1 && canEdit → [onEnterEditor]
///   2. canViewEditHistory → [onShowHistory]
///   3. 其它：tooltip 改成"无权查看编辑历史",按钮禁用
class EditsIndicator extends StatelessWidget {
  final Post post;
  final VoidCallback? onShowHistory;
  final VoidCallback? onEnterEditor;

  const EditsIndicator({
    super.key,
    required this.post,
    this.onShowHistory,
    this.onEnterEditor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.colorScheme.onSurfaceVariant;
    final color = base.withValues(alpha: 0.8);
    final disabledColor = base.withValues(alpha: 0.35);

    final isWikiFirstVersion = post.wiki && post.version == 1;
    final canEnterEditor =
        isWikiFirstVersion && post.canEdit && onEnterEditor != null;
    final canShowHistory =
        post.canViewEditHistory && post.version > 1 && onShowHistory != null;
    final enabled = canEnterEditor || canShowHistory;

    final tooltip = _buildTooltip(context, enabled: enabled);
    final iconData = post.wiki
        ? Symbols.auto_stories_rounded
        : Symbols.edit_rounded;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(iconData, size: 12, color: enabled ? color : disabledColor),
        if (post.editsCount > 0) ...[
          const SizedBox(width: 2),
          Text(
            '${post.editsCount}',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: enabled ? color : disabledColor,
              fontWeight: FontWeight.w500,
              height: 1.0,
            ),
          ),
        ],
      ],
    );

    final tappable = enabled
        ? InkResponse(
            radius: 14,
            customBorder: const RoundedSuperellipseBorder(
              borderRadius: BorderRadius.all(Radius.circular(9999)),
            ),
            onTap: () {
              if (canEnterEditor) {
                onEnterEditor!.call();
              } else if (canShowHistory) {
                onShowHistory!.call();
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: content,
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: content,
          );

    return Tooltip(message: tooltip, preferBelow: false, child: tappable);
  }

  String _buildTooltip(BuildContext context, {required bool enabled}) {
    final l10n = context.l10n;
    if (post.wiki && post.version <= 1) {
      return l10n.postRevision_wikiAbout;
    }

    final lastEditedTimeText = TimeUtils.formatTooltipTime(
      post.lastWikiEdit ?? post.updatedAt,
    );
    if (post.wiki) {
      return l10n.postRevision_wikiEditTooltip(lastEditedTimeText);
    }
    if (!enabled && post.version > 1) {
      return l10n.postRevision_indicatorDisabled;
    }
    return l10n.postRevision_indicatorTooltipEdited(lastEditedTimeText);
  }
}
