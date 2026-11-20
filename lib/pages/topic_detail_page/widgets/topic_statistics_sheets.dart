import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/search_result.dart';
import '../../../models/topic.dart';
import '../../../utils/number_utils.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../widgets/common/inline_icon_span.dart';
import '../../../widgets/common/smart_avatar.dart';

/// 话题统计区各弹层的列表内容：参与者、链接、获赞最多的回复。
///
/// 条目统一用 [SegmentedCardItem]，跟随外观里的分段 / 描边 / 平铺设置。

/// 分段模式下条目之间的间距
const double _itemGap = 3;

/// 列表与弹层左右边缘的距离
const EdgeInsets _listPadding = EdgeInsets.symmetric(horizontal: 16);

class TopicParticipantList extends StatelessWidget {
  const TopicParticipantList({
    super.key,
    required this.participants,
    this.onTap,
  });

  final List<TopicUser> participants;
  final ValueChanged<TopicUser>? onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      padding: _listPadding,
      itemCount: participants.length,
      itemBuilder: (_, index) {
        final participant = participants[index];
        return _ListItem(
          index: index,
          count: participants.length,
          onTap: onTap == null ? null : () => onTap!(participant),
          child: _ParticipantRow(participant: participant),
        );
      },
    );
  }
}

class TopicLinkList extends StatelessWidget {
  const TopicLinkList({super.key, required this.links, required this.onTap});

  final List<TopicLink> links;
  final ValueChanged<TopicLink> onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      padding: _listPadding,
      itemCount: links.length,
      itemBuilder: (_, index) => _ListItem(
        index: index,
        count: links.length,
        onTap: () => onTap(links[index]),
        child: _LinkRow(link: links[index]),
      ),
    );
  }
}

/// 获赞最多的回复列表（不含首帖）。
class TopicMostLikedReplies extends StatefulWidget {
  const TopicMostLikedReplies({super.key, required this.load, this.onTap});

  final Future<List<SearchPost>> Function({bool refresh}) load;
  final ValueChanged<SearchPost>? onTap;

  @override
  State<TopicMostLikedReplies> createState() => _TopicMostLikedRepliesState();
}

class _TopicMostLikedRepliesState extends State<TopicMostLikedReplies> {
  late Future<List<SearchPost>> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<List<SearchPost>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 160,
            child: Center(child: LoadingSpinner()),
          );
        }
        if (snapshot.hasError) {
          return SizedBox(
            height: 160,
            child: Center(
              child: TextButton.icon(
                icon: const Icon(Symbols.refresh_rounded),
                label: Text(l10n.common_loadFailedTapRetry),
                onPressed: () =>
                    setState(() => _future = widget.load(refresh: true)),
              ),
            ),
          );
        }
        final posts = snapshot.data ?? const <SearchPost>[];
        if (posts.isEmpty) {
          return AppEmptyState(
            icon: const Icon(Symbols.favorite_rounded),
            title: l10n.topicDetail_noLikedReplies,
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          padding: _listPadding,
          itemCount: posts.length,
          itemBuilder: (_, index) => _ListItem(
            index: index,
            count: posts.length,
            onTap: widget.onTap == null
                ? null
                : () => widget.onTap!(posts[index]),
            child: _LikedReplyBody(post: posts[index]),
          ),
        );
      },
    );
  }
}

/// 列表条目外壳：分段卡片 + 与轮廓同形的按压反馈。
class _ListItem extends StatelessWidget {
  const _ListItem({
    required this.index,
    required this.count,
    required this.onTap,
    required this.child,
  });

  final int index;
  final int count;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SegmentedCardItem(
      index: index,
      count: count,
      gap: SegmentedCardItem.gapOf(context, _itemGap),
      child: InkWell(
        borderRadius: SegmentedCardItem.borderRadiusOf(
          context,
          index: index,
          count: count,
        ),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: child,
        ),
      ),
    );
  }
}

/// 右侧的计数胶囊：可选图标 + 数值 + 可选单位，同段排版共用基线。
class _CountPill extends StatelessWidget {
  const _CountPill({this.icon, required this.value, this.unit});

  final IconData? icon;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final color = colorScheme.onSurfaceVariant;
    final textStyle = theme.textTheme.labelMedium;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colorScheme.surfaceContainerHighest,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(10),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text.rich(
          TextSpan(
            children: [
              if (icon case final icon?) ...[
                inlineIconSpan(
                  icon,
                  size: 13,
                  fill: 1,
                  color: color,
                  textStyle: textStyle ?? const TextStyle(),
                ),
                const WidgetSpan(child: SizedBox(width: 3)),
              ],
              TextSpan(
                text: value,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (unit != null) ...[
                const WidgetSpan(child: SizedBox(width: 2)),
                TextSpan(text: unit),
              ],
            ],
          ),
          style: textStyle?.copyWith(color: color),
        ),
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({required this.participant});

  final TopicUser participant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasName = participant.displayName != participant.username;
    return Row(
      children: [
        SmartAvatar(
          imageUrl: participant.getAvatarUrl(size: 96),
          radius: 18,
          fallbackText: participant.username,
          backgroundColor: colorScheme.secondaryContainer,
          foregroundColor: colorScheme.onSecondaryContainer,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                participant.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (hasName)
                Text(
                  '@${participant.username}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _CountPill(
          value: NumberUtils.formatCount(participant.postCount),
          unit: context.l10n.topicDetail_postUnit(participant.postCount),
        ),
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.link});

  final TopicLink link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final icon = link.attachment
        ? Symbols.attach_file_rounded
        : link.internal
        ? Symbols.forum_rounded
        : Symbols.public_rounded;
    final meta = [
      if (link.domain.isNotEmpty) link.domain,
      if (link.clicks > 0) context.l10n.topicDetail_linkClicks(link.clicks),
    ].join(' · ');
    return Row(
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(
            color: colorScheme.surfaceContainerHighest,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(10),
            ),
          ),
          child: SizedBox.square(
            dimension: 36,
            child: Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 站内话题标题可能带 :emoji: 短码
              EmojiText(
                link.title.isEmpty ? link.url : link.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              if (meta.isNotEmpty)
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LikedReplyBody extends StatelessWidget {
  const _LikedReplyBody({required this.post});

  final SearchPost post;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SmartAvatar(
              imageUrl: post.getAvatarUrl(size: 48),
              radius: 12,
              fallbackText: post.username,
              backgroundColor: colorScheme.secondaryContainer,
              foregroundColor: colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              // 用户名与楼层号同段排版共用基线
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: post.username,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const WidgetSpan(child: SizedBox(width: 6)),
                    TextSpan(
                      text: '#${post.postNumber}',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 12),
            _CountPill(
              icon: Symbols.favorite_rounded,
              value: NumberUtils.formatCount(post.likeCount),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 摘要是 HTML 片段：解析后取纯文本（去标签、解实体），短码转 emoji
        EmojiText(
          html_parser.parseFragment(post.blurb).text ?? '',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
