import 'package:fluxdo/utils/avatar_url.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../../utils/time_utils.dart';
import '../../../../utils/url_helper.dart';
import '../../../common/smart_avatar.dart';
import '../../../../theme/app_colors.dart';

/// 解决方案横幅(仅在主贴下方展示)
///
/// 渲染:
/// - 顶部绿色 header:"已解决  N 解决方案"
/// - 列表每行:头像 + 用户名 + 时间 + 展开/折叠箭头
/// - 默认第一项展开,展示摘要 + "阅读更多"跳转
class PostSolutionBanner extends StatefulWidget {
  final List<AcceptedAnswer> acceptedAnswers;
  final void Function(int postNumber)? onJumpToPost;

  const PostSolutionBanner({
    super.key,
    required this.acceptedAnswers,
    this.onJumpToPost,
  });

  @override
  State<PostSolutionBanner> createState() => _PostSolutionBannerState();
}

class _PostSolutionBannerState extends State<PostSolutionBanner> {
  /// 当前展开行的索引,-1 表示全部折叠
  int _expandedIndex = 0;

  @override
  void didUpdateWidget(PostSolutionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表长度变化时,如展开项超出新列表范围,回退到默认展开第一项
    if (_expandedIndex >= widget.acceptedAnswers.length) {
      _expandedIndex = widget.acceptedAnswers.isEmpty ? -1 : 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final answers = widget.acceptedAnswers;
    if (answers.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: ShapeDecoration(
            color: isDark
                ? context.appColors.green.withValues(alpha: 0.05)
                : context.appColors.green.withValues(alpha: 0.04),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: context.appColors.green.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BannerHeader(count: answers.length),
              for (var i = 0; i < answers.length; i++)
                _AnswerRow(
                  key: ValueKey('accepted-answer-${answers[i].postNumber}'),
                  answer: answers[i],
                  expanded: _expandedIndex == i,
                  isLast: i == answers.length - 1,
                  onToggle: () {
                    setState(() {
                      _expandedIndex = _expandedIndex == i ? -1 : i;
                    });
                  },
                  onJumpToPost: widget.onJumpToPost,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BannerHeader extends StatelessWidget {
  final int count;
  const _BannerHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2E7D32) : const Color(0xFF43A047),
      ),
      child: Row(
        children: [
          const Icon(Symbols.check_box_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            context.l10n.post_topicSolved,
            style: theme.textTheme.titleSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          if (count > 1) ...[
            const SizedBox(width: 12),
            Text(
              context.l10n.post_solutionsCount(count),
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnswerRow extends StatelessWidget {
  final AcceptedAnswer answer;
  final bool expanded;
  final bool isLast;
  final VoidCallback onToggle;
  final void Function(int postNumber)? onJumpToPost;

  const _AnswerRow({
    super.key,
    required this.answer,
    required this.expanded,
    required this.isLast,
    required this.onToggle,
    required this.onJumpToPost,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = (answer.name?.isNotEmpty ?? false)
        ? answer.name!
        : answer.username;
    final timeText = TimeUtils.formatRelativeTime(answer.createdAt);
    final avatarUrl = (answer.avatarTemplate?.isNotEmpty ?? false)
        ? UrlHelper.resolveUrlWithCdn(
            AvatarUrl.resolve(answer.avatarTemplate!, size: 48),
          )
        : null;
    final hasExcerpt = (answer.excerpt?.isNotEmpty ?? false);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: hasExcerpt
                ? onToggle
                : () => onJumpToPost?.call(answer.postNumber),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  SmartAvatar(
                    imageUrl: avatarUrl,
                    radius: 12,
                    fallbackText: displayName.isNotEmpty
                        ? displayName.substring(0, 1).toUpperCase()
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (timeText.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            '·',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            timeText,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (hasExcerpt)
                    Icon(
                      expanded
                          ? Symbols.expand_less_rounded
                          : Symbols.expand_more_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  else
                    Icon(
                      Symbols.arrow_forward_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (expanded && hasExcerpt)
            _ExpandedExcerpt(
              excerpt: answer.excerpt!,
              postNumber: answer.postNumber,
              onJumpToPost: onJumpToPost,
            ),
        ],
      ),
    );
  }
}

class _ExpandedExcerpt extends StatelessWidget {
  final String excerpt;
  final int postNumber;
  final void Function(int postNumber)? onJumpToPost;

  const _ExpandedExcerpt({
    required this.excerpt,
    required this.postNumber,
    required this.onJumpToPost,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 解决方案摘要:改用自研 FluxdoRender 只读预览(非正文场景关闭选区)
          FluxdoRenderCallbacks.generic(
            heroTagNamespace: 'solution_excerpt_$postNumber',
          ).render(
            cookedHtml: excerpt,
            baseTextStyle: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              height: 1.5,
              color: theme.colorScheme.onSurface,
            ),
            compact: true,
            selectionEnabled: false,
          ),
          const SizedBox(height: 6),
          InkWell(
            onTap: () => onJumpToPost?.call(postNumber),
            customBorder: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Text(
                context.l10n.post_readMore,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
