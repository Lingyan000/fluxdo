import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../../providers/selected_topic_provider.dart';
import '../../utils/discourse_url_parser.dart';

/// 帖子相关链接组件
///
/// 显示其他帖子引用当前帖子的入站链接（reflection links）
/// 默认折叠，点击标题栏展开/收起
class PostLinks extends StatefulWidget {
  final List<LinkCount>? linkCounts;
  final bool defaultExpanded;

  /// 最大折叠显示数量
  static const int maxCollapsedLinks = 5;

  const PostLinks({
    super.key,
    this.linkCounts,
    this.defaultExpanded = false,
  });

  @override
  State<PostLinks> createState() => _PostLinksState();
}

class _PostLinksState extends State<PostLinks> with SingleTickerProviderStateMixin {
  late bool _expanded = widget.defaultExpanded;
  bool _showAll = false; // 链接列表内部的"查看更多"

  /// 获取内部入站链接（reflection links）
  List<LinkCount> get _internalLinks {
    if (widget.linkCounts == null) return [];

    // 过滤：内部链接 + reflection + 有标题
    final filtered = widget.linkCounts!
        .where((l) => l.internal && l.reflection && l.title != null && l.title!.isNotEmpty)
        .toList();

    // 按标题去重
    final seen = <String>{};
    final unique = <LinkCount>[];
    for (final link in filtered) {
      if (!seen.contains(link.title)) {
        seen.add(link.title!);
        unique.add(link);
      }
    }

    return unique;
  }

  List<LinkCount> get _displayedLinks {
    final links = _internalLinks;
    if (_showAll || links.length <= PostLinks.maxCollapsedLinks) {
      return links;
    }
    return links.take(PostLinks.maxCollapsedLinks).toList();
  }

  bool get _canShowMore {
    return _internalLinks.length > PostLinks.maxCollapsedLinks && !_showAll;
  }

  int get _remainingCount {
    return _internalLinks.length - PostLinks.maxCollapsedLinks;
  }

  /// 处理链接点击:平行视界面板内压当前栈(与正文内链同语义),
  /// 全屏页照旧 push。
  void _onLinkTap(LinkCount link) {
    final topicInfo = DiscourseUrlParser.parseTopic(link.url);
    if (topicInfo != null) {
      if (EmbeddedStackScope.maybePushTopic(
        context,
        topicId: topicInfo.topicId,
        initialTitle: link.title,
      )) {
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TopicDetailPage(
            topicId: topicInfo.topicId,
            initialTitle: link.title,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final links = _internalLinks;
    if (links.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 可点击的标题栏
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: _expanded
                ? const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  )
                : BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Symbols.link_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.post_relatedLinks,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${links.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Symbols.expand_more_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开的链接列表。用 AnimatedSize + 条件渲染而不是
          // AnimatedCrossFade:后者收起状态也会构建并布局整个列表
          // (楼层挂载时白付几 ms),而视觉上可感知的只有尺寸过渡。
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity, height: 0)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                      ..._displayedLinks.map((link) => _buildLinkItem(link, theme)),
                      if (_canShowMore)
                        InkWell(
                          onTap: () => setState(() => _showAll = true),
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(12),
                            bottomRight: Radius.circular(12),
                          ),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Symbols.more_horiz_rounded,
                                  size: 16,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  context.l10n.post_moreLinks(_remainingCount),
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkItem(LinkCount link, ThemeData theme) {
    return InkWell(
      onTap: () => _onLinkTap(link),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Symbols.subdirectory_arrow_right_rounded,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                link.title ?? link.url,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (link.clicks > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _formatClicks(link.clicks),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(
              Symbols.arrow_outward_rounded,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  /// 格式化点击数
  String _formatClicks(int count) {
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return '$count';
  }
}
