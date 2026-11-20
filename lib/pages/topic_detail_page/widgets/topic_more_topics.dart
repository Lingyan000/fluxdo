import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../models/category.dart';
import '../../../models/topic.dart';
import '../../../providers/category_provider.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/selected_topic_provider.dart';
import '../../../utils/number_utils.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/category_tags_line.dart';
import '../../../widgets/common/inline_icon_span.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../category_topics_page.dart';
import '../../search_page.dart';
import '../topic_detail_page.dart';
import '../../../widgets/common/emoji_text.dart';

/// 帖子流末尾的推荐区(对齐网页版 more-topics)
///
/// 两组数据来自话题详情响应:related = discourse-ai 语义相关的「相关话题」,
/// suggested = 服务端 TopicQuery 的「建议话题」。两组都有时用分页签切换
/// (对齐官方 tab 注册顺序,相关话题在前);只有一组时直接显示该组标题。
///
/// 顶部不画分隔线:上方最后一个帖子自带底部分隔线,再画一条就是双线。
///
/// 私信只展示服务端返回的相关消息。
class MoreTopicsSection extends ConsumerStatefulWidget {
  const MoreTopicsSection({
    super.key,
    required this.detail,
    this.relatedMessages,
  });

  final TopicDetail detail;

  /// 树形末页可单独返回相关消息。字段缺失时沿用详情响应。
  final List<Topic>? relatedMessages;

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
    final isPrivateMessage = detail.isPrivateMessage;
    final related = isPrivateMessage
        ? widget.relatedMessages ?? detail.relatedMessages ?? const <Topic>[]
        : detail.relatedTopics;
    final suggested = isPrivateMessage
        ? const <Topic>[]
        : detail.suggestedTopics;
    if (related.isEmpty && suggested.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final l10n = context.l10n;
    final hasTabs = related.isNotEmpty && suggested.isNotEmpty;
    final showRelated =
        related.isNotEmpty && (!hasTabs || (_preferRelated ?? true));
    final topics = showRelated ? related : suggested;
    final relatedLabel = isPrivateMessage
        ? l10n.topicDetail_relatedMessages
        : l10n.topicDetail_relatedTopics;
    final categoryMap = isPrivateMessage
        ? null
        : ref.watch(categoryMapProvider).value;
    final category = categoryMap?[detail.categoryId];

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
                    if (showRelated && !isPrivateMessage) ...[
                      Icon(
                        Symbols.auto_awesome_rounded,
                        size: 16,
                        color: context.emphasis.accent,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Semantics(
                        header: true,
                        child: Text(
                          showRelated
                              ? relatedLabel
                              : l10n.topicDetail_suggestedTopics,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        for (final topic in topics)
          _MoreTopicTile(
            topic: topic,
            category: categoryMap?[int.tryParse(topic.categoryId)],
            totalReplies: isPrivateMessage && topic.postsCount > 0
                ? topic.postsCount - 1
                : null,
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
                InteractionPageRoute(
                  builder: (_) => TopicDetailPage(
                    topicId: topic.id,
                    initialTitle: topic.title,
                  ),
                ),
              );
            },
          ),
        if (isPrivateMessage &&
            related.length >= 5 &&
            detail.allowedGroups.isEmpty &&
            detail.allowedUsers.length == 2)
          _AllDirectMessagesLink(users: detail.allowedUsers),
        if (category != null)
          _BrowseMoreLine(
            label: l10n.topicDetail_browseMoreInCategory(category.name),
            onTap: () => Navigator.of(context).push(
              InteractionPageRoute(
                builder: (_) => CategoryTopicsPage(category: category),
              ),
            ),
          ),
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
      shape: RoundedSuperellipseBorder(borderRadius: context.shapes.borderRadius(16)),
      child: InkWell(
        onTap: selected ? null : onTap,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(16),
        ),
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

  /// 已知的私信回复数包含零。精简话题条目可以省略此项。
  final int? replyCount;
  final bool showTime;

  bool get hasMetaLine => showCategoryLine || replyCount != null || showTime;
}

MoreTopicTileDensity resolveMoreTopicTileDensity(
  Topic topic, {
  Category? category,
  int? totalReplies,
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
    replyCount: totalReplies ?? (replies > 0 ? replies : null),
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
    this.totalReplies,
    required this.onTap,
  });

  final Topic topic;
  final Category? category;
  final int? totalReplies;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = resolveMoreTopicTileDensity(
      topic,
      category: category,
      totalReplies: totalReplies,
    );
    final metaColor = theme.colorScheme.onSurfaceVariant;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EmojiText(
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

  /// 有分类或标签时分列展示，否则把统计直接排在标题下方。
  Widget _buildMetaLine(
    BuildContext context,
    MoreTopicTileDensity density,
    Color metaColor,
  ) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: metaColor,
    );
    final stats = Text.rich(
      TextSpan(
        children: [
          if (density.replyCount case final count?) ...[
            inlineIconSpan(
              Symbols.chat_bubble_rounded,
              size: 12,
              color: metaColor,
              textStyle: style ?? const TextStyle(),
            ),
            const WidgetSpan(child: SizedBox(width: 3)),
            TextSpan(text: NumberUtils.formatCount(count)),
            if (density.showTime) const TextSpan(text: ' · '),
          ],
          if (density.showTime)
            TextSpan(
              text: TimeUtils.formatRelativeTime(
                topic.lastPostedAt ?? topic.createdAt,
              ),
            ),
        ],
      ),
      style: style,
    );
    if (!density.showCategoryLine) return stats;

    return Row(
      children: [
        Expanded(
          child: CategoryTagsLine(
            category: category,
            tags: topic.tags,
            metaColor: metaColor,
          ),
        ),
        if (density.replyCount != null || density.showTime) ...[
          const SizedBox(width: 12),
          stats,
        ],
      ],
    );
  }
}

/// 只有当前用户参与的双人私信才能跳到与对方的直接消息搜索。
class _AllDirectMessagesLink extends ConsumerWidget {
  const _AllDirectMessagesLink({required this.users});

  final List<TopicUser> users;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myId = ref.watch(currentUserProvider.select((user) => user.value?.id));
    if (!users.any((user) => user.id == myId)) return const SizedBox.shrink();
    final other = users.where((user) => user.id != myId).firstOrNull;
    if (other == null || other.username.isEmpty) return const SizedBox.shrink();
    return _BrowseMoreLine(
      label: context.l10n.topicDetail_allMessagesFrom(other.username),
      onTap: () => Navigator.of(context).push(
        InteractionPageRoute(
          builder: (_) => SearchPage(
            initialQuery: '@${other.username} in:personal-direct',
          ),
        ),
      ),
    );
  }
}

class _BrowseMoreLine extends StatelessWidget {
  const _BrowseMoreLine({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: InkWell(
          onTap: onTap,
          customBorder: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              label,
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
