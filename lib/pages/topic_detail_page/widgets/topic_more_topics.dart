import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../models/category.dart';
import '../../../models/topic.dart';
import '../../../providers/category_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/selected_topic_provider.dart';
import '../../../utils/number_utils.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/category_tags_line.dart';
import '../../../widgets/common/icon_glyph_span.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../category_topics_page.dart';
import '../topic_detail_page.dart';

/// 帖子流末尾的推荐区(对齐网页版 more-topics)
///
/// 两组数据来自话题详情响应:related = discourse-ai 语义相关的「相关话题」,
/// suggested = 服务端 TopicQuery 的「建议话题」。两组都有时用分页签切换
/// (对齐官方 tab 注册顺序,相关话题在前);只有一组时直接显示该组标题。
///
/// 顶部不画分隔线:上方最后一个帖子自带底部分隔线,再画一条就是双线。
///
/// 私信不接:官方私信下走的是 related_messages 字段(文案也不同),本次未实现。
class MoreTopicsSection extends ConsumerStatefulWidget {
  const MoreTopicsSection({super.key, required this.detail});

  final TopicDetail detail;

  @override
  ConsumerState<MoreTopicsSection> createState() => _MoreTopicsSectionState();
}

class _MoreTopicsSectionState extends ConsumerState<MoreTopicsSection> {
  /// null = 跟随数据自动选(相关话题优先);非 null = 用户手动切过
  bool? _preferRelated;

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      preferencesProvider.select((p) => p.showSuggestedTopics),
    );
    if (!enabled) return const SizedBox.shrink();

    final detail = widget.detail;
    if (detail.isPrivateMessage) return const SizedBox.shrink();

    final related = detail.relatedTopics;
    final suggested = detail.suggestedTopics;
    if (related.isEmpty && suggested.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final l10n = context.l10n;
    final hasTabs = related.isNotEmpty && suggested.isNotEmpty;
    final showRelated = related.isNotEmpty && (_preferRelated ?? true);
    final topics = showRelated ? related : suggested;
    final categoryMap = ref.watch(categoryMapProvider).value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: hasTabs
              ? Row(
                  children: [
                    _MoreTopicsTab(
                      label: l10n.topicDetail_relatedTopics,
                      icon: Symbols.auto_awesome_rounded,
                      selected: showRelated,
                      onTap: () => setState(() => _preferRelated = true),
                    ),
                    const SizedBox(width: 8),
                    _MoreTopicsTab(
                      label: l10n.topicDetail_suggestedTopics,
                      selected: !showRelated,
                      onTap: () => setState(() => _preferRelated = false),
                    ),
                  ],
                )
              : Row(
                  children: [
                    if (showRelated) ...[
                      Icon(
                        Symbols.auto_awesome_rounded,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      showRelated
                          ? l10n.topicDetail_relatedTopics
                          : l10n.topicDetail_suggestedTopics,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
        for (final topic in topics)
          _MoreTopicTile(
            topic: topic,
            category: categoryMap?[int.tryParse(topic.categoryId)],
            // 平行视界面板内=压当前栈(与正文内链同语义);
            // 全屏话题页=照旧全屏 push。
            onTap: () {
              if (EmbeddedStackScope.maybePushTopic(
                context,
                topicId: topic.id,
                initialTitle: topic.title,
              )) {
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TopicDetailPage(
                    topicId: topic.id,
                    initialTitle: topic.title,
                  ),
                ),
              );
            },
          ),
        _BrowseMoreLine(category: categoryMap?[detail.categoryId]),
      ],
    );
  }
}

/// 分页签 pill
class _MoreTopicsTab extends StatelessWidget {
  const _MoreTopicsTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Material(
      color: selected
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: selected ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 推荐条目该画哪几段
///
/// 推荐话题的字段随来源浮动:suggested 走 SuggestedTopicSerializer(excerpt
/// 只在置顶/站点开了 always_include_topic_excerpts 时才有),AI 的 related
/// 往往更薄。固定版式会留成片空白,所以逐段判断"服务端到底给没给"。
class MoreTopicTileDensity {
  const MoreTopicTileDensity({
    required this.creator,
    required this.showExcerpt,
    required this.showCategoryLine,
    required this.replyCount,
    required this.showTime,
  });

  /// 话题创建人(posters 首位,Discourse 约定 OP 在前);解不出则不画头像
  final TopicUser? creator;
  final bool showExcerpt;
  final bool showCategoryLine;

  /// 展示用回复数(reply_count 缺席时回落 posts_count - 1),0 = 不画
  final int replyCount;
  final bool showTime;

  bool get hasMetaLine => showCategoryLine || replyCount > 0 || showTime;
}

MoreTopicTileDensity resolveMoreTopicTileDensity(
  Topic topic, {
  Category? category,
}) {
  TopicUser? creator;
  for (final poster in topic.posters) {
    final user = poster.user;
    if (user != null && user.avatarTemplate.isNotEmpty) {
      creator = user;
      break;
    }
  }
  final replies = topic.replyCount > 0
      ? topic.replyCount
      : (topic.postsCount - 1).clamp(0, 999999);
  return MoreTopicTileDensity(
    creator: creator,
    showExcerpt: (topic.excerpt?.trim().isNotEmpty ?? false),
    showCategoryLine: category != null || topic.tags.isNotEmpty,
    replyCount: replies,
    showTime: (topic.lastPostedAt ?? topic.createdAt) != null,
  );
}

/// 按字段密度自适应的推荐条目:缺的段落不渲染也不占位,
/// 全缺时退化成纯标题单行(related_topics 最薄的形态)。
///
/// 头像只画话题创建人一个(与站内话题卡一致);不画赞/浏览数——站内
/// 话题卡在窄宽下也只显示回复数,推荐条目信息密度更低,堆满统计簇在
/// 手机宽度上只会显得杂乱。
class _MoreTopicTile extends StatelessWidget {
  const _MoreTopicTile({
    required this.topic,
    required this.category,
    required this.onTap,
  });

  final Topic topic;
  final Category? category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = resolveMoreTopicTileDensity(topic, category: category);
    final metaColor = theme.colorScheme.onSurfaceVariant;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          topic.title,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            height: 1.35,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (density.showExcerpt)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              topic.excerpt!.trim(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: metaColor.withValues(alpha: 0.85),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (density.hasMetaLine)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _buildMetaLine(context, density, metaColor),
          ),
      ],
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: density.creator == null
            ? content
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶对齐标题首行:标题 bodyMedium 首行高约 19px,
                  // 32px 头像下沉会显得飘,略加 1px 视觉对齐
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: SmartAvatar(
                      imageUrl: density.creator!.getAvatarUrl(size: 64),
                      radius: 16,
                      fallbackText: density.creator!.displayName,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: content),
                ],
              ),
      ),
    );
  }

  /// meta 行:分类 + 标签靠左(超宽省略),回复数 + 时间固定靠右,
  /// 左右锚定避免逐项挤在一起的粘连感
  Widget _buildMetaLine(
    BuildContext context,
    MoreTopicTileDensity density,
    Color metaColor,
  ) {
    final theme = Theme.of(context);
    final rightStyle = theme.textTheme.labelSmall?.copyWith(color: metaColor);

    final rightSpans = <InlineSpan>[];
    if (density.replyCount > 0) {
      rightSpans.add(iconGlyphSpan(
        context,
        Symbols.chat_bubble_rounded,
        size: 12,
        color: metaColor,
        gap: 3,
        textStyle: rightStyle,
      ));
      rightSpans.add(TextSpan(
        text: NumberUtils.formatCount(density.replyCount),
        style: rightStyle,
      ));
    }
    if (density.showTime) {
      if (rightSpans.isNotEmpty) {
        rightSpans.add(TextSpan(text: ' · ', style: rightStyle));
      }
      rightSpans.add(TextSpan(
        text: TimeUtils.formatRelativeTime(
          topic.lastPostedAt ?? topic.createdAt,
        ),
        style: rightStyle,
      ));
    }

    return Row(
      children: [
        Expanded(
          child: density.showCategoryLine
              ? CategoryTagsLine(
                  category: category,
                  tags: topic.tags,
                  metaColor: metaColor,
                )
              : const SizedBox.shrink(),
        ),
        if (rightSpans.isNotEmpty) ...[
          const SizedBox(width: 12),
          Text.rich(TextSpan(children: rightSpans)),
        ],
      ],
    );
  }
}

/// 「浏览更多」一行(对齐官方 browse-more)
///
/// 官方那行还含「最新话题」链接,App 里「最新」是首页 tab,从详情再 push
/// 一个列表页不自然,故只保留分类入口;话题没有分类时整行不画。
class _BrowseMoreLine extends StatelessWidget {
  const _BrowseMoreLine({required this.category});

  final Category? category;

  @override
  Widget build(BuildContext context) {
    final category = this.category;
    if (category == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CategoryTopicsPage(category: category),
            ),
          ),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              context.l10n.topicDetail_browseMoreInCategory(category.name),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
