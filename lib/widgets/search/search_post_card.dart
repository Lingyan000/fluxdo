import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../providers/category_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/number_utils.dart';
import '../../utils/time_utils.dart';
import '../common/smart_avatar.dart';
import '../common/topic_badges.dart';

/// 搜索结果帖子卡片
class SearchPostCard extends ConsumerWidget {
  final SearchPost post;
  final VoidCallback? onTap;

  const SearchPostCard({
    super.key,
    required this.post,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final topic = post.topic;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = topic?.categoryId;
    Category? category;
    if (categoryId != null && categoryMap != null) {
      category = categoryMap[categoryId];
    }

    // 图标逻辑：本级 FA Icon -> 本级 Logo -> 父级 FA Icon -> 父级 Logo
    IconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.hardEdge,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 标题行
              if (topic != null)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildTopicTitle(post, topic, theme)),
                    // 楼层号
                    if (post.postNumber > 1)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '#${post.postNumber}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),

              const SizedBox(height: 10),

              // 2. 分类与标签行
              if (topic != null && (category != null || topic.tags.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
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
                      ...topic.tags
                          .take(3)
                          .map((tag) => TagBadge(name: tag.name)),
                    ],
                  ),
                ),

              // 3. 帖子摘要
              if (post.blurb.isNotEmpty) ...[
                _buildBlurb(post.blurb, theme),
                const SizedBox(height: 12),
              ],

              // 4. 底部信息栏
              Row(
                children: [
                  // 用户头像
                  SmartAvatar(
                    imageUrl: post.getAvatarUrl().isNotEmpty
                        ? post.getAvatarUrl(size: 48)
                        : null,
                    radius: 12,
                    fallbackText: post.username,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    post.username,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const Spacer(),

                  // 点赞数
                  if (post.likeCount > 0) ...[
                    Icon(
                      Icons.favorite_border_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      NumberUtils.formatCount(post.likeCount),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],

                  // 时间
                  Text(
                    TimeUtils.formatRelativeTime(post.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
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

  Widget _buildTopicTitle(SearchPost post, SearchTopic topic, ThemeData theme) {
    // 如果有高亮标题，使用高亮版本
    if (post.topicTitleHeadline != null &&
        post.topicTitleHeadline!.isNotEmpty) {
      return _buildHighlightedText(
        post.topicTitleHeadline!,
        theme,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (topic.closed)
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 2),
            child: Icon(Icons.lock, size: 16, color: theme.colorScheme.outline),
          ),
        if (topic.archived)
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 2),
            child: Icon(
              Icons.archive,
              size: 16,
              color: theme.colorScheme.outline,
            ),
          ),
        Expanded(
          child: Text(
            topic.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildBlurb(String blurb, ThemeData theme) {
    return _buildHighlightedText(
      blurb,
      theme,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.4,
      ),
    );
  }

  Widget _buildHighlightedText(
    String text,
    ThemeData theme, {
    TextStyle? style,
  }) {
    // Discourse 使用 <span class="search-highlight">...</span> 来高亮
    final regex = RegExp(r'<span class="search-highlight">(.*?)</span>');
    final matches = regex.allMatches(text);

    if (matches.isEmpty) {
      // 没有高亮，直接显示纯文本（移除其他 HTML 标签）
      final cleanText = text.replaceAll(RegExp(r'<[^>]*>'), '');
      return Text(
        cleanText,
        style: style,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }

    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      // 添加高亮前的文本
      if (match.start > lastEnd) {
        final beforeText = text
            .substring(lastEnd, match.start)
            .replaceAll(RegExp(r'<[^>]*>'), '');
        spans.add(TextSpan(text: beforeText));
      }

      // 添加高亮文本
      final highlightedText = match.group(1) ?? '';
      spans.add(
        TextSpan(
          text: highlightedText,
          style: TextStyle(
            backgroundColor: theme.colorScheme.primaryContainer,
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

      lastEnd = match.end;
    }

    // 添加剩余文本
    if (lastEnd < text.length) {
      final afterText = text
          .substring(lastEnd)
          .replaceAll(RegExp(r'<[^>]*>'), '');
      spans.add(TextSpan(text: afterText));
    }

    return RichText(
      text: TextSpan(style: style, children: spans),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}
