import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../models/topic_card_style.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/frame_jank_monitor.dart';
import '../../utils/platform_utils.dart';
import '../../utils/url_helper.dart';
import '../common/smart_avatar.dart';
import '../common/animated_avatar_overlay.dart';
import '../common/perf_span_box.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/category_tags_line.dart';
import '../common/icon_glyph_span.dart';
import '../common/relative_time_text.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';

Widget _withDesktopTertiaryTap(Widget child, VoidCallback? onMiddleClick) {
  if (!PlatformUtils.isDesktop || onMiddleClick == null) return child;
  return GestureDetector(onTertiaryTapUp: (_) => onMiddleClick(), child: child);
}

Widget _clipCardIfNeeded({
  required Widget child,
  required BorderRadius borderRadius,
  required bool shouldClip,
}) {
  if (!shouldClip) return child;
  return ClipRRect(borderRadius: borderRadius, child: child);
}

/// 话题卡交互面(公共):桌面 = Material + InkWell(hover/水波纹/右键/
/// 中键),移动 = 灰底按压面。widget 卡与自绘卡(painted_bookmark_card)
/// 共用同一实现,保证两种卡的交互观感逐像素一致。
class TopicCardInteractiveSurface extends StatelessWidget {
  const TopicCardInteractiveSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onMiddleClick,
    this.onPreviewIntent,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMiddleClick;

  /// 预览意图出现时的回调(预加载正文):移动端 = 按住不动 250ms
  /// (长按判定前 ~250ms 的提前量);桌面端 = 右键按下。与 [onLongPress]
  /// 成对使用,仅在 onLongPress 非空时有意义
  final VoidCallback? onPreviewIntent;
  @override
  Widget build(BuildContext context) {
    if (!PlatformUtils.isDesktop) {
      return _MobileTopicTapSurface(
        borderRadius: borderRadius,
        onTap: onTap,
        onLongPress: onLongPress,
        onPreviewIntent: onPreviewIntent,
        child: child,
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: _withDesktopTertiaryTap(
        InkWell(
          borderRadius: borderRadius,
          splashFactory: InkSplash.splashFactory,
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          // 右键按下即视为预览意图(按下→弹起的间隔就是预加载窗口)
          onSecondaryTapDown: onPreviewIntent == null
              ? null
              : (_) => onPreviewIntent!(),
          child: child,
        ),
        onMiddleClick,
      ),
    );
  }
}

class _MobileTopicTapSurface extends StatefulWidget {
  const _MobileTopicTapSurface({
    required this.borderRadius,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onPreviewIntent,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPreviewIntent;

  @override
  State<_MobileTopicTapSurface> createState() => _MobileTopicTapSurfaceState();
}

class _MobileTopicTapSurfaceState extends State<_MobileTopicTapSurface> {
  bool _pressed = false;

  /// 预览意图计时器:落指 250ms 未抬手/未被抢走即判定为长按意图,
  /// 提前触发预加载(长按判定要 ~500ms,弹窗打开再隔帧 —— 这
  /// ~300ms 就是正文预加载的窗口)。普通点按(<200ms 抬手)与滚动
  /// (tapCancel)都会取消,不会误触发
  Timer? _previewIntentTimer;

  void _armPreviewIntent() {
    if (widget.onPreviewIntent == null) return;
    _previewIntentTimer?.cancel();
    _previewIntentTimer = Timer(
      const Duration(milliseconds: 250),
      widget.onPreviewIntent!,
    );
  }

  void _cancelPreviewIntent() {
    _previewIntentTimer?.cancel();
    _previewIntentTimer = null;
  }

  @override
  void dispose() {
    _cancelPreviewIntent();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    Feedback.forTap(context);
    widget.onTap?.call();
  }

  void _handleLongPress() {
    Feedback.forLongPress(context);
    // 菜单/预览即将接管交互反馈,高亮就地熄灭 —— 不等 onLongPressEnd:
    // 长按被接受后若后续是 PointerCancel(预览模态弹出、滚动仲裁抢走),
    // LongPressGestureRecognizer 不会回调 end(框架无 onLongPressCancel),
    // 灰底会永久残留
    _setPressed(false);
    widget.onLongPress?.call();
  }

  @override
  Widget build(BuildContext context) {
    final overlayColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.06);
    return Semantics(
      onTap: widget.onTap == null ? null : _handleTap,
      onLongPress: widget.onLongPress == null ? null : _handleLongPress,
      // 裸指针兜底:up/cancel 按**落指时**的命中路径派发,无视手势仲裁
      // 结果与模态遮挡,保证任何路径下按压高亮都会熄灭(GestureDetector
      // 的 tapCancel/longPressEnd 覆盖不了"接受后被 cancel"的组合)
      child: Listener(
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: (_) {
            _setPressed(true);
            _armPreviewIntent();
          },
          onTapCancel: () {
            _setPressed(false);
            _cancelPreviewIntent();
          },
          onTapUp: (_) {
            _setPressed(false);
            _cancelPreviewIntent();
          },
          onTap: widget.onTap == null ? null : _handleTap,
          onLongPressStart: widget.onLongPress == null
              ? null
              : (_) => _setPressed(true),
          onLongPress: widget.onLongPress == null ? null : _handleLongPress,
          onLongPressEnd: widget.onLongPress == null
              ? null
              : (_) => _setPressed(false),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _pressed ? overlayColor : Colors.transparent,
              borderRadius: widget.borderRadius,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

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

  /// 预览意图回调(预加载正文),见 TopicCardInteractiveSurface
  final VoidCallback? onPreviewIntent;
  final bool isSelected;
  final Color? highlightColor;
  final Widget? topWidget;

  /// 详情摘要区域,置于标题与署名块之间(如书签的帖子摘要)
  final Widget? middleWidget;

  /// Gmail 式私信布局:发件人置顶加粗、会话主题次行(私信列表用)
  final bool messageStyle;

  /// 由列表层提供时，避免每张卡片各自订阅分类 Provider。
  final Map<int, Category>? categoryMap;

  /// 头像右侧元信息区的可用宽度。首页预先计算后传入，可跳过
  /// Sliver 布局阶段的逐卡 LayoutBuilder 二次构建。
  final double? statsAvailableWidth;

  const TopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.onPreviewIntent,
    this.isSelected = false,
    this.highlightColor,
    this.topWidget,
    this.middleWidget,
    this.messageStyle = false,
    this.categoryMap,
    this.statsAvailableWidth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 帧内构建归因:pop 回列表页 / 列表滚动的 build 大帧此前全是
    // "无构建记录"盲区,补上话题卡片(监控关闭零开销)
    FrameJankMonitor.noteBuild('card#${topic.id}');
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
    // 首行/末行的 meta 文本色
    final metaColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: isFullyRead ? 0.6 : 0.8,
    );
    // 右上角未读槽位：数字徽章 → 蓝点 → 无
    final unreadIndicator = _buildUnreadIndicator(context);

    // 获取分类信息
    final effectiveCategoryMap =
        categoryMap ?? ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = effectiveCategoryMap?[categoryId];

    // 话题卡自定义样式(私信卡不受影响,强制默认)
    final style = messageStyle
        ? TopicCardStyle.defaults
        : ref.watch(preferencesProvider.select((p) => p.topicCardStyle));

    // 标题字号可自定义(默认 15:Gmail 主题行 14 与原版 16 的折中);
    // 私信卡主题行字号在 _buildMessageBody 内部另定,不走这里
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: style.titleFontSize,
      fontWeight: isFullyRead ? FontWeight.w500 : FontWeight.w600,
      height: 1.3,
      color: titleColor,
    );

    // Card 壳换轻装(视觉逐项等价):cardTheme elevation=0 无阴影无 tint,
    // 而 Card→Material 每卡挂一套 AnimatedPhysicalModel 隐式动画基建
    // (AnimationController/Ticker/PhysicalShape),对列表滚动物化是纯税
    // (生产 PROF 点名)。DecoratedBox 复刻色/圆角/选中描边,ClipRRect
    // 复刻 antiAlias 裁剪,Material(transparency) 只做 InkWell 的 ink 载体。
    final cardRadius = BorderRadius.circular(10);
    // PerfSpanBox:整卡子树的 layout/paint 账单(lay:card#N / pnt:card#N),
    // 与 noteBuild 在场名单互补(监控关闭零开销,纯代理盒无视觉影响)
    return PerfSpanBox(
      label: 'card#${topic.id}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _clipCardIfNeeded(
          borderRadius: cardRadius,
          shouldClip: topWidget != null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isSelected
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
                  : (highlightColor ?? theme.cardTheme.color),
              borderRadius: cardRadius,
              border: isSelected
                  ? Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.5),
                    )
                  : null,
            ),
            child: TopicCardInteractiveSurface(
              borderRadius: cardRadius,
              onTap: onTap,
              onLongPress: onLongPress,
              onPreviewIntent: onPreviewIntent,
              onMiddleClick: onMiddleClick,
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
                        : _buildNormalBody(
                            context,
                            style: style,
                            titleStyle: titleStyle,
                            titleColor: titleColor,
                            metaColor: metaColor,
                            isUnread: isUnread,
                            isFullyRead: isFullyRead,
                            unreadIndicator: unreadIndicator,
                            category: category,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fadeWhenRead(
    Widget child, {
    required bool isFullyRead,
    double opacity = 0.55,
  }) {
    return isFullyRead ? Opacity(opacity: opacity, child: child) : child;
  }

  /// 普通话题卡主体:按 [TopicCardStyle.avatarLayout] 分两种结构。
  /// inline = 现状(头像 32 在元信息行内);column = 头像 40 独占左列,
  /// 标题/摘要/元信息都在右侧(类似私信卡,头像顶对齐)
  Widget _buildNormalBody(
    BuildContext context, {
    required TopicCardStyle style,
    required TextStyle? titleStyle,
    required Color titleColor,
    required Color metaColor,
    required bool isUnread,
    required bool isFullyRead,
    required Widget? unreadIndicator,
    required Category? category,
  }) {
    // 第1行：标题满宽置顶(最多两行) + 右侧未读槽位。
    // 论坛列表以标题为主信息,置顶让视线沿左边缘直扫
    final titleRow = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _buildTitleText(
            context,
            style: titleStyle,
            titleColor: titleColor,
            isFullyRead: isFullyRead,
          ),
        ),
        if (unreadIndicator != null) ...[
          const SizedBox(width: 6),
          Padding(
            // 蓝点与标题首行视觉居中;数字徽章本身够高不用补
            padding: EdgeInsets.only(top: topic.unread > 0 ? 0 : 5),
            child: unreadIndicator,
          ),
        ],
      ],
    );

    Widget metadata({required bool withAvatarInline}) {
      Widget block(double availableWidth) => _buildMetadataBlock(
        context,
        style: style,
        category: category,
        metaColor: metaColor,
        isUnread: isUnread,
        isFullyRead: isFullyRead,
        availableWidth: availableWidth,
      );
      final meta = statsAvailableWidth != null
          ? block(statsAvailableWidth!)
          : LayoutBuilder(
              builder: (context, constraints) => block(constraints.maxWidth),
            );
      if (!withAvatarInline) return meta;
      // 第2+3行：头像跨两行,右侧上下两行小字。
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _fadeWhenRead(
            _buildOriginalPosterAvatar(context, style: style),
            isFullyRead: isFullyRead,
            opacity: 0.6,
          ),
          const SizedBox(width: 8),
          Expanded(child: meta),
        ],
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        titleRow,
        // 详情摘要(如书签的帖子摘要):标题下、署名块上,
        // Gmail snippet 的位置
        if (middleWidget != null) ...[const SizedBox(height: 4), middleWidget!],
        const SizedBox(height: 8),
        metadata(
          withAvatarInline: style.avatarLayout == TopicCardAvatarLayout.inline,
        ),
      ],
    );

    if (style.avatarLayout != TopicCardAvatarLayout.column) return content;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fadeWhenRead(
          _buildOriginalPosterAvatar(context, style: style, radius: 20),
          isFullyRead: isFullyRead,
          opacity: 0.6,
        ),
        const SizedBox(width: 10),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildMetadataBlock(
    BuildContext context, {
    required TopicCardStyle style,
    required Category? category,
    required Color metaColor,
    required bool isUnread,
    required bool isFullyRead,
    required double availableWidth,
  }) {
    final theme = Theme.of(context);
    // stats 的已读退灰走色值预乘(见 _buildStat.dim),不再外包 Opacity 层
    final stats = _buildStatsCluster(
      context,
      availableWidth,
      style: style,
      dim: isFullyRead,
    );
    // 分类是骨架字段恒定显示;标签可精简
    final catTags = _buildCategoryTagsLine(
      context,
      category,
      metaColor,
      showTags: style.showTags,
      dim: isFullyRead,
    );
    // 时间是骨架字段,恒定显示
    final timeText = RelativeTimeText(
      dateTime: topic.lastPostedAt,
      style: theme.textTheme.labelSmall?.copyWith(
        color: isUnread ? theme.colorScheme.primary : metaColor,
      ),
    );
    final authorName = style.showAuthor
        ? _buildAuthorName(context, metaColor, isFullyRead: isFullyRead)
        : null;

    // 动态布局:author 与 catTags 双双在场才分两行(署名+时间 /
    // 分类标签+统计);任一缺席则剩余字段合并单行 [左块 … 统计 时间],
    // 行随内容收缩(与自绘卡同构)
    if (authorName == null || catTags == null) {
      final leftBlock = authorName ?? catTags;
      return Row(
        children: [
          Expanded(child: leftBlock ?? const SizedBox.shrink()),
          const SizedBox(width: 8),
          if (stats != null) ...[stats, const SizedBox(width: 10)],
          timeText,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: authorName),
            const SizedBox(width: 8),
            timeText,
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(child: catTags),
            if (stats != null) ...[const SizedBox(width: 8), stats],
          ],
        ),
      ],
    );
  }

  /// 构建楼主头像(默认 32px 跨署名两行;私信/column 布局用 40px)
  Widget _buildOriginalPosterAvatar(
    BuildContext context, {
    TopicCardStyle? style,
    double radius = 16,
  }) {
    // 取第一个 poster（Original Poster）
    if (topic.posters.isNotEmpty) {
      final op = topic.posters.first;
      if (op.user != null) {
        // 静态模板小图打底(几 KB 秒出);动图原件只作 overlay 叠加,
        // ready 前透明、ready 后收起静态层 —— 既避免把几百 KB 的 gif
        // 原件喂进静态首帧管线造成"动图用户头像加载慢",又防透明 gif
        // 从透明像素后透出静态层成"双影"
        final avatarUrl = op.user!.getAvatarUrl(
          size: (radius * 4).round(), // @2x 显示尺寸请求,radius*2 为显示直径
        );
        final animatedUrl = (style?.animatedAvatar ?? true)
            ? op.user!.animatedAvatarUrl
            : null;
        final base = SmartAvatar(
          imageUrl: avatarUrl,
          radius: radius,
          fallbackText: op.user!.username,
        );
        if (animatedUrl == null) return base;
        return AnimatedAvatarStack(
          animatedUrl: animatedUrl,
          base: base,
          size: radius * 2,
        );
      }
    }
    return _buildAvatarFallback(context, radius);
  }

  Widget _buildAvatarFallback(BuildContext context, double radius) {
    final theme = Theme.of(context);
    final fallbackName = topic.posters.isNotEmpty
        ? topic.posters.first.user?.username
        : topic.lastPosterUsername;
    // fallback：用用户名首字母
    if (fallbackName != null && fallbackName.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Text(
          fallbackName[0].toUpperCase(),
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
  Widget _buildTitleText(
    BuildContext context, {
    required TextStyle? style,
    required Color titleColor,
    required bool isFullyRead,
  }) {
    // 绝大多数首页标题没有状态图标和自定义 Emoji。直接走 Text，避免
    // 每次冷挂载都创建 Span 列表并执行 shortcode 正则扫描。
    final needsRichText =
        topic.closed ||
        topic.hasAcceptedAnswer ||
        topic.canHaveAnswer ||
        topic.title.contains(':');
    if (!needsRichText) {
      return Text(
        topic.title,
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Text.rich(
      TextSpan(
        style: style,
        children: _buildTitleSpans(
          context,
          style,
          titleColor,
          isFullyRead: isFullyRead,
        ),
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  List<InlineSpan> _buildTitleSpans(
    BuildContext context,
    TextStyle? style,
    Color titleColor, {
    required bool isFullyRead,
  }) {
    final theme = Theme.of(context);
    return [
      if (topic.closed)
        iconGlyphSpan(
          context,
          Symbols.lock_rounded,
          size: 15,
          color: titleColor,
          gap: 4,
        ),
      if (topic.hasAcceptedAnswer)
        iconGlyphSpan(
          context,
          Symbols.check_box_rounded,
          size: 15,
          // 全读完时随文字一起降饱和
          color: isFullyRead
              ? Colors.green.withValues(alpha: 0.5)
              : Colors.green,
          gap: 4,
        )
      else if (topic.canHaveAnswer)
        iconGlyphSpan(
          context,
          Symbols.check_box_outline_blank_rounded,
          size: 15,
          color: theme.colorScheme.outline,
          gap: 4,
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
        _fadeWhenRead(
          _buildOriginalPosterAvatar(context, radius: 20),
          isFullyRead: isFullyRead,
          opacity: 0.6,
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
              _buildTitleText(
                context,
                style: subjectStyle,
                titleColor: subjectColor,
                isFullyRead: isFullyRead,
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
  /// 已读退灰经 opacityFactor 逐色预乘(像素恒等,免外层 Opacity 层);
  /// 分类和标签都无(或均被开关关闭)时返回 null
  Widget? _buildCategoryTagsLine(
    BuildContext context,
    Category? category,
    Color metaColor, {
    bool showTags = true,
    bool dim = false,
  }) {
    final tags = showTags ? topic.tags : const <Tag>[];
    if (category == null && tags.isEmpty) return null;
    return CategoryTagsLine(
      category: category,
      tags: tags,
      metaColor: metaColor,
      opacityFactor: dim ? 0.55 : 1.0,
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
  /// 与分类/标签同行(时间在第2行),无内容返回 null 不占位;
  /// 字段开关与响应式宽度条件取 AND
  Widget? _buildStatsCluster(
    BuildContext context,
    double availableWidth, {
    required TopicCardStyle style,
    bool dim = false,
  }) {
    final theme = Theme.of(context);
    final showLikes =
        style.showLikes && availableWidth >= 300 && topic.likeCount > 0;
    final showViews =
        style.showViews && availableWidth >= 460 && topic.views > 0;
    final replies = (topic.postsCount - 1).clamp(0, 999999);
    final showReplies = style.showReplies && replies > 0;
    final heatColor = _replyHeatColor(topic, theme);

    final children = <Widget>[
      if (showViews)
        _buildStat(context, Symbols.visibility_rounded, topic.views, dim: dim),
      if (showLikes)
        _buildStat(
          context,
          Symbols.favorite_border_rounded,
          topic.likeCount,
          dim: dim,
        ),
      if (showReplies)
        _buildStat(
          context,
          Symbols.chat_bubble_rounded,
          replies,
          color: heatColor,
          bold: heatColor != null,
          dim: dim,
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
    bool dim = false,
  }) {
    final theme = Theme.of(context);
    // 默认灰度调柔,让热度色计数在对比中突出
    var effectiveColor =
        color ?? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    // 已读退灰:原为外层 Opacity(0.55) 包装 —— 图标/文字字形互不重叠,
    // 色值 alpha 预乘与整层透明像素恒等,省掉每张已读卡的合成层
    if (dim) {
      effectiveColor = effectiveColor.withValues(
        alpha: effectiveColor.a * 0.55,
      );
    }
    // 单段落合并:原 Row[Icon, SizedBox(3), Text] = 2 个段落 + 1 个 Row
    // 布局;Icon 本质是单字形 RichText,字形 span + letterSpacing:3
    // 像素级复刻间距后,每个统计项只剩 1 个段落
    return Text.rich(
      TextSpan(
        children: [
          iconGlyphSpan(
            context,
            icon,
            size: 13,
            color: effectiveColor,
            gap: 3,
            textStyle: theme.textTheme.labelSmall,
          ),
          TextSpan(
            text: NumberUtils.formatCount(count),
            style: theme.textTheme.labelSmall?.copyWith(
              color: effectiveColor,
              fontWeight: bold ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 紧凑型话题卡片 - 用于置顶话题
class CompactTopicCard extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onTap;
  final VoidCallback? onMiddleClick;
  final VoidCallback? onLongPress;
  final VoidCallback? onPreviewIntent;
  final bool isSelected;
  final Color? highlightColor;
  final Map<int, Category>? categoryMap;

  const CompactTopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.onPreviewIntent,
    this.isSelected = false,
    this.highlightColor,
    this.categoryMap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    FrameJankMonitor.noteBuild('card#${topic.id}');
    final theme = Theme.of(context);
    final isUnread = topic.unseen || topic.unread > 0;

    // 获取分类信息
    final effectiveCategoryMap =
        categoryMap ?? ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = effectiveCategoryMap?[categoryId];

    // 图标逻辑
    FaIconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = effectiveCategoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    // 同 TopicCard:Card 壳换轻装(elevation=0 主题下视觉逐项等价),
    // 砍每卡一套 AnimatedPhysicalModel 隐式动画基建。
    final cardRadius = BorderRadius.circular(10);
    final compactTitleStyle = theme.textTheme.labelMedium?.copyWith(
      fontWeight: isUnread ? FontWeight.w500 : FontWeight.w400,
      color: isUnread
          ? theme.colorScheme.onSurface
          : theme.colorScheme.onSurfaceVariant,
    );
    final needsRichTitle =
        topic.closed ||
        topic.hasAcceptedAnswer ||
        topic.canHaveAnswer ||
        topic.title.contains(':');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _clipCardIfNeeded(
        borderRadius: cardRadius,
        shouldClip: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isSelected
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
                : highlightColor ??
                      theme.colorScheme.surfaceContainerLow.withValues(
                        alpha: 0.5,
                      ),
            borderRadius: cardRadius,
            border: isSelected
                ? Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  )
                : null,
          ),
          child: TopicCardInteractiveSurface(
            borderRadius: cardRadius,
            onTap: onTap,
            onLongPress: onLongPress,
            onPreviewIntent: onPreviewIntent,
            onMiddleClick: onMiddleClick,
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
                      FaIcon(
                        faIcon,
                        size: 12,
                        color: _parseColor(category.color),
                      )
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
                    child: needsRichTitle
                        ? Text.rich(
                            TextSpan(
                              style: compactTitleStyle,
                              children: [
                                if (topic.closed)
                                  iconGlyphSpan(
                                    context,
                                    Symbols.lock_rounded,
                                    size: 12,
                                    color: isUnread
                                        ? theme.colorScheme.onSurface
                                        : theme.colorScheme.onSurfaceVariant,
                                    gap: 3,
                                  ),
                                if (topic.hasAcceptedAnswer)
                                  iconGlyphSpan(
                                    context,
                                    Symbols.check_box_rounded,
                                    size: 12,
                                    color: Colors.green,
                                    gap: 3,
                                  )
                                else if (topic.canHaveAnswer)
                                  iconGlyphSpan(
                                    context,
                                    Symbols.check_box_outline_blank_rounded,
                                    size: 12,
                                    color: theme.colorScheme.outline,
                                    gap: 3,
                                  ),
                                ...EmojiText.buildEmojiSpans(
                                  context,
                                  topic.title,
                                  compactTitleStyle,
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : Text(
                            topic.title,
                            style: compactTitleStyle,
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
                    // 单段落:字形 span 复刻 Icon(12)+SizedBox(2)+Text
                    Text.rich(
                      TextSpan(
                        children: [
                          iconGlyphSpan(
                            context,
                            Symbols.chat_bubble_rounded,
                            size: 12,
                            color: theme.colorScheme.outline.withValues(
                              alpha: 0.7,
                            ),
                            gap: 2,
                            textStyle: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                            ),
                          ),
                          TextSpan(
                            text: '${topic.postsCount - 1}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline.withValues(
                                alpha: 0.7,
                              ),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
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
