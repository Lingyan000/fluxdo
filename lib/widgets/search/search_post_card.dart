import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../providers/category_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/number_utils.dart';
import '../../utils/platform_utils.dart';
import '../common/relative_time_text.dart';
import '../common/smart_avatar.dart';
import '../common/topic_badges.dart';

/// 搜索结果帖子卡片 — 与话题列表卡片风格一致的紧凑横向布局
class SearchPostCard extends ConsumerWidget {
  final SearchPost post;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const SearchPostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onLongPress,
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: PlatformUtils.isDesktop ? onLongPress : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧：用户头像
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SmartAvatar(
                  imageUrl: post.getAvatarUrl().isNotEmpty
                      ? post.getAvatarUrl(size: 68)
                      : null,
                  radius: 17,
                  fallbackText: post.username,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              // 右侧：多行内容
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 第1行：标题 + 楼层号/AI标记
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _buildTopicTitle(post, topic, theme),
                        ),
                        if (post.isAiGenerated || post.postNumber > 1)
                          const SizedBox(width: 8),
                        if (post.isAiGenerated)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(Icons.auto_awesome, size: 14, color: theme.colorScheme.tertiary),
                          ),
                        if (post.postNumber > 1)
                          Container(
                            margin: const EdgeInsets.only(top: 2),
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
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),

                    // 摘要（紧凑显示，最多2行）
                    if (post.blurb.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _buildBlurb(post.blurb, theme),
                    ],

                    const SizedBox(height: 6),

                    // 第2行：分类+标签（左） + 点赞+时间（右），与 TopicCard 一致
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
                              if (topic != null)
                                ...topic.tags
                                    .take(3)
                                    .map((tag) => TagBadge(name: tag.name)),
                            ],
                          ),
                        ),
                        // 右侧：点赞 + 时间
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (post.likeCount > 0) ...[
                              _buildStat(
                                context,
                                Icons.favorite_border_rounded,
                                post.likeCount,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '·',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            RelativeTimeText(
                              dateTime: post.createdAt,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant
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
    );
  }

  Widget _buildTopicTitle(
      SearchPost post, SearchTopic? topic, ThemeData theme) {
    if (topic == null) return const SizedBox.shrink();

    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.3,
    );

    // 如果有高亮标题，使用高亮版本
    if (post.topicTitleHeadline != null &&
        post.topicTitleHeadline!.isNotEmpty) {
      return _buildHighlightedTitle(post.topicTitleHeadline!, topic, theme, titleStyle);
    }

    return Text.rich(
      TextSpan(
        style: titleStyle,
        children: [
          if (topic.closed)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (topic.archived)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.archive_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          TextSpan(text: topic.title),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 带状态图标的高亮标题
  Widget _buildHighlightedTitle(
      String headline, SearchTopic topic, ThemeData theme, TextStyle? style) {
    final spans = <InlineSpan>[];

    // 状态图标
    if (topic.closed) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
        ),
      ));
    }
    if (topic.archived) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(Icons.archive_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
        ),
      ));
    }

    // 解析高亮文本
    final regex = RegExp(r'<span class="search-highlight">(.*?)</span>');
    final matches = regex.allMatches(headline);

    if (matches.isEmpty) {
      final cleanText = headline.replaceAll(RegExp(r'<[^>]*>'), '');
      spans.add(TextSpan(text: cleanText));
    } else {
      int lastEnd = 0;
      for (final match in matches) {
        if (match.start > lastEnd) {
          spans.add(TextSpan(
            text: headline.substring(lastEnd, match.start).replaceAll(RegExp(r'<[^>]*>'), ''),
          ));
        }
        spans.add(TextSpan(
          text: match.group(1) ?? '',
          style: TextStyle(
            backgroundColor: theme.colorScheme.primaryContainer,
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ));
        lastEnd = match.end;
      }
      if (lastEnd < headline.length) {
        spans.add(TextSpan(
          text: headline.substring(lastEnd).replaceAll(RegExp(r'<[^>]*>'), ''),
        ));
      }
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildBlurb(String blurb, ThemeData theme) {
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );

    final regex = RegExp(r'<span class="search-highlight">(.*?)</span>');
    final matches = regex.allMatches(blurb);

    if (matches.isEmpty) {
      final cleanText = blurb.replaceAll(RegExp(r'<[^>]*>'), '');
      return Text(
        cleanText,
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        final beforeText = blurb
            .substring(lastEnd, match.start)
            .replaceAll(RegExp(r'<[^>]*>'), '');
        spans.add(TextSpan(text: beforeText));
      }
      spans.add(
        TextSpan(
          text: match.group(1) ?? '',
          style: TextStyle(
            backgroundColor: theme.colorScheme.primaryContainer,
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      lastEnd = match.end;
    }

    if (lastEnd < blurb.length) {
      final afterText = blurb
          .substring(lastEnd)
          .replaceAll(RegExp(r'<[^>]*>'), '');
      spans.add(TextSpan(text: afterText));
    }

    return RichText(
      text: TextSpan(style: style, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildStat(BuildContext context, IconData icon, int count) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          NumberUtils.formatCount(count),
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
