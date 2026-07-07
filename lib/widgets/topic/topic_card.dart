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
import '../common/category_tags_line.dart';
import '../common/relative_time_text.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';

/// 话题卡片组件 — 标题置顶布局:
/// 1. 标题(满宽,最多两行,未读加粗)+ 右侧未读槽位
///    (可选)详情摘要(middleWidget,Gmail snippet 位)
/// 2. 头像(32px,跨两行)+ 昵称 ······ 时间
/// 3.                    ▪分类 + 标签 ······ 统计
/// 分类固定在第3行行首,纵向扫描时位置恒定不漂移;
/// 无分类无标签时(如私信)退化为单行署名:昵称 ······ 统计 + 时间
class TopicCard extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onTap;
  final VoidCallback? onMiddleClick;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final Color? highlightColor;
  final Widget? topWidget;

  /// 详情摘要区域,置于标题与署名块之间(如书签的帖子摘要)
  final Widget? middleWidget;

  /// Gmail 式私信布局:发件人置顶加粗、会话主题次行(私信列表用)
  final bool messageStyle;

  const TopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.isSelected = false,
    this.highlightColor,
    this.topWidget,
    this.middleWidget,
    this.messageStyle = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 新内容信号(蓝点/未读数/时间高亮):新话题或有未读回复
    final isUnread = topic.unseen || topic.unread > 0;
    // 全部读完：进入过话题且没有未读帖子
    final isFullyRead =
        !topic.unseen && topic.unread == 0 && topic.lastReadPostNumber != null;

    // 视觉二态:没读完(常规,加粗) / 读完了(整卡退灰)。
    // "没点开过的旧话题"语义上也是没读,归入强调态,避免出现第三档深浅
    // onSurfaceVariant 与 onSurface 在部分主题下区分度不够,
    // 叠一层透明度让已读态明确退后
    final titleColor = isFullyRead
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75)
        : theme.colorScheme.onSurface;
    // 标题 15sp:Gmail 主题行(14)与原版(16)的折中,置顶后担得起主视觉
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      fontWeight: isFullyRead ? FontWeight.w500 : FontWeight.w600,
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
                child: messageStyle
                    ? _buildMessageBody(
                        context,
                        isUnread: isUnread,
                        isFullyRead: isFullyRead,
                        metaColor: metaColor,
                        unreadIndicator: unreadIndicator,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 第1行：标题满宽置顶(最多两行) + 右侧未读槽位。
                          // 论坛列表以标题为主信息,置顶让视线沿左边缘直扫
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    style: titleStyle,
                                    children: _buildTitleSpans(
                                      context,
                                      titleStyle,
                                      titleColor,
                                      isFullyRead: isFullyRead,
                                    ),
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (unreadIndicator != null) ...[
                                const SizedBox(width: 6),
                                Padding(
                                  // 蓝点与标题首行视觉居中;数字徽章本身够高不用补
                                  padding: EdgeInsets.only(
                                    top: topic.unread > 0 ? 0 : 5,
                                  ),
                                  child: unreadIndicator,
                                ),
                              ],
                            ],
                          ),
                          // 详情摘要(如书签的帖子摘要):标题下、署名块上,
                          // Gmail snippet 的位置
                          if (middleWidget != null) ...[
                            const SizedBox(height: 4),
                            middleWidget!,
                          ],
                          const SizedBox(height: 8),

                          // 第2+3行：头像跨两行,右侧上下两行小字;
                          // 32px 头像正好撑满两行 labelSmall,无留白也不撑高。
                          // 无分类无标签时(如私信)退化为单行署名,头像居中
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Opacity(
                                opacity: isFullyRead ? 0.6 : 1.0,
                                child: _buildOriginalPosterAvatar(context),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final stats = _buildStatsCluster(
                                      context,
                                      constraints.maxWidth,
                                    );
                                    final catTags = _buildCategoryTagsLine(
                                      context,
                                      category,
                                      metaColor,
                                    );
                                    final timeText = RelativeTimeText(
                                      dateTime: topic.lastPostedAt,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            // 未读时时间用主题色,
                                            // 呼应 Gmail 的未读高亮
                                            color: isUnread
                                                ? theme.colorScheme.primary
                                                : metaColor,
                                          ),
                                    );

                                    // 单行署名:昵称 ······ 统计 + 时间
                                    if (catTags == null) {
                                      return Row(
                                        children: [
                                          Expanded(
                                            child: _buildAuthorName(
                                              context,
                                              metaColor,
                                              isFullyRead: isFullyRead,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (stats != null) ...[
                                            Opacity(
                                              opacity: isFullyRead ? 0.55 : 1.0,
                                              child: stats,
                                            ),
                                            const SizedBox(width: 10),
                                          ],
                                          timeText,
                                        ],
                                      );
                                    }

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // 第2行：昵称 ······ 时间(右对齐可扫新)
                                        Row(
                                          children: [
                                            Expanded(
                                              child: _buildAuthorName(
                                                context,
                                                metaColor,
                                                isFullyRead: isFullyRead,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            timeText,
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        // 第3行：▪分类 + 标签 ······ 统计。
                                        // 分类恒在行首,纵向扫描时位置固定不漂移
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Opacity(
                                                // 全读完时分类色/标签色随文字退灰
                                                opacity: isFullyRead
                                                    ? 0.55
                                                    : 1.0,
                                                child: catTags,
                                              ),
                                            ),
                                            if (stats != null) ...[
                                              const SizedBox(width: 8),
                                              Opacity(
                                                opacity: isFullyRead
                                                    ? 0.55
                                                    : 1.0,
                                                child: stats,
                                              ),
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
            ],
          ),
        ),
      ),
    );
  }

  /// 构建楼主头像(默认 32px 跨署名两行;私信布局用 40px)
  Widget _buildOriginalPosterAvatar(
    BuildContext context, {
    double radius = 16,
  }) {
    final theme = Theme.of(context);
    // 取第一个 poster（Original Poster）
    if (topic.posters.isNotEmpty) {
      final op = topic.posters.first;
      if (op.user != null) {
        // @2x 显示尺寸请求,radius*2 为显示直径
        final avatarUrl = op.user!.getAvatarUrl(size: (radius * 4).round());
        return SmartAvatar(
          imageUrl: avatarUrl,
          radius: radius,
          fallbackText: op.user!.username,
        );
      }
    }
    // fallback：用 lastPosterUsername 首字母
    if (topic.lastPosterUsername != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Text(
          topic.lastPosterUsername![0].toUpperCase(),
          style: TextStyle(
            fontSize: radius * 0.8,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      );
    }
    return SizedBox(width: radius * 2, height: radius * 2);
  }

  /// 标题行内 spans:锁定/已解决/可解决图标 + emoji 标题文本
  List<InlineSpan> _buildTitleSpans(
    BuildContext context,
    TextStyle? style,
    Color titleColor, {
    required bool isFullyRead,
  }) {
    final theme = Theme.of(context);
    return [
      if (topic.closed)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Symbols.lock_rounded, size: 15, color: titleColor),
          ),
        ),
      if (topic.hasAcceptedAnswer)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(
              Symbols.check_box_rounded,
              size: 15,
              // 全读完时随文字一起降饱和
              color: isFullyRead
                  ? Colors.green.withValues(alpha: 0.5)
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
              size: 15,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ...EmojiText.buildEmojiSpans(context, topic.title, style),
    ];
  }

  /// Gmail 式私信布局:头像跨两行,发件人置顶加粗,会话主题次行。
  /// 私信语义与邮件一致:"谁发来的"是首要信息,主题次之
  Widget _buildMessageBody(
    BuildContext context, {
    required bool isUnread,
    required bool isFullyRead,
    required Color metaColor,
    required Widget? unreadIndicator,
  }) {
    final theme = Theme.of(context);
    // 发件人:卡片里最大最粗的元素(Gmail 发件人行定位)
    final senderStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      fontWeight: isFullyRead ? FontWeight.w400 : FontWeight.w600,
      color: isFullyRead
          ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75)
          : theme.colorScheme.onSurface,
    );
    // 主题行:比发件人小一档,未读微加粗
    final subjectColor = isFullyRead
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75)
        : theme.colorScheme.onSurface.withValues(alpha: 0.9);
    final subjectStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: isFullyRead ? FontWeight.w400 : FontWeight.w500,
      height: 1.3,
      color: subjectColor,
    );
    final name = topic.posters.isNotEmpty
        ? topic.posters.first.user?.displayName
        : topic.lastPosterUsername;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: isFullyRead ? 0.6 : 1.0,
          child: _buildOriginalPosterAvatar(context, radius: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第1行：发件人 ······ 时间 + 未读槽位
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name ?? '',
                      style: senderStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  RelativeTimeText(
                    dateTime: topic.lastPostedAt,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isUnread ? theme.colorScheme.primary : metaColor,
                    ),
                  ),
                  if (unreadIndicator != null) ...[
                    const SizedBox(width: 6),
                    unreadIndicator,
                  ],
                ],
              ),
              const SizedBox(height: 2),
              // 第2行：会话主题(最多两行)
              Text.rich(
                TextSpan(
                  style: subjectStyle,
                  children: _buildTitleSpans(
                    context,
                    subjectStyle,
                    subjectColor,
                    isFullyRead: isFullyRead,
                  ),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (middleWidget != null) ...[
                const SizedBox(height: 2),
                middleWidget!,
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 第2行:楼主昵称(优先 name,空回退 username);
  /// 没读完时加粗提亮,全读完随 metaColor 退灰
  Widget _buildAuthorName(
    BuildContext context,
    Color metaColor, {
    required bool isFullyRead,
  }) {
    final theme = Theme.of(context);
    // 优先昵称(linux.do 用户多设中文昵称,辨识度更高),空则回退 username
    final name = topic.posters.isNotEmpty
        ? topic.posters.first.user?.displayName
        : topic.lastPosterUsername;
    return Text(
      name ?? '',
      style: theme.textTheme.labelSmall?.copyWith(
        color: isFullyRead
            ? metaColor
            : theme.colorScheme.onSurface.withValues(alpha: 0.85),
        fontWeight: isFullyRead ? null : FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 第3行:▪分类色标+名 + 标签轻文本,单行 ellipsis(共享组件)。
  /// 全读退灰由外层 Opacity 统一处理;分类和标签都无时返回 null
  Widget? _buildCategoryTagsLine(
    BuildContext context,
    Category? category,
    Color metaColor,
  ) {
    if (category == null && topic.tags.isEmpty) return null;
    return CategoryTagsLine(
      category: category,
      tags: topic.tags,
      metaColor: metaColor,
    );
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
  /// 与分类/标签同行(时间在第2行),无内容返回 null 不占位
  Widget? _buildStatsCluster(BuildContext context, double availableWidth) {
    final theme = Theme.of(context);
    final showLikes = availableWidth >= 300 && topic.likeCount > 0;
    final showViews = availableWidth >= 460 && topic.views > 0;
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
                        fontSize: 10,
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
