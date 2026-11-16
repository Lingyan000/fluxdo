import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/search_result.dart';
import '../../../models/topic.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../utils/link_launcher.dart';
import '../../../utils/number_utils.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../../widgets/user/user_card.dart';

/// 话题的参与者、点赞、阅读时长和链接汇总。
///
/// 常驻一行统计，高度不随数据量变化；参与者、点赞、链接的明细
/// 点开后在底部弹层中浏览。
class TopicStatistics extends StatefulWidget {
  const TopicStatistics({
    super.key,
    required this.detail,
    this.wordsPerMinute,
    this.onJumpToPost,
  });

  final TopicDetail detail;
  final num? wordsPerMinute;
  final void Function(int postNumber)? onJumpToPost;

  @override
  State<TopicStatistics> createState() => _TopicStatisticsState();
}

class _TopicStatisticsState extends State<TopicStatistics> {
  /// 头像堆叠最多显示的人数
  static const _maxStackedAvatars = 5;

  /// 高赞回复弹层最多列出的条数
  static const _maxLikedReplies = 10;

  /// 高赞回复请求缓存，话题或点赞数变化后失效
  Future<List<SearchPost>>? _mostLiked;
  Object? _mostLikedKey;

  Future<List<SearchPost>> _loadMostLiked({bool refresh = false}) {
    final detail = widget.detail;
    final key = (detail.id, detail.likeCount);
    if (!refresh && _mostLiked != null && _mostLikedKey == key) {
      return _mostLiked!;
    }
    _mostLikedKey = key;
    final future = _fetchMostLiked(detail.id);
    // 失败不缓存，下次打开重新请求
    future.catchError((_) {
      if (identical(_mostLiked, future)) _mostLiked = null;
      return const <SearchPost>[];
    });
    return _mostLiked = future;
  }

  static Future<List<SearchPost>> _fetchMostLiked(int topicId) async {
    final result = await DiscourseService().search(
      query: '" " topic:$topicId order:likes',
    );
    final posts =
        result.posts
            .where((post) => post.postNumber > 1 && post.likeCount > 0)
            .toList()
          ..sort((a, b) => b.likeCount.compareTo(a.likeCount));
    return posts.take(_maxLikedReplies).toList();
  }

  void _showParticipants() {
    final detail = widget.detail;
    final l10n = context.l10n;
    AppBottomSheet.show(
      context: context,
      title: l10n.topicDetail_participantsLabel,
      contentPadding: const EdgeInsets.only(bottom: 16),
      builder: (sheetContext) => ListView.builder(
        shrinkWrap: true,
        itemCount: detail.participants.length,
        itemBuilder: (_, index) {
          final participant = detail.participants[index];
          return _ParticipantTile(
            participant: participant,
            onTap: canShowUserCardPreview(context)
                ? () {
                    Navigator.of(sheetContext).pop();
                    _showUserCard(participant);
                  }
                : null,
          );
        },
      ),
    );
  }

  void _showUserCard(TopicUser participant) {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final detail = widget.detail;
    showUserCard(
      context: context,
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      username: participant.username,
      topicId: detail.id,
      topicTitle: detail.title,
      nameFallback: participant.name,
      avatarFallbackUrl: participant.getAvatarUrl(size: 144),
    );
  }

  void _showLinks() {
    final links = widget.detail.links;
    AppBottomSheet.show(
      context: context,
      title: context.l10n.topicDetail_linksLabel,
      contentPadding: const EdgeInsets.only(bottom: 16),
      builder: (sheetContext) => ListView.builder(
        shrinkWrap: true,
        itemCount: links.length,
        itemBuilder: (_, index) => _LinkTile(
          link: links[index],
          onTap: () {
            Navigator.of(sheetContext).pop();
            if (mounted) launchContentLink(context, links[index].url);
          },
        ),
      ),
    );
  }

  void _showMostLiked() {
    final onJumpToPost = widget.onJumpToPost;
    AppBottomSheet.show(
      context: context,
      title: context.l10n.topicDetail_mostLikedReplies,
      contentPadding: const EdgeInsets.only(bottom: 16),
      builder: (sheetContext) => _MostLikedReplies(
        load: _loadMostLiked,
        onTap: onJumpToPost == null
            ? null
            : (post) {
                Navigator.of(sheetContext).pop();
                onJumpToPost(post.postNumber);
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final detail = widget.detail;
    final participants = detail.participants;
    final count = math.max(detail.participantCount, participants.length);
    final speed = widget.wordsPerMinute;
    // 与 Discourse 统计区一致，较短话题不显示估算阅读时间。
    final minutes = speed != null && speed > 0
        ? math.max(detail.wordCount / speed, detail.postsCount / 15).ceil()
        : 0;
    // 至少两人时才叠头像，只有一人时头像没有信息量
    final showAvatars = participants.length >= 2;
    final stats = <Widget>[
      if (count > 0)
        _StatItem(
          leading: showAvatars
              ? _AvatarStack(
                  users: participants.take(_maxStackedAvatars).toList(),
                  ringColor: Theme.of(context).colorScheme.surface,
                )
              : null,
          icon: Symbols.group_rounded,
          value: NumberUtils.formatCount(count),
          label: l10n.topicDetail_participantsLabel,
          semanticLabel: l10n.topicDetail_participantCount(count),
          onTap: participants.isNotEmpty ? _showParticipants : null,
        ),
      if (detail.likeCount > 0)
        _StatItem(
          icon: Symbols.favorite_rounded,
          value: NumberUtils.formatCount(detail.likeCount),
          label: l10n.topicDetail_likesLabel,
          semanticLabel: l10n.topicDetail_totalLikes(detail.likeCount),
          // 只有首帖时没有可列出的回复
          onTap: detail.postsCount > 1 ? _showMostLiked : null,
        ),
      if (detail.links.isNotEmpty)
        _StatItem(
          icon: Symbols.link_rounded,
          value: NumberUtils.formatCount(detail.links.length),
          label: l10n.topicDetail_linksLabel,
          semanticLabel: l10n.topicDetail_linkCount(detail.links.length),
          onTap: _showLinks,
        ),
      if (minutes > 3)
        _StatItem(
          icon: Symbols.auto_stories_rounded,
          value: '$minutes',
          label: l10n.topicDetail_readMinutesLabel,
          semanticLabel: l10n.topicDetail_readMinutes(minutes),
        ),
    ];
    if (stats.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: stats,
      ),
    );
  }
}

/// 与话题元数据行（回复、浏览）同排版的统计项：图标 + 数值 + 浅色标签；
/// 可点击的项在末尾带一个小箭头。
class _StatItem extends StatelessWidget {
  const _StatItem({
    this.leading,
    required this.icon,
    required this.value,
    required this.label,
    required this.semanticLabel,
    this.onTap,
  });

  /// 替代图标显示的前导组件（参与者头像堆叠）
  final Widget? leading;
  final IconData icon;
  final String value;
  final String label;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading ?? Icon(icon, size: 14, color: color.withValues(alpha: 0.7)),
          SizedBox(width: leading != null ? 6 : 4),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color.withValues(alpha: 0.8),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color.withValues(alpha: 0.5),
            ),
          ),
          if (onTap != null)
            Icon(
              Symbols.chevron_right_rounded,
              size: 14,
              color: color.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      excludeSemantics: true,
      child: onTap == null
          ? content
          : InkWell(
              customBorder: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(8),
              ),
              onTap: onTap,
              child: content,
            ),
    );
  }
}

/// 参与者头像叠放，后一个压在前一个之上。
class _AvatarStack extends StatelessWidget {
  const _AvatarStack({required this.users, required this.ringColor});

  final List<TopicUser> users;
  final Color ringColor;

  static const double _radius = 9;
  static const double _ring = 1.5;
  static const double _step = 13;

  @override
  Widget build(BuildContext context) {
    const size = (_radius + _ring) * 2;
    return SizedBox(
      width: size + (users.length - 1) * _step,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < users.length; i++)
            PositionedDirectional(
              start: i * _step,
              child: SmartAvatar(
                imageUrl: users[i].getAvatarUrl(size: 48),
                radius: _radius + _ring,
                fallbackText: users[i].username,
                border: Border.all(color: ringColor, width: _ring),
              ),
            ),
        ],
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, this.onTap});

  final TopicUser participant;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasName = participant.displayName != participant.username;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: SmartAvatar(
        imageUrl: participant.getAvatarUrl(size: 96),
        radius: 18,
        fallbackText: participant.username,
      ),
      title: Text(
        participant.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: hasName
          ? Text(
              '@${participant.username}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: Text(
        context.l10n.topicDetail_postCountShort(participant.postCount),
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: onTap,
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link, required this.onTap});

  final TopicLink link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: const Icon(Symbols.link_rounded),
      title: Text(
        link.title.isEmpty ? link.url : link.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: link.title.isEmpty
          ? null
          : Text(link.url, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Tooltip(
        message: context.l10n.topicDetail_linkClicks(link.clicks),
        child: Text(
          NumberUtils.formatCount(link.clicks),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      onTap: onTap,
    );
  }
}

/// 获赞最多的回复列表（不含首帖）。
class _MostLikedReplies extends StatefulWidget {
  const _MostLikedReplies({required this.load, this.onTap});

  final Future<List<SearchPost>> Function({bool refresh}) load;
  final ValueChanged<SearchPost>? onTap;

  @override
  State<_MostLikedReplies> createState() => _MostLikedRepliesState();
}

class _MostLikedRepliesState extends State<_MostLikedReplies> {
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
          itemCount: posts.length,
          itemBuilder: (_, index) => _LikedReplyTile(
            post: posts[index],
            onTap: widget.onTap == null
                ? null
                : () => widget.onTap!(posts[index]),
          ),
        );
      },
    );
  }
}

class _LikedReplyTile extends StatelessWidget {
  const _LikedReplyTile({required this.post, this.onTap});

  final SearchPost post;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SmartAvatar(
                  imageUrl: post.getAvatarUrl(size: 48),
                  radius: 10,
                  fallbackText: post.username,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    post.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text('#${post.postNumber}', style: secondary),
                const SizedBox(width: 12),
                Icon(
                  Symbols.favorite_rounded,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(NumberUtils.formatCount(post.likeCount), style: secondary),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              post.blurb.replaceAll(RegExp(r'<[^>]*>'), ''),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
