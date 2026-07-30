import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../providers/discourse_providers.dart';
import '../../../utils/font_awesome_helper.dart';
import '../../../widgets/topic/topic_summary_widget.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/relative_time_text.dart';
import '../../../utils/number_utils.dart';
import '../../../widgets/topic/topic_notification_button.dart';
import '../../../widgets/layout/home_workspace_scope.dart';
import 'topic_vote_button.dart';
import '../../../widgets/common/topic_badges.dart';
import '../../category_topics_page.dart';
import '../../tag_topics_page.dart';
import '../../../widgets/topic/assign_sheet.dart';

/// 话题详情页头部组件
class TopicDetailHeader extends ConsumerWidget {
  final TopicDetail detail;
  final GlobalKey? headerKey;
  final void Function(int, bool)? onVoteChanged;
  final void Function(TopicNotificationLevel)? onNotificationLevelChanged;
  final bool showTitle;

  /// 跳转到当前话题的指定帖子
  final void Function(int postNumber)? onJumpToPost;

  const TopicDetailHeader({
    super.key,
    required this.detail,
    this.headerKey,
    this.onVoteChanged,
    this.onNotificationLevelChanged,
    this.showTitle = true,
    this.onJumpToPost,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final category = categoryMap?[detail.categoryId];

    FaIconData? faIcon;
    String? logoUrl;

    if (category != null) {
      faIcon = FontAwesomeHelper.getIcon(category.icon);
      logoUrl = category.uploadedLogo;

      if (faIcon == null &&
          (logoUrl == null || logoUrl.isEmpty) &&
          category.parentCategoryId != null) {
        final parent = categoryMap?[category.parentCategoryId];
        faIcon = FontAwesomeHelper.getIcon(parent?.icon);
        logoUrl = parent?.uploadedLogo;
      }
    }

    return Container(
      padding: EdgeInsets.fromLTRB(16, showTitle ? 20 : 12, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle)
            SelectableText.rich(
              TextSpan(
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                  letterSpacing: 0.2,
                ),
                children: [
                  if (detail.isPrivateMessage)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Symbols.mail_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  if (detail.closed)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Symbols.lock_rounded,
                          size: 20,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  if (detail.hasAcceptedAnswer)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Symbols.check_box_rounded,
                          size: 20,
                          color: Colors.green,
                        ),
                      ),
                    ),
                  ...EmojiText.buildEmojiSpans(
                    context,
                    detail.title,
                    theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
              key: headerKey,
            )
          else
            SizedBox(key: headerKey),

          SizedBox(height: showTitle ? 16 : 8),

          // 分类与标签（私信话题不显示）
          if (!detail.isPrivateMessage &&
              (category != null ||
                  (detail.tags != null && detail.tags!.isNotEmpty))) ...[
            Wrap(
              spacing: 6,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 分类 Badge
                if (category != null)
                  CategoryBadge(
                    category: category,
                    faIcon: faIcon,
                    logoUrl: logoUrl,
                    onTap: () {
                      final workspace = HomeWorkspaceScope.maybeOf(context);
                      if (workspace != null) {
                        workspace.onShowCategory(category);
                        return;
                      }
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              CategoryTopicsPage(category: category),
                        ),
                      );
                    },
                  ),

                // 标签 Badges
                if (detail.tags != null)
                  ...detail.tags!.map(
                    (tag) => TagBadge(
                      name: tag.name,
                      onTap: () {
                        final workspace = HomeWorkspaceScope.maybeOf(context);
                        if (workspace != null) {
                          workspace.onShowTag(tag.name);
                          return;
                        }
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => TagTopicsPage(tagName: tag.name),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // 指定(discourse-assign)标识:有指定对象才显示,点开直接跳到
          // 指定弹窗——之前只在"更多"菜单的文字里标了状态,标题区域完全
          // 看不出来,指定完等于白指定。
          if (detail.isAssigned) ...[
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => unawaited(
                showAssignSheet(context, ref, topicId: detail.id),
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.assignment_ind_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '已指定给 '
                      '${detail.assignedToUser?.displayName ?? detail.assignedToGroupName ?? ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Metadata Row (Replies, Views, Date, Vote Button)
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _buildMetadataItem(
                      context,
                      Symbols.chat_bubble_rounded,
                      '${detail.postsCount - 1}',
                      label: context.l10n.topicDetail_replyLabel,
                    ),
                    _buildMetadataItem(
                      context,
                      Symbols.visibility_rounded,
                      NumberUtils.formatCount(detail.views),
                      label: context.l10n.topicDetail_viewsLabel,
                    ),
                    Tooltip(
                      message: TimeUtils.formatTooltipTime(detail.createdAt),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Symbols.schedule_rounded,
                            size: 14,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 4),
                          RelativeTimeText(
                            dateTime: detail.createdAt,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant
                                      .withValues(alpha: 0.8),
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 投票按钮
              TopicVoteButton(topic: detail, onVoteChanged: onVoteChanged),
            ],
          ),

          // AI 摘要 & 订阅按钮
          const SizedBox(height: 16),
          CollapsibleTopicSummary(
            topicId: detail.id,
            topicDetail: detail,
            onJumpToPost: onJumpToPost,
            headerExtra: TopicNotificationButton(
              level: detail.notificationLevel,
              onChanged: onNotificationLevelChanged,
              style: TopicNotificationButtonStyle.chip,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataItem(
    BuildContext context,
    IconData icon,
    String text, {
    String? label,
  }) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            fontWeight: FontWeight.w500,
          ),
        ),
        if (label != null) ...[
          const SizedBox(width: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ],
      ],
    );
  }
}
