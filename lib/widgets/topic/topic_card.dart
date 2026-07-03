import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/platform_utils.dart';
import '../../utils/url_helper.dart';
import '../common/smart_avatar.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/relative_time_text.dart';
import '../../utils/number_utils.dart';
import '../../utils/tag_icon_list.dart';
import '../../utils/color_utils.dart';
import '../common/emoji_text.dart';

/// 话题卡片组件 — Gmail 式三行布局:
/// 1. 楼主 · 分类 ······ 时间 + 未读槽位
/// 2. 标题(满宽,最多两行,未读加粗)
/// 3. 标签轻文本(单行 ellipsis) ······ 统计
class TopicCard extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onTap;
  final VoidCallback? onMiddleClick;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final Color? highlightColor;
  final Widget? topWidget;
  final Widget? bottomWidget;

  const TopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.isSelected = false,
    this.highlightColor,
    this.topWidget,
    this.bottomWidget,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUnread = topic.unseen || topic.unread > 0;
    // 全部读完：进入过话题且没有未读帖子
    final isFullyRead =
        !topic.unseen && topic.unread == 0 && topic.lastReadPostNumber != null;

    // Gmail 式层级:未读 = 标题加粗 + 深色;已读 = 常规字重 + 灰色
    final titleColor = isUnread
        ? theme.colorScheme.onSurface
        : isFullyRead
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
        : theme.colorScheme.onSurfaceVariant;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: isUnread ? FontWeight.w600 : FontWeight.w400,
      height: 1.3,
      color: titleColor,
    );
    // 首行/末行的 meta 文本色
    final metaColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: isFullyRead ? 0.6 : 0.8,
    );
    // 右上角未读槽位：数字徽章 → 蓝点 → 无
    final unreadIndicator = _buildUnreadIndicator(context);

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = categoryMap?[categoryId];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : highlightColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected
            ? BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              )
            : BorderSide.none,
      ),
      child: GestureDetector(
        onTertiaryTapUp: PlatformUtils.isDesktop && onMiddleClick != null
            ? (_) => onMiddleClick!.call()
            : null,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: PlatformUtils.isDesktop ? onLongPress : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部附属区域（如书签元信息色带）
              if (topWidget != null) ...[topWidget!],
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 左侧：楼主头像,顶对齐锁定第一行(全读完时轻降)
                    Opacity(
                      opacity: isFullyRead ? 0.6 : 1.0,
                      child: _buildOriginalPosterAvatar(context),
                    ),
                    const SizedBox(width: 10),
                    // 右侧：Gmail 式三行
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 第1行：楼主 · 分类 ······ 时间 + 未读槽位
                          Row(
                            children: [
                              Expanded(
                                child: _buildMetaLine(
                                  context,
                                  category,
                                  metaColor,
                                  isUnread: isUnread,
                                  isFullyRead: isFullyRead,
                                ),
                              ),
                              const SizedBox(width: 8),
                              RelativeTimeText(
                                dateTime: topic.lastPostedAt,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  // 未读时时间用主题色,呼应 Gmail 的未读高亮
                                  // (蓝点已是强信号,这里不再加粗)
                                  color: isUnread
                                      ? theme.colorScheme.primary
                                      : metaColor,
                                ),
                              ),
                              if (unreadIndicator != null) ...[
                                const SizedBox(width: 6),
                                unreadIndicator,
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),

                          // 第2行：标题满宽,最多两行
                          Text.rich(
                            TextSpan(
                              style: titleStyle,
                              children: [
                                if (topic.closed)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Icon(
                                        Symbols.lock_rounded,
                                        size: 16,
                                        color: titleColor,
                                      ),
                                    ),
                                  ),
                                if (topic.hasAcceptedAnswer)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Icon(
                                        Symbols.check_box_rounded,
                                        size: 16,
                                        // 全读完时随文字一起降饱和
                                        color: isFullyRead
                                            ? Colors.green.withValues(
                                                alpha: 0.5,
                                              )
                                            : Colors.green,
                                      ),
                                    ),
                                  )
                                else if (topic.canHaveAnswer)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Icon(
                                        Symbols.check_box_outline_blank_rounded,
                                        size: 16,
                                        color: theme.colorScheme.outline,
                                      ),
                                    ),
                                  ),
                                ...EmojiText.buildEmojiSpans(
                                  context,
                                  topic.title,
                                  titleStyle,
                                ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),

                          // 第3行：标签轻文本（单行 ellipsis） ······ 统计
                          // 两者都为空时整行省掉
                          if (topic.tags.isNotEmpty ||
                              topic.postsCount > 1 ||
                              topic.likeCount > 0) ...[
                            const SizedBox(height: 4),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                return Opacity(
                                  // 全读完时标签色/热度色整体降饱和,
                                  // 与标题降色一致地"退后"
                                  opacity: isFullyRead ? 0.55 : 1.0,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child:
                                            _buildTagsLine(
                                              context,
                                              metaColor,
                                            ) ??
                                            const SizedBox.shrink(),
                                      ),
                                      const SizedBox(width: 8),
                                      _buildStatsCluster(
                                        context,
                                        constraints.maxWidth,
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 底部附属区域
              if (bottomWidget != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 2, 14, 8),
                  child: bottomWidget!,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建楼主头像
  Widget _buildOriginalPosterAvatar(BuildContext context) {
    final theme = Theme.of(context);
    // 取第一个 poster（Original Poster）
    if (topic.posters.isNotEmpty) {
      final op = topic.posters.first;
      if (op.user != null) {
        final avatarUrl = op.user!.getAvatarUrl(size: 68);
        return SmartAvatar(
          imageUrl: avatarUrl,
          radius: 17,
          fallbackText: op.user!.username,
        );
      }
    }
    // fallback：用 lastPosterUsername 首字母
    if (topic.lastPosterUsername != null) {
      return CircleAvatar(
        radius: 17,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Text(
          topic.lastPosterUsername![0].toUpperCase(),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      );
    }
    return const SizedBox(width: 34, height: 34);
  }

  /// 第1行:楼主用户名 · 分类(色标+名称)
  /// 全部为轻文本,Gmail 发件人行的定位;未读时用户名加粗提亮,
  /// 全读完时分类色降饱和退灰
  Widget _buildMetaLine(
    BuildContext context,
    Category? category,
    Color metaColor, {
    required bool isUnread,
    required bool isFullyRead,
  }) {
    final theme = Theme.of(context);
    final username = topic.posters.isNotEmpty
        ? topic.posters.first.user?.username
        : topic.lastPosterUsername;
    // 分类色按主题亮度适配:暗色主题提亮、亮色主题压暗,保证可读;
    // 全读完时再降透明度,与文字一起"退后"
    Color? categoryColor;
    if (category != null) {
      categoryColor = ColorUtils.readableOn(
        _parseCategoryColor(category.color),
        theme.brightness,
      );
      if (isFullyRead) {
        categoryColor = categoryColor.withValues(alpha: 0.55);
      }
    }
    final style = theme.textTheme.labelSmall?.copyWith(color: metaColor);

    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (username != null && username.isNotEmpty)
            TextSpan(
              text: username,
              // Gmail:未读时发件人加粗提亮
              style: isUnread
                  ? TextStyle(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.85,
                      ),
                    )
                  : null,
            ),
          if (username != null && username.isNotEmpty && category != null)
            TextSpan(
              text: ' · ',
              style: TextStyle(color: metaColor.withValues(alpha: 0.5)),
            ),
          if (category != null) ...[
            // 统一用 Discourse 式分类色标(小圆角方块):
            // FA 图标/logo/圆点三种形态混排是列表显乱的来源,
            // 色标形态恒定,颜色即分类身份
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                margin: const EdgeInsets.only(right: 4),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: categoryColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            TextSpan(
              // 分类名用中性色:颜色锚点只留给前面的色标,
              // 避免整行文字被彩色劈成两截
              text: category.name,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 第3行:标签轻文本(图标+名称,空格分隔),单行 ellipsis;无标签返回 null
  Widget? _buildTagsLine(BuildContext context, Color metaColor) {
    if (topic.tags.isEmpty) return null;
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: metaColor);

    final spans = <InlineSpan>[];
    for (var i = 0; i < topic.tags.length; i++) {
      final tag = topic.tags[i];
      final tagInfo = TagIconList.get(tag.name);
      if (i > 0) spans.add(const TextSpan(text: '   '));
      if (tagInfo != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 3),
              child: FaIcon(
                tagInfo.icon,
                size: 10,
                // 标签图标色同样按主题亮度适配
                color: ColorUtils.readableOn(tagInfo.color, theme.brightness),
              ),
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: '#',
            style: TextStyle(color: metaColor.withValues(alpha: 0.6)),
          ),
        );
      }
      spans.add(TextSpan(text: tag.name));
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Color _parseCategoryColor(String hex) {
    final clean = hex.replaceAll('#', '');
    if (clean.length == 6) {
      return Color(int.parse('0xFF$clean'));
    }
    return Colors.grey;
  }

  /// 右上角未读槽位：数字徽章（unread）→ 蓝点（unseen）→ null（不占位）
  Widget? _buildUnreadIndicator(BuildContext context) {
    final theme = Theme.of(context);
    if (topic.unread > 0) {
      // 未读数：主题色圆角徽章
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '${topic.unread}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    if (topic.unseen) {
      // 新话题蓝点：固定槽位，不再随标题截断消失
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
        ),
      );
    }
    return null;
  }

  /// 第3行右侧统计簇:💬回复(热度色)为主,宽度富余时加 ❤/👁。
  /// 时间已上移到第1行,这里只放计数,窄屏也放得下。
  Widget _buildStatsCluster(BuildContext context, double availableWidth) {
    final theme = Theme.of(context);
    final showLikes = availableWidth >= 270 && topic.likeCount > 0;
    final showViews = availableWidth >= 420 && topic.views > 0;
    final replies = (topic.postsCount - 1).clamp(0, 999999);
    final heatColor = _replyHeatColor(topic, theme);

    final children = <Widget>[
      if (showViews)
        _buildStat(context, Symbols.visibility_rounded, topic.views),
      if (showLikes)
        _buildStat(context, Symbols.favorite_border_rounded, topic.likeCount),
      if (replies > 0)
        _buildStat(
          context,
          Symbols.chat_bubble_rounded,
          replies,
          color: heatColor,
          bold: heatColor != null,
        ),
    ];
    if (children.isEmpty) return const SizedBox.shrink();

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

  /// 计算 likes/posts 比率
  double _heatRatio(Topic topic) {
    if (topic.postsCount < 10) return 0;
    return topic.likeCount / topic.postsCount;
  }

  /// 回复数热度颜色
  Color? _replyHeatColor(Topic topic, ThemeData theme) {
    final ratio = _heatRatio(topic);
    if (ratio > 2.0) return const Color(0xFFFE7A15); // 高热度-橙色
    if (ratio > 1.0) return const Color(0xFFCF7721); // 中热度-暗橙色
    if (ratio > 0.5) return const Color(0xFF9B764F); // 低热度-褐色
    return null; // 默认颜色
  }

  Widget _buildStat(
    BuildContext context,
    IconData icon,
    int count, {
    Color? color,
    bool bold = false,
  }) {
    final theme = Theme.of(context);
    // 默认灰度调柔,让热度色计数在对比中突出
    final effectiveColor =
        color ?? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: effectiveColor),
        const SizedBox(width: 3),
        Text(
          NumberUtils.formatCount(count),
          style: theme.textTheme.labelSmall?.copyWith(
            color: effectiveColor,
            fontWeight: bold ? FontWeight.w600 : null,
          ),
        ),
      ],
    );
  }
}

/// 紧凑型话题卡片 - 用于置顶话题
class CompactTopicCard extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onTap;
  final VoidCallback? onMiddleClick;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final Color? highlightColor;

  const CompactTopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.isSelected = false,
    this.highlightColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUnread = topic.unseen || topic.unread > 0;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = categoryMap?[categoryId];

    // 图标逻辑
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
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : highlightColor ??
                theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected
            ? BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              )
            : BorderSide.none,
      ),
      child: GestureDetector(
        onTertiaryTapUp: PlatformUtils.isDesktop && onMiddleClick != null
            ? (_) => onMiddleClick!.call()
            : null,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: PlatformUtils.isDesktop ? onLongPress : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // 1. 置顶图标
                Icon(
                  Symbols.push_pin_rounded,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),

                // 2. 分类图标/Dot
                if (category != null) ...[
                  if (faIcon != null)
                    FaIcon(faIcon, size: 12, color: _parseColor(category.color))
                  else if (logoUrl != null && logoUrl.isNotEmpty)
                    Image(
                      image: discourseImageProvider(
                        UrlHelper.resolveUrlWithCdn(logoUrl),
                      ),
                      width: 12,
                      height: 12,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return _buildCategoryDot(category);
                      },
                    )
                  else
                    _buildCategoryDot(category),
                  const SizedBox(width: 8),
                ],

                // 3. 标题
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: isUnread
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: isUnread
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      children: [
                        if (topic.closed)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Symbols.lock_rounded,
                                size: 12,
                                color: isUnread
                                    ? theme.colorScheme.onSurface
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (topic.hasAcceptedAnswer)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Symbols.check_box_rounded,
                                size: 12,
                                color: Colors.green,
                              ),
                            ),
                          )
                        else if (topic.canHaveAnswer)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Symbols.check_box_outline_blank_rounded,
                                size: 12,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                        ...EmojiText.buildEmojiSpans(
                          context,
                          topic.title,
                          theme.textTheme.labelMedium?.copyWith(
                            fontWeight: isUnread
                                ? FontWeight.w500
                                : FontWeight.w400,
                            color: isUnread
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                const SizedBox(width: 8),

                // 4. 未读数或简单状态
                if (topic.unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.7,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${topic.unread}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                        fontSize: 9,
                      ),
                    ),
                  )
                else if (topic.postsCount > 1)
                  Row(
                    children: [
                      Icon(
                        Symbols.chat_bubble_rounded,
                        size: 12,
                        color: theme.colorScheme.outline.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${topic.postsCount - 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.7,
                          ),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryDot(Category category) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: _parseColor(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}
