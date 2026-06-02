import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/platform_utils.dart';
import '../../utils/url_helper.dart';
import '../common/topic_badges.dart';
import '../common/smart_avatar.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/relative_time_text.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';

/// 话题卡片组件 — 紧凑横向布局
class TopicCard extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onTap;
  final VoidCallback? onMiddleClick;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final Color? highlightColor;
  final Widget? topWidget;
  final Widget? bottomWidget;

  const TopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.isSelected = false,
    this.highlightColor,
    this.topWidget,
    this.bottomWidget,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUnread = topic.unseen || topic.unread > 0;
    // 全部读完：进入过话题且没有未读帖子
    final isFullyRead =
        !topic.unseen && topic.unread == 0 && topic.lastReadPostNumber != null;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = categoryMap?[categoryId];

    // 图标逻辑优先级：
    // 1. 本级 FA Icon
    // 2. 本级 Logo
    // 3. 父级 FA Icon
    // 4. 父级 Logo
    FaIconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : highlightColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected
            ? BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              )
            : BorderSide.none,
      ),
      child: GestureDetector(
        onTertiaryTapUp: PlatformUtils.isDesktop && onMiddleClick != null
            ? (_) => onMiddleClick!.call()
            : null,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: PlatformUtils.isDesktop ? onLongPress : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部附属区域（如书签元信息色带）
              if (topWidget != null) ...[topWidget!],
              Opacity(
                opacity: isFullyRead ? 0.5 : 1.0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 左侧：楼主头像
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _buildOriginalPosterAvatar(context),
                      ),
                      const SizedBox(width: 10),
                      // 右侧：两行内容
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 第1行：标题 + 回复数/未读数
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text.rich(
                                    TextSpan(
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w500,
                                            height: 1.3,
                                            color: isUnread
                                                ? theme.colorScheme.onSurface
                                                : theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                          ),
                                      children: [
                                        if (topic.closed)
                                          WidgetSpan(
                                            alignment:
                                                PlaceholderAlignment.middle,
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                right: 4,
                                              ),
                                              child: Icon(
                                                Icons.lock_outline,
                                                size: 16,
                                                color: isUnread
                                                    ? theme
                                                          .colorScheme
                                                          .onSurface
                                                    : theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        if (topic.hasAcceptedAnswer)
                                          WidgetSpan(
                                            alignment:
                                                PlaceholderAlignment.middle,
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                right: 4,
                                              ),
                                              child: Icon(
                                                Icons.check_box,
                                                size: 16,
                                                color: Colors.green,
                                              ),
                                            ),
                                          )
                                        else if (topic.canHaveAnswer)
                                          WidgetSpan(
                                            alignment:
                                                PlaceholderAlignment.middle,
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                right: 4,
                                              ),
                                              child: Icon(
                                                Icons.check_box_outline_blank,
                                                size: 16,
                                                color:
                                                    theme.colorScheme.outline,
                                              ),
                                            ),
                                          ),
                                        ...EmojiText.buildEmojiSpans(
                                          context,
                                          topic.title,
                                          theme.textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.w500,
                                            height: 1.3,
                                            color: isUnread
                                                ? theme.colorScheme.onSurface
                                                : theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                          ),
                                        ),
                                        // 未读蓝点追加在标题末尾
                                        if (topic.unseen)
                                          WidgetSpan(
                                            alignment:
                                                PlaceholderAlignment.middle,
                                            child: Container(
                                              margin: const EdgeInsets.only(
                                                left: 6,
                                              ),
                                              width: 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                color:
                                                    theme.colorScheme.primary,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 右上角：回复数或未读数
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: _buildReplyOrUnread(context),
                                ),
                              ],
                            ),

                            const SizedBox(height: 6),

                            // 第2行：分类+标签（左） + 点赞+时间（右）
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 左侧：分类和标签
                                Expanded(
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      if (category != null)
                                        CategoryBadge(
                                          category: category,
                                          faIcon: faIcon,
                                          logoUrl: logoUrl,
                                        ),
                                      ...topic.tags.map(
                                        (tag) => TagBadge(name: tag.name),
                                      ),
                                    ],
                                  ),
                                ),
                                // 右侧：点赞 + 时间
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (topic.likeCount > 0) ...[
                                      _buildStat(
                                        context,
                                        Icons.favorite_border_rounded,
                                        topic.likeCount,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '·',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant
                                                  .withValues(alpha: 0.5),
                                            ),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    RelativeTimeText(
                                      dateTime: topic.lastPostedAt,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant
                                                .withValues(alpha: 0.7),
                                          ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 底部附属区域
              if (bottomWidget != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 2, 14, 8),
                  child: bottomWidget!,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建楼主头像
  Widget _buildOriginalPosterAvatar(BuildContext context) {
    final theme = Theme.of(context);
    // 取第一个 poster（Original Poster）
    if (topic.posters.isNotEmpty) {
      final op = topic.posters.first;
      if (op.user != null) {
        final avatarUrl = op.user!.getAvatarUrl(size: 68);
        return SmartAvatar(
          imageUrl: avatarUrl,
          radius: 17,
          fallbackText: op.user!.username,
        );
      }
    }
    // fallback：用 lastPosterUsername 首字母
    if (topic.lastPosterUsername != null) {
      return CircleAvatar(
        radius: 17,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Text(
          topic.lastPosterUsername![0].toUpperCase(),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      );
    }
    return const SizedBox(width: 34, height: 34);
  }

  /// 回复数/未读数切换
  Widget _buildReplyOrUnread(BuildContext context) {
    final theme = Theme.of(context);
    if (topic.unread > 0) {
      // 未读数：主题色圆角徽章
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '${topic.unread}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    } else {
      // 回复数：带热度颜色
      final replies = (topic.postsCount - 1).clamp(0, 999999);
      if (replies <= 0) return const SizedBox.shrink();
      final heatColor = _replyHeatColor(topic, theme);
      return _buildStat(
        context,
        Icons.chat_bubble_outline_rounded,
        replies,
        color: heatColor,
        bold: heatColor != null,
      );
    }
  }

  /// 计算 likes/posts 比率
  double _heatRatio(Topic topic) {
    if (topic.postsCount < 10) return 0;
    return topic.likeCount / topic.postsCount;
  }

  /// 回复数热度颜色
  Color? _replyHeatColor(Topic topic, ThemeData theme) {
    final ratio = _heatRatio(topic);
    if (ratio > 2.0) return const Color(0xFFFE7A15); // 高热度-橙色
    if (ratio > 1.0) return const Color(0xFFCF7721); // 中热度-暗橙色
    if (ratio > 0.5) return const Color(0xFF9B764F); // 低热度-褐色
    return null; // 默认颜色
  }

  Widget _buildStat(
    BuildContext context,
    IconData icon,
    int count, {
    Color? color,
    bool bold = false,
  }) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: effectiveColor),
        const SizedBox(width: 3),
        Text(
          NumberUtils.formatCount(count),
          style: theme.textTheme.labelSmall?.copyWith(
            color: effectiveColor,
            fontWeight: bold ? FontWeight.w600 : null,
          ),
        ),
      ],
    );
  }
}

/// 紧凑型话题卡片 - 用于置顶话题
class CompactTopicCard extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onTap;
  final VoidCallback? onMiddleClick;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final Color? highlightColor;

  const CompactTopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.isSelected = false,
    this.highlightColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUnread = topic.unseen || topic.unread > 0;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = categoryMap?[categoryId];

    // 图标逻辑
    FaIconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : highlightColor ??
                theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected
            ? BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              )
            : BorderSide.none,
      ),
      child: GestureDetector(
        onTertiaryTapUp: PlatformUtils.isDesktop && onMiddleClick != null
            ? (_) => onMiddleClick!.call()
            : null,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: PlatformUtils.isDesktop ? onLongPress : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // 1. 置顶图标
                Icon(
                  Icons.push_pin_rounded,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),

                // 2. 分类图标/Dot
                if (category != null) ...[
                  if (faIcon != null)
                    FaIcon(faIcon, size: 12, color: _parseColor(category.color))
                  else if (logoUrl != null && logoUrl.isNotEmpty)
                    Image(
                      image: discourseImageProvider(
                        UrlHelper.resolveUrlWithCdn(logoUrl),
                      ),
                      width: 12,
                      height: 12,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return _buildCategoryDot(category);
                      },
                    )
                  else
                    _buildCategoryDot(category),
                  const SizedBox(width: 8),
                ],

                // 3. 标题
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: isUnread
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: isUnread
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      children: [
                        if (topic.closed)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Icons.lock_outline,
                                size: 12,
                                color: isUnread
                                    ? theme.colorScheme.onSurface
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (topic.hasAcceptedAnswer)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Icons.check_box,
                                size: 12,
                                color: Colors.green,
                              ),
                            ),
                          )
                        else if (topic.canHaveAnswer)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Icons.check_box_outline_blank,
                                size: 12,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                        ...EmojiText.buildEmojiSpans(
                          context,
                          topic.title,
                          theme.textTheme.labelMedium?.copyWith(
                            fontWeight: isUnread
                                ? FontWeight.w500
                                : FontWeight.w400,
                            color: isUnread
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                const SizedBox(width: 8),

                // 4. 未读数或简单状态
                if (topic.unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.7,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${topic.unread}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                        fontSize: 9,
                      ),
                    ),
                  )
                else if (topic.postsCount > 1)
                  Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 12,
                        color: theme.colorScheme.outline.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${topic.postsCount - 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.7,
                          ),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryDot(Category category) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: _parseColor(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}
