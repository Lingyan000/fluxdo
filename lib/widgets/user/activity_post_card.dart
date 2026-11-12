import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../models/category.dart';
import '../../models/topic.dart';
import '../../providers/selected_topic_provider.dart';
import '../../theme/theme_style.dart';
import '../../utils/category_navigation.dart';
import '../../utils/color_utils.dart';
import '../../utils/emoji_shortcodes.dart';
import '../../utils/number_utils.dart';
import '../../l10n/s.dart';
import '../common/category_tags_line.dart';
import '../common/emoji_text.dart';
import '../common/relative_time_text.dart';
import '../common/smart_avatar.dart';
import '../content/collapsed_html_content.dart';
import '../post/post_item/widgets/reaction_emoji.dart';
import '../topic/topic_card.dart' show TopicCardInteractiveSurface;

/// 资料页与用户组共用活动卡；作者、动作与所引用的帖子分别呈现。
class ActivityPostCard extends StatelessWidget {
  const ActivityPostCard({
    super.key,
    required this.position,
    required this.title,
    required this.actionLabel,
    required this.onTap,
    this.onLongPress,
    this.onPreviewIntent,
    this.actionIcon,
    this.author,
    this.actionActor,
    this.occurredAt,
    this.postNumber,
    this.excerpt,
    this.quoteExcerpt = false,
    this.accepted = false,
    this.reactionId,
    this.boostNote,
    this.categoryId,
    this.categories = const {},
    this.footer,
  });

  final ({int index, int count}) position;
  final String title;
  final String actionLabel;
  final IconData? actionIcon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPreviewIntent;
  final Widget? footer;
  final TopicUser? author;
  final TopicUser? actionActor;
  final DateTime? occurredAt;
  final int? postNumber;
  final String? excerpt;
  final bool quoteExcerpt;
  final bool accepted;
  final String? reactionId;
  final Widget? boostNote;
  final int? categoryId;
  final Map<int, Category> categories;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: secondary,
      height: 1.4,
    );
    final category = categories[categoryId];
    final parent = categories[category?.parentCategoryId];
    final radius = SegmentedCardItem.borderRadiusOf(
      context,
      index: position.index,
      count: position.count,
    );
    final body = excerpt?.trim();
    final reaction = normalizeEmojiShortcodeName(reactionId ?? '');
    final metadata = Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (actionIcon != null)
              Icon(
                actionIcon,
                size: 15,
                color: accepted ? context.emphasis.selected : secondary,
              ),
            if (actionActor != null)
              _ActivityLink(
                minimumSize: Size.zero,
                onTap: () => EmbeddedStackScope.openProfile(
                  context,
                  actionActor!.username,
                ),
                child: Text(
                  '@${actionActor!.username}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: metaStyle,
                ),
              ),
            Text(actionLabel, style: metaStyle),
          ],
        ),
        if (postNumber != null && postNumber! > 0)
          Text('#$postNumber', style: metaStyle),
        if (occurredAt != null)
          RelativeTimeText(dateTime: occurredAt, style: metaStyle),
      ],
    );
    return SegmentedCardItem(
      index: position.index,
      count: position.count,
      gap: 4,
      color: PageBackgroundScope.contentColor(
        context,
        theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
      ),
      child: TopicCardInteractiveSurface(
        onTap: onTap,
        onLongPress: onLongPress,
        onPreviewIntent: onPreviewIntent,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (author != null) ...[
                _ActivityAuthor(author: author!),
                const SizedBox(height: 4),
              ],
              metadata,
              if (title.isNotEmpty) ...[
                const SizedBox(height: 10),
                EmojiText(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ],
              if (reaction.isNotEmpty) ...[
                const SizedBox(height: 10),
                Semantics(
                  image: true,
                  label: ':$reaction:',
                  child: ReactionEmoji(reactionId: reaction, size: 28),
                ),
              ],
              if (body != null && body.isNotEmpty) ...[
                const SizedBox(height: 10),
                _ActivityExcerpt(html: body, quoted: quoteExcerpt),
              ],
              if (boostNote != null) ...[
                const SizedBox(height: 10),
                boostNote!,
              ],
              if (category != null) ...[
                const SizedBox(height: 4),
                _ActivityLink(
                  onTap: () => openCategoryPage(
                    context,
                    category.id,
                    useWorkspace: false,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Symbols.circle,
                        size: 8,
                        color: ColorUtils.category(category.color, theme),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          [
                            if (parent != null) parent.name,
                            category.name,
                          ].join(' › '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (footer != null) ...[const SizedBox(height: 4), footer!],
            ],
          ),
        ),
      ),
    );
  }
}

/// 话题活动沿用作者、动作、标题、分类的阅读顺序，讨论统计放在底部。
class ActivityTopicCard extends StatelessWidget {
  const ActivityTopicCard({
    super.key,
    required this.topic,
    required this.position,
    required this.onTap,
    this.categories = const {},
    this.onLongPress,
    this.onPreviewIntent,
  });

  final Topic topic;
  final ({int index, int count}) position;
  final Map<int, Category> categories;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPreviewIntent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: color,
      height: 1.4,
    );
    final replies = math.max(0, topic.postsCount - 1);
    return ActivityPostCard(
      position: position,
      author: topic.posters.firstOrNull?.user,
      title: topic.title,
      actionLabel: context.l10n.userProfile_tabVotes,
      actionIcon: Symbols.how_to_vote_rounded,
      excerpt: topic.excerpt,
      categoryId: int.tryParse(topic.categoryId),
      categories: categories,
      onTap: onTap,
      onLongPress: onLongPress,
      onPreviewIntent: onPreviewIntent,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (topic.tags.isNotEmpty) ...[
            CategoryTagsLine(tags: topic.tags, metaColor: color),
            const SizedBox(height: 10),
          ],
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (topic.closed)
                Icon(Symbols.lock_rounded, size: 16, color: color),
              if (topic.hasAcceptedAnswer || topic.canHaveAnswer)
                Icon(
                  topic.hasAcceptedAnswer
                      ? Symbols.check_box_rounded
                      : Symbols.check_box_outline_blank_rounded,
                  size: 16,
                  color: topic.hasAcceptedAnswer
                      ? context.emphasis.selected
                      : color,
                ),
              for (final (icon, count, label) in [
                (
                  Symbols.chat_bubble_rounded,
                  replies,
                  context.l10n.topic_replyCount(replies),
                ),
                (
                  Symbols.visibility_rounded,
                  topic.views,
                  context.l10n.topic_viewCount('${topic.views}'),
                ),
                (
                  Symbols.favorite_border_rounded,
                  topic.likeCount,
                  context.l10n.topic_likeCount('${topic.likeCount}'),
                ),
              ])
                Tooltip(
                  message: label,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 14, color: color),
                      const SizedBox(width: 4),
                      Text(NumberUtils.formatCount(count), style: style),
                    ],
                  ),
                ),
              if (topic.unread > 0)
                Tooltip(
                  message: context.l10n.topic_filterUnread,
                  child: Badge(label: Text('${topic.unread}')),
                ),
              if (topic.lastPostedAt != null)
                RelativeTimeText(
                  dateTime: topic.lastPostedAt,
                  style: style,
                  displayStyle: TimeDisplayStyle.prefixed,
                  prefix: context.l10n.topic_lastReply,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActivityAuthor extends StatelessWidget {
  const _ActivityAuthor({required this.author});
  final TopicUser author;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: _ActivityLink(
        onTap: () => EmbeddedStackScope.openProfile(context, author.username),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SmartAvatar(
              imageUrl: author.avatarTemplate.isEmpty
                  ? ''
                  : author.getAvatarUrl(size: 80),
              radius: 16,
              fallbackText: author.username,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Wrap(
                spacing: 8,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    author.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (author.displayName != author.username)
                    Text(
                      '@${author.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内容链接按实际内容收拢点击范围，焦点仍可由键盘清晰定位。
class _ActivityLink extends StatelessWidget {
  const _ActivityLink({
    required this.onTap,
    required this.child,
    this.minimumSize = const Size(44, 44),
  });

  final VoidCallback onTap;
  final Widget child;
  final Size minimumSize;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: context.shapes.borderRadius(4),
    splashFactory: NoSplash.splashFactory,
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? Theme.of(context).focusColor
          : Colors.transparent,
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minimumSize.width,
        minHeight: minimumSize.height,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Align(widthFactor: 1, heightFactor: 1, child: child),
      ),
    ),
  );
}

class _ActivityExcerpt extends StatelessWidget {
  const _ActivityExcerpt({required this.html, required this.quoted});
  final String html;
  final bool quoted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = CollapsedHtmlContent(
      html: html,
      maxLines: 4,
      textStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
    );
    if (!quoted) return text;
    final bar = context.themeStyle.quote == QuoteStyle.bar;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bar
            ? null
            : PageBackgroundScope.contentColor(
                context,
                theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
              ),
        borderRadius: bar ? null : context.shapes.borderRadius(10),
        border: bar
            ? Border(
                left: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 3,
                ),
              )
            : null,
      ),
      child: text,
    );
  }
}

/// Boost 留言气泡随内容收拢，长留言在卡片内换行。
class ActivityBoostNote extends StatelessWidget {
  const ActivityBoostNote({super.key, required this.actor, required this.text});
  final TopicUser actor;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: PageBackgroundScope.contentColor(
            context,
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          ),
          borderRadius: context.shapes.borderRadius(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Tooltip(
              message: actor.displayName,
              child: _ActivityLink(
                onTap: () =>
                    EmbeddedStackScope.openProfile(context, actor.username),
                child: SmartAvatar(
                  imageUrl: actor.avatarTemplate.isEmpty
                      ? ''
                      : actor.getAvatarUrl(size: 48),
                  radius: 12,
                  fallbackText: actor.username,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(0, 10, 12, 10),
                child: EmojiText(
                  text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
