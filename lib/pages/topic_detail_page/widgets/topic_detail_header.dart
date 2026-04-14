import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'topic_vote_button.dart';
import '../../../widgets/common/topic_badges.dart';
import '../../category_topics_page.dart';
import '../../tag_topics_page.dart';

/// 话题详情页头部组件
class TopicDetailHeader extends ConsumerWidget {
  final TopicDetail detail;
  final GlobalKey? headerKey;
  final void Function(int, bool)? onVoteChanged;
  final void Function(TopicNotificationLevel)? onNotificationLevelChanged;
  /// 跳转到当前话题的指定帖子
  final void Function(int postNumber)? onJumpToPost;

  const TopicDetailHeader({
    super.key,
    required this.detail,
    this.headerKey,
    this.onVoteChanged,
    this.onNotificationLevelChanged,
    this.onJumpToPost,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final category = categoryMap?[detail.categoryId];

    IconData? faIcon;
    String? logoUrl;

    if (category != null) {
      faIcon = FontAwesomeHelper.getIcon(category.icon);
      logoUrl = category.uploadedLogo;

      if (faIcon == null && (logoUrl == null || logoUrl.isEmpty) && category.parentCategoryId != null) {
        final parent = categoryMap?[category.parentCategoryId];
        faIcon = FontAwesomeHelper.getIcon(parent?.icon);
        logoUrl = parent?.uploadedLogo;
      }
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha:0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          SelectableText.rich(
            TextSpan(
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
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
                        Icons.mail_outline,
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
                        Icons.lock_rounded,
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
                        Icons.check_box,
                        size: 20,
                        color: Colors.green,
                      ),
                    ),
                  ),
                ...EmojiText.buildEmojiSpans(context, detail.title, theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  height: 1.4,
                )),
              ],
            ),
            key: headerKey,
          ),

          const SizedBox(height: 16),
          
          // 分类与标签（私信话题不显示）
          if (!detail.isPrivateMessage && (category != null || (detail.tags != null && detail.tags!.isNotEmpty))) ...[
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
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => CategoryTopicsPage(category: category)),
                    ),
                  ),

                // 标签 Badges
                if (detail.tags != null)
                  ...detail.tags!.map((tag) => TagBadge(
                    name: tag.name,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => TagTopicsPage(tagName: tag.name)),
                    ),
                  )),
              ],
            ),
            const SizedBox(height: 16),
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
                      Icons.chat_bubble_outline_rounded,
                      '${detail.postsCount - 1}',
                      label: context.l10n.topicDetail_replyLabel
                    ),
                    _buildMetadataItem(
                      context,
                      Icons.visibility_outlined,
                      NumberUtils.formatCount(detail.views),
                      label: context.l10n.topicDetail_viewsLabel
                    ),
                    Tooltip(
                      message: TimeUtils.formatTooltipTime(detail.createdAt),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 4),
                          RelativeTimeText(
                            dateTime: detail.createdAt,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
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
              TopicVoteButton(
                topic: detail,
                onVoteChanged: onVoteChanged,
              ),
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

  Widget _buildMetadataItem(BuildContext context, IconData icon, String text, {String? label}) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.7),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.8),
            fontWeight: FontWeight.w500,
          ),
        ),
        if (label != null) ...[
          const SizedBox(width: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.5),
            ),
          ),
        ],
      ],
    );
  }


}
