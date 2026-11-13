import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../utils/link_launcher.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../../widgets/user/user_card.dart';

/// 话题的参与者、点赞、阅读时长和链接汇总。
class TopicStatistics extends StatelessWidget {
  const TopicStatistics({super.key, required this.detail, this.wordsPerMinute});

  final TopicDetail detail;
  final num? wordsPerMinute;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final participants = detail.participants;
    final count = math.max(detail.participantCount, participants.length);
    final speed = wordsPerMinute;
    // 与 Discourse 统计区一致，较短话题不显示估算阅读时间。
    final minutes = speed != null && speed > 0
        ? math.max(detail.wordCount / speed, detail.postsCount / 15).ceil()
        : 0;
    final stats = <String>[
      if (count > 0) l10n.topicDetail_participantCount(count),
      if (detail.likeCount > 0) l10n.topicDetail_totalLikes(detail.likeCount),
      if (minutes > 3) l10n.topicDetail_readMinutes(minutes),
      if (detail.links.isNotEmpty)
        l10n.topicDetail_linkCount(detail.links.length),
    ];
    if (stats.isEmpty) return const SizedBox.shrink();
    final summary = Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final text in stats)
          Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    if (participants.isEmpty && detail.links.isEmpty) {
      return Padding(padding: const EdgeInsets.only(top: 12), child: summary);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        key: PageStorageKey('topic-statistics-${detail.id}'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: summary,
        children: [
          if (participants.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final participant in participants)
                    Builder(
                      builder: (chipContext) => ActionChip(
                        avatar: SmartAvatar(
                          imageUrl: participant.getAvatarUrl(size: 48),
                          radius: 12,
                          fallbackText: participant.username,
                        ),
                        label: Text(
                          l10n.topicDetail_participantPosts(
                            participant.displayName,
                            participant.postCount,
                          ),
                        ),
                        onPressed: canShowUserCardPreview(context)
                            ? () {
                                final box =
                                    chipContext.findRenderObject() as RenderBox;
                                showUserCard(
                                  context: chipContext,
                                  anchorRect:
                                      box.localToGlobal(Offset.zero) & box.size,
                                  username: participant.username,
                                  topicId: detail.id,
                                  topicTitle: detail.title,
                                  nameFallback: participant.name,
                                  avatarFallbackUrl: participant.getAvatarUrl(
                                    size: 144,
                                  ),
                                );
                              }
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          if (detail.links.isNotEmpty) _TopicLinks(links: detail.links),
        ],
      ),
    );
  }
}

class _TopicLinks extends StatefulWidget {
  const _TopicLinks({required this.links});
  final List<TopicLink> links;

  @override
  State<_TopicLinks> createState() => _TopicLinksState();
}

class _TopicLinksState extends State<_TopicLinks> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final links = _showAll ? widget.links : widget.links.take(5);
    return Column(
      children: [
        for (final link in links)
          ListTile(
            contentPadding: EdgeInsets.zero,
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
              child: Text('${link.clicks}'),
            ),
            onTap: () => launchContentLink(context, link.url),
          ),
        if (!_showAll && widget.links.length > 5)
          TextButton(
            onPressed: () => setState(() => _showAll = true),
            child: Text(
              context.l10n.topicDetail_showAllLinks(widget.links.length),
            ),
          ),
      ],
    );
  }
}
