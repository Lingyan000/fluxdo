import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../providers/category_provider.dart';
import '../../utils/number_utils.dart';
import '../../utils/platform_utils.dart';
import '../../utils/responsive.dart';
import '../common/category_tags_line.dart';
import '../common/relative_time_text.dart';
import '../common/smart_avatar.dart';
import '../topic/painted_topic_card.dart';
import '../topic/topic_card_layout.dart';
import '../topic/topic_item_builder.dart' show kUsePaintedTopicCard;

/// 搜索结果帖子卡片 — 与话题卡片同款的标题置顶布局:
/// 1. 标题(满宽,最多两行,支持搜索高亮)+ 右侧 AI标记/#楼层 槽位
///    (可选)摘要 blurb(支持搜索高亮)
/// 2. 头像(32px,跨两行)+ 用户名 ······ 时间
/// 3.                     ▪分类 + 标签 ······ 统计
/// 无分类无标签时退化为单行署名:用户名 ······ 统计 + 时间
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

    // ── 自绘路径(默认):排版全局缓存 + 单渲染对象,与话题卡同引擎
    // (kUsePaintedTopicCard 总开关一键回退 widget 版)
    if (kUsePaintedTopicCard) {
      final viewportWidth = MediaQuery.sizeOf(context).width - 32; // 页边 16×2
      final isMobile = Responsive.isMobile(context);
      final cardWidth = isMobile
          ? viewportWidth
          : (viewportWidth > Breakpoints.maxContentWidth
              ? Breakpoints.maxContentWidth
              : viewportWidth);
      final layout = TopicCardLayout.obtainSearch(
        identity: 'search:${post.id}',
        post: post,
        width: cardWidth,
        theme: theme,
        category: category,
        statsAvailableWidth: cardWidth - 64,
      );
      Widget card = PaintedTopicCard(
        layout: layout,
        onTap: onTap,
        onLongPress: onLongPress,
      );
      if (!isMobile) {
        card = Center(child: SizedBox(width: cardWidth, child: card));
      }
      return card;
    }

    // ── widget 版(回退保险丝)────────────────────────────────

    // 搜索结果无已读态,统一用话题卡片的强调态样式
    final titleColor = theme.colorScheme.onSurface;
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: titleColor,
    );
    final metaColor = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: PlatformUtils.isDesktop ? onLongPress : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第1行：标题满宽置顶 + 右侧 AI标记/#楼层 槽位
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildTopicTitle(post, topic, theme, titleStyle),
                  ),
                  if (post.isAiGenerated || post.postNumber > 1)
                    const SizedBox(width: 6),
                  if (post.isAiGenerated)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Symbols.auto_awesome_rounded,
                        size: 14,
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  if (post.postNumber > 1)
                    Container(
                      margin: const EdgeInsets.only(top: 1, left: 4),
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

              // 摘要(支持搜索高亮,最多2行):Gmail snippet 位
              if (post.blurb.isNotEmpty) ...[
                const SizedBox(height: 4),
                _buildBlurb(post.blurb, theme),
              ],
              const SizedBox(height: 8),

              // 第2+3行：头像跨两行,右侧上下两行小字;
              // 无分类无标签时退化为单行署名,头像居中
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SmartAvatar(
                    imageUrl: post.getAvatarUrl().isNotEmpty
                        ? post.getAvatarUrl(size: 64)
                        : null,
                    radius: 16,
                    fallbackText: post.username,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final stats = _buildStatsCluster(
                          context,
                          topic,
                          constraints.maxWidth,
                        );
                        final hasCatTags =
                            category != null ||
                            (topic != null && topic.tags.isNotEmpty);
                        final catTags = hasCatTags
                            ? CategoryTagsLine(
                                category: category,
                                tags: topic?.tags ?? const [],
                                metaColor: metaColor,
                              )
                            : null;
                        final timeText = RelativeTimeText(
                          dateTime: post.createdAt,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: metaColor,
                          ),
                        );
                        final authorName = Text(
                          post.username,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.85,
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        );

                        // 单行署名:用户名 ······ 统计 + 时间
                        if (catTags == null) {
                          return Row(
                            children: [
                              Expanded(child: authorName),
                              const SizedBox(width: 8),
                              if (stats != null) ...[
                                stats,
                                const SizedBox(width: 10),
                              ],
                              timeText,
                            ],
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 第2行：用户名 ······ 时间
                            Row(
                              children: [
                                Expanded(child: authorName),
                                const SizedBox(width: 8),
                                timeText,
                              ],
                            ),
                            const SizedBox(height: 2),
                            // 第3行：▪分类 + 标签 ······ 统计
                            Row(
                              children: [
                                Expanded(child: catTags),
                                if (stats != null) ...[
                                  const SizedBox(width: 8),
                                  stats,
                                ],
                              ],
                            ),
                          ],
                        );
                      },
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

  Widget _buildTopicTitle(
    SearchPost post,
    SearchTopic? topic,
    ThemeData theme,
    TextStyle? titleStyle,
  ) {
    if (topic == null) return const SizedBox.shrink();

    // 如果有高亮标题，使用高亮版本
    if (post.topicTitleHeadline != null &&
        post.topicTitleHeadline!.isNotEmpty) {
      return _buildHighlightedTitle(
        post.topicTitleHeadline!,
        topic,
        theme,
        titleStyle,
      );
    }

    if (!topic.closed && !topic.archived) {
      return Text(
        topic.title,
        style: titleStyle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Text.rich(
      TextSpan(
        style: titleStyle,
        children: [
          ..._buildTitleStateIcons(topic, theme),
          TextSpan(text: topic.title),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 标题状态图标:锁定/归档
  List<InlineSpan> _buildTitleStateIcons(SearchTopic topic, ThemeData theme) {
    return [
      if (topic.closed)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(
              Symbols.lock_rounded,
              size: 15,
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
              Symbols.archive_rounded,
              size: 15,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }

  /// 带状态图标的高亮标题
  Widget _buildHighlightedTitle(
    String headline,
    SearchTopic topic,
    ThemeData theme,
    TextStyle? style,
  ) {
    final spans = <InlineSpan>[..._buildTitleStateIcons(topic, theme)];

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
          spans.add(
            TextSpan(
              text: headline
                  .substring(lastEnd, match.start)
                  .replaceAll(RegExp(r'<[^>]*>'), ''),
            ),
          );
        }
        spans.add(
          TextSpan(
            text: match.group(1) ?? '',
            style: TextStyle(
              backgroundColor: theme.colorScheme.primaryContainer,
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
        lastEnd = match.end;
      }
      if (lastEnd < headline.length) {
        spans.add(
          TextSpan(
            text: headline
                .substring(lastEnd)
                .replaceAll(RegExp(r'<[^>]*>'), ''),
          ),
        );
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
            fontWeight: FontWeight.w500,
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

  /// 第3行右侧统计簇:❤帖子获赞 + 💬话题回复,宽度富余时加 👁浏览。
  /// 与话题卡片同款样式;无内容返回 null 不占位
  Widget? _buildStatsCluster(
    BuildContext context,
    SearchTopic? topic,
    double availableWidth,
  ) {
    final replies = topic != null ? (topic.postsCount - 1).clamp(0, 999999) : 0;
    final showViews = availableWidth >= 460 && topic != null && topic.views > 0;

    final children = <Widget>[
      if (showViews)
        _buildStat(context, Symbols.visibility_rounded, topic.views),
      if (post.likeCount > 0)
        _buildStat(context, Symbols.favorite_border_rounded, post.likeCount),
      if (replies > 0)
        _buildStat(context, Symbols.chat_bubble_rounded, replies),
    ];
    if (children.isEmpty) return null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          children[i],
        ],
      ],
    );
  }

  Widget _buildStat(BuildContext context, IconData icon, int count) {
    final theme = Theme.of(context);
    // 默认灰度调柔,与话题卡片统计簇一致
    final color = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          NumberUtils.formatCount(count),
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
