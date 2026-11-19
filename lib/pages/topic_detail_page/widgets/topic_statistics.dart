import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/search_result.dart';
import '../../../models/topic.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../utils/link_launcher.dart';
import '../../../utils/number_utils.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/inline_icon_span.dart';
import '../../../widgets/user/user_card.dart';
import 'topic_participant_avatars.dart';
import 'topic_statistics_sheets.dart';

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
      builder: (sheetContext) => TopicParticipantList(
        participants: detail.participants,
        onTap: canShowUserCardPreview(context)
            ? (participant) {
                Navigator.of(sheetContext).pop();
                _showUserCard(participant);
              }
            : null,
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
      builder: (sheetContext) => TopicLinkList(
        links: links,
        onTap: (link) {
          Navigator.of(sheetContext).pop();
          if (mounted) launchContentLink(context, link.url);
        },
      ),
    );
  }

  void _showMostLiked() {
    final onJumpToPost = widget.onJumpToPost;
    AppBottomSheet.show(
      context: context,
      title: context.l10n.topicDetail_mostLikedReplies,
      contentPadding: const EdgeInsets.only(bottom: 16),
      builder: (sheetContext) => TopicMostLikedReplies(
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
      if (!detail.isPrivateMessage && count > 0)
        _StatItem(
          leading: showAvatars
              ? TopicParticipantAvatars(
                  users: participants.take(_maxStackedAvatars),
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
          icon: Symbols.menu_book_rounded,
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
    final textStyle = theme.textTheme.bodySmall ?? const TextStyle();
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // 图标、数值、标签与箭头同段排版：数值与标签共用基线，图标经
      // inlineIconSpan 按基线定位。拆成 Row 里的多个组件各自居中时，西文
      // 数字与中文回退字体的行高不同会让两段文字上下错开
      child: Text.rich(
        TextSpan(
          children: [
            if (leading case final leading?)
              WidgetSpan(alignment: PlaceholderAlignment.middle, child: leading)
            else
              inlineIconSpan(
                icon,
                size: 14,
                color: color.withValues(alpha: 0.7),
                textStyle: textStyle,
              ),
            WidgetSpan(child: SizedBox(width: leading != null ? 6 : 4)),
            TextSpan(
              text: value,
              style: TextStyle(
                color: color.withValues(alpha: 0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
            const WidgetSpan(child: SizedBox(width: 2)),
            TextSpan(
              text: label,
              style: TextStyle(color: color.withValues(alpha: 0.5)),
            ),
            if (onTap != null)
              inlineIconSpan(
                Symbols.chevron_right_rounded,
                size: 14,
                color: color.withValues(alpha: 0.5),
                textStyle: textStyle,
              ),
          ],
        ),
        style: theme.textTheme.bodySmall,
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
