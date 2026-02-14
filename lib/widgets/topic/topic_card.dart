import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../utils/color_utils.dart';
import '../../utils/url_helper.dart';
import '../../utils/font_awesome_helper.dart';
import '../common/topic_badges.dart';
import '../common/smart_avatar.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/time_utils.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';

/// 话题卡片组件
class TopicCard extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;

  const TopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUnread = topic.unseen || topic.unread > 0;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final category = categoryMap?[topic.categoryId];
    
    // 图标逻辑优先级：
    // 1. 本级 FA Icon
    // 2. 本级 Logo
    // 3. 父级 FA Icon
    // 4. 父级 Logo
    
    // 检查 FA Icon
    IconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    
    // 检查 Logo
    String? logoUrl = category?.uploadedLogo;

    // 如果本级没有图标，尝试父级
    if (faIcon == null && (logoUrl == null || logoUrl.isEmpty) && category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    return RepaintBoundary(
      child: Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.hardEdge,
      elevation: isSelected ? 0 : 0,
      color: isSelected ? theme.colorScheme.primaryContainer.withValues(alpha:0.4) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha:0.5)
              : theme.colorScheme.outlineVariant.withValues(alpha:0.5),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 标题行
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 新话题蓝点
                    if (topic.unseen)
                      Container(
                        margin: const EdgeInsets.only(right: 8, top: 6),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                            color: isUnread
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          children: [
                            if (topic.closed)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Icon(
                                    Icons.lock_outline,
                                    size: 16,
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
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Icon(
                                    Icons.check_box,
                                    size: 16,
                                    color: Colors.green,
                                  ),
                                ),
                              )
                            else if (topic.canHaveAnswer)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Icon(
                                    Icons.check_box_outline_blank,
                                    size: 16,
                                    color: theme.colorScheme.outline,
                                  ),
                                ),
                              ),
                            ...EmojiText.buildEmojiSpans(context, topic.title, theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                              color: isUnread
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurfaceVariant,
                            )),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 未读数量徽章
                    if (topic.unread > 0)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${topic.unread}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                
                const SizedBox(height: 10),
                
                // 2. 分类与标签行
                if (category != null || topic.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // 分类 Badge
                        if (category != null)
                          CategoryBadge(
                            category: category,
                            faIcon: faIcon,
                            logoUrl: logoUrl,
                          ),
                        
                        // 标签 Badges
                        ...topic.tags.map(
                          (tag) => TagBadge(
                            name: tag.name,
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 14),

                // 3. 底部信息栏 (头像 + 统计)
                Row(
                  children: [
                    // 左侧：参与者头像
                    if (topic.posters.isNotEmpty)
                      _buildStackedAvatars(context, topic.posters)
                    else if (topic.lastPosterUsername != null)
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: theme.colorScheme.secondaryContainer,
                        child: Text(
                          topic.lastPosterUsername![0].toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),

                    const Spacer(),

                    // 右侧：统计数据
                    _buildStat(context, Icons.chat_bubble_outline_rounded, (topic.postsCount - 1).clamp(0, 999999)),
                    const SizedBox(width: 12),

                    if (topic.likeCount > 0) ...[
                      _buildStat(context, Icons.favorite_border_rounded, topic.likeCount),
                      const SizedBox(width: 12),
                    ],

                    Text(
                      TimeUtils.formatRelativeTime(topic.lastPostedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.7),
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

  Widget _buildStackedAvatars(BuildContext context, List<TopicPoster> posters) {
    // Filter valid users
    final validPosters = posters.where((p) => p.user != null).toList();
    if (validPosters.isEmpty) return const SizedBox();

    const double avatarSize = 24.0;
    const double overlap = 10.0;
    
    // Display up to 5 posters
    final displayPosters = validPosters.take(5).toList();
    
    return SizedBox(
      height: avatarSize,
      width: avatarSize + (displayPosters.length - 1) * (avatarSize - overlap),
      child: Stack(
        children: List.generate(displayPosters.length, (index) {
          final poster = displayPosters[index];
          
          final avatarUrl = poster.user!.getAvatarUrl(size: 48);
          return Positioned(
            left: index * (avatarSize - overlap),
            child: SmartAvatar(
              imageUrl: avatarUrl,
              radius: avatarSize / 2,
              fallbackText: poster.user!.username,
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 1.5,
              ),
            ),
          );
        }).reversed.toList(),
      ),
    );
  }
  
  Widget _buildStat(BuildContext context, IconData icon, int count) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          NumberUtils.formatCount(count),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
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
  final VoidCallback? onLongPress;
  final bool isSelected;

  const CompactTopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUnread = topic.unseen || topic.unread > 0;
    
    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final category = categoryMap?[topic.categoryId];
    
    // 图标逻辑
    IconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null && (logoUrl == null || logoUrl.isEmpty) && category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.hardEdge,
      elevation: isSelected ? 0 : 0,
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha:0.4)
          : theme.colorScheme.surfaceContainerLow.withValues(alpha:0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha:0.5)
              : theme.colorScheme.outlineVariant.withValues(alpha:0.4),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
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
                  FaIcon(
                    faIcon,
                    size: 12,
                    color: ColorUtils.parseHex(category.color),
                  )
                else if (logoUrl != null && logoUrl.isNotEmpty)
                  Image(
                    image: discourseImageProvider(
                      UrlHelper.resolveUrl(logoUrl),
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
                      fontWeight: isUnread ? FontWeight.w600 : FontWeight.w400,
                      color: isUnread ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
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
                              color: isUnread ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
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
                      ...EmojiText.buildEmojiSpans(context, topic.title, theme.textTheme.labelMedium?.copyWith(
                        fontWeight: isUnread ? FontWeight.w600 : FontWeight.w400,
                        color: isUnread ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                      )),
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha:0.7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${topic.unread}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                      fontSize: 9,
                    ),
                  ),
                )
              else if (topic.postsCount > 1)
                 Row(
                   children: [
                     Icon(Icons.chat_bubble_outline_rounded, size: 12, color: theme.colorScheme.outline.withValues(alpha:0.7)),
                     const SizedBox(width: 2),
                     Text(
                        '${topic.postsCount - 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline.withValues(alpha:0.7),
                          fontSize: 10,
                        ),
                     ),
                   ],
                 ),
            ],
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
        color: ColorUtils.parseHex(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

}
