import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import '../../../utils/responsive.dart';

import 'package:common_ui/common_ui.dart';

import '../../../utils/time_utils.dart';
import '../../../widgets/common/emoji_text.dart';
import '../controllers/topic_position_info.dart';
import 'topic_bar_gestures.dart';
import 'topic_filter_controls.dart';
import 'topic_floating_bar_edge.dart';
import 'topic_progress_track.dart';

/// 话题底栏尺寸：列表末尾留白、回顶 / 目录按钮定位都从这里推导，
/// 不要在别处重复写数字
abstract final class TopicBottomBarMetrics {
  /// 栏内操作行高度
  static const double contentHeight = 56;

  /// 顶边进度线高度（收起后贴底的细线同高）
  static const double progressLineHeight = 2;

  /// 悬浮形态（非手机宽度）离底边的距离
  static const double floatingMargin = 16;
  static const double floatingRadius = 24;
  static RoundedSuperellipseBorder floatingShape(BuildContext context) =>
      RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(floatingRadius),
      );

  /// 悬浮于栏上方的按钮与栏之间的间距
  static const double gap = 12;

  /// 底栏、悬浮按钮列、收起后进度线共用的一套动效：同时长同曲线，
  /// 显隐时作为一个整体运动
  static const Duration motionDuration = Duration(milliseconds: 220);
  static const Curve motionCurve = Curves.easeOutCubic;

  /// 非手机宽度用悬浮卡片形态，宽度跟随帖子列
  static bool isFloating(BuildContext context) => !Responsive.isMobile(context);

  /// 栏展开时自底边起占用的高度（含安全区）
  static double occupiedHeight(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final bar = progressLineHeight + contentHeight;
    return isFloating(context)
        ? bar + bottomPadding + floatingMargin
        : bar + bottomPadding;
  }

  /// 栏收起时，悬浮按钮离底边的基准高度
  static double collapsedBase(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + floatingMargin;
}

/// 回复入口的形态，由登录态与 `details.can_create_post` 推导
enum TopicReplyEntryState {
  reply,
  replyPrivateMessage,
  login,
  closed,
  noPermission;

  bool get interactive =>
      this == reply || this == replyPrivateMessage || this == login;
}

/// 话题详情页底部操作栏
///
/// 左侧回复入口，右侧楼层计数 / 书签 / 筛选，顶边是阅读进度线。
/// 整条栏是手势面（见 [TopicBarGestures]）：横向拖动定位楼层、上滑与
/// 长按菜单触发可配置动作。
class TopicBottomBar extends ConsumerStatefulWidget {
  final ValueListenable<int> streamIndexListenable;
  final ValueListenable<double>? readingPositionListenable;
  final int totalCount;
  final TopicReplyEntryState replyEntryState;
  final ValueListenable<String?>? replyDraftListenable;
  final VoidCallback onReplyEntryTap;
  final VoidCallback onOpenTimeline;
  final bool bookmarked;
  final VoidCallback onBookmark;
  final ValueChanged<ProgressGestureAction> onGestureAction;
  final ValueChanged<int> onScrubCommit;
  final TopicPositionInfoSource? infoSource;

  final VoidCallback? onScrubStart;
  final TopicFilterControls filter;

  /// 回复入口胶囊的 key：快捷回复面板从它的位置与外形长出
  final GlobalKey? replyEntryKey;

  /// 快捷回复面板在屏上时隐藏回复入口胶囊（面板正是从它变形出来的）
  final ValueListenable<bool>? replyEntryHiddenListenable;

  const TopicBottomBar({
    super.key,
    required this.streamIndexListenable,
    this.readingPositionListenable,
    required this.totalCount,
    required this.replyEntryState,
    this.replyDraftListenable,
    required this.onReplyEntryTap,
    required this.onOpenTimeline,
    required this.bookmarked,
    required this.onBookmark,
    required this.onGestureAction,
    required this.onScrubCommit,
    this.infoSource,
    this.onScrubStart,
    required this.filter,
    this.replyEntryKey,
    this.replyEntryHiddenListenable,
  });

  @override
  ConsumerState<TopicBottomBar> createState() => _TopicBottomBarState();
}

class _TopicBottomBarState extends ConsumerState<TopicBottomBar> {
  /// 拖动定位中的目标楼层，供栏内楼层计数预览。
  final ValueNotifier<int?> _scrubIndex = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _scrubIndex.dispose();
    super.dispose();
  }

  static const double _horizontalPadding = 12;
  static const double _counterGap = 4;

  /// 紧凑图标按钮的点按尺寸（VisualDensity.compact 下 48 → 40）
  static const double _compactButtonExtent = 40;

  /// 楼层计数的宽度只随「总楼数、首末日期、字号」变化，测一次缓存
  ({Object key, double full, double compact})? _counterCache;

  /// 计数区固定宽度：按本话题可能出现的最宽数字与日期测量，滚动中
  /// 不随楼层号位数抖动。只有当输入框会被挤到放不下提示文案时，才退到
  /// 只显示当前楼层号的紧凑形态（超大话题即如此）。
  ({double width, bool compact}) _counterLayout(
    BuildContext context,
    double rowWidth,
    int buttonCount,
  ) {
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final detail = widget.infoSource?.detail;
    final dates = [
      TimeUtils.formatSmartDate(detail?.createdAt),
      TimeUtils.formatSmartDate(widget.infoSource?.dateAt(widget.totalCount)),
      TimeUtils.formatSmartDate(DateTime.now()),
    ];
    final key = (widget.totalCount, dates, textScaler, theme.textTheme);
    var cache = _counterCache;
    if (cache == null || cache.key != key) {
      final total = widget.totalCount;
      final numberStyle = _FloorCounter.numberStyle(theme);
      final totalStyle = _FloorCounter.totalStyle(theme);
      final dateStyle = _FloorCounter.dateStyle(theme);
      double measure(InlineSpan span) {
        final painter = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      final numbers = measure(
        TextSpan(
          children: [
            TextSpan(text: '$total', style: numberStyle),
            TextSpan(text: ' / $total', style: totalStyle),
          ],
        ),
      );
      final current = measure(TextSpan(text: '$total', style: numberStyle));
      var date = 0.0;
      for (final text in dates) {
        if (text.isEmpty) continue;
        final w = measure(TextSpan(text: text, style: dateStyle));
        if (w > date) date = w;
      }
      const padding = _FloorCounter.horizontalPadding * 2;
      cache = (
        key: key,
        full: (numbers > date ? numbers : date) + padding,
        compact: (current > date ? current : date) + padding,
      );
      _counterCache = cache;
    }

    final available =
        rowWidth - _counterGap - buttonCount * _compactButtonExtent;
    final minEntry = TopicReplyEntry.naturalWidth(
      context,
      widget.replyEntryState,
    );
    final compact = available - cache.full < minEntry;
    return (width: compact ? cache.compact : cache.full, compact: compact);
  }

  /// 嵌套视图自有滚动体系，楼层进度对它无意义
  bool get _showsProgress => !widget.filter.isNestedMode;

  Widget _buildReplyEntry() {
    final entry = TopicReplyEntry(
      key: widget.replyEntryKey,
      state: widget.replyEntryState,
      draftListenable: widget.replyDraftListenable,
      onTap: widget.onReplyEntryTap,
    );
    final hidden = widget.replyEntryHiddenListenable;
    if (hidden == null) return entry;
    return ValueListenableBuilder<bool>(
      valueListenable: hidden,
      child: entry,
      builder: (context, isHidden, child) =>
          Opacity(opacity: isHidden ? 0 : 1, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final floating = TopicBottomBarMetrics.isFloating(context);
    final showBookmark = widget.replyEntryState != TopicReplyEntryState.login;
    final gestureBar =
        _showsProgress &&
        ref.watch(preferencesProvider.select((p) => p.progressGesturesEnabled));

    final row = SizedBox(
      height: TopicBottomBarMetrics.contentHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _TopicBottomBarState._horizontalPadding,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final buttonCount = (showBookmark ? 1 : 0) + 1;
            final counter = _showsProgress
                ? _counterLayout(context, constraints.maxWidth, buttonCount)
                : null;
            return Row(
              children: [
                Expanded(child: _buildReplyEntry()),
                const SizedBox(width: _counterGap),
                if (counter != null)
                  _FloorCounter(
                    width: counter.width,
                    compact: counter.compact,
                    streamIndexListenable: widget.streamIndexListenable,
                    scrubIndexListenable: _scrubIndex,
                    totalCount: widget.totalCount,
                    infoSource: widget.infoSource,
                    onTap: widget.onOpenTimeline,
                  ),
                // 未登录时书签无从保存
                if (showBookmark)
                  IconButton(
                    onPressed: widget.onBookmark,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Symbols.bookmark_rounded,
                      fill: widget.bookmarked ? 1 : 0,
                      color: widget.bookmarked
                          ? context.emphasis.selected
                          : null,
                    ),
                    tooltip: widget.bookmarked
                        ? context.l10n.topicDetail_editBookmark
                        : context.l10n.common_addBookmark,
                  ),
                TopicFilterButton(
                  controls: widget.filter,
                  openOnPress: !gestureBar,
                ),
              ],
            );
          },
        ),
      ),
    );

    final body = _showsProgress
        ? TopicBarGestures(
            onAction: widget.onGestureAction,
            streamIndexListenable: widget.streamIndexListenable,
            readingPositionListenable: widget.readingPositionListenable,
            totalCount: widget.totalCount,
            scrubIndexNotifier: _scrubIndex,
            onScrubCommit: widget.onScrubCommit,
            infoSource: widget.infoSource,
            onScrubStart: widget.onScrubStart,
            child: row,
          )
        : Padding(
            padding: const EdgeInsets.only(
              top: TopicBottomBarMetrics.progressLineHeight,
            ),
            child: row,
          );

    final Widget content = body;

    if (floating) {
      return Material(
        color: theme.colorScheme.surfaceContainer,
        shape: TopicBottomBarMetrics.floatingShape(context),
        clipBehavior: Clip.antiAlias,
        elevation: 3,
        shadowColor: Colors.black26,
        child: content,
      );
    }

    // 贴底形态属于「页面底」：有页面背景时画对齐的背景副本
    return PageBackdrop(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: content,
      ),
    );
  }
}

/// 回复入口：输入框形态的按钮，点按打开回复面板（或去登录）
class TopicReplyEntry extends StatelessWidget {
  const TopicReplyEntry({
    super.key,
    required this.state,
    required this.onTap,
    this.draftListenable,
  });

  final TopicReplyEntryState state;
  final VoidCallback onTap;

  /// 有未发出的草稿时，以「草稿 + 摘要」代替提示文案
  final ValueListenable<String?>? draftListenable;

  static const double _height = 40;
  static const double _horizontalPadding = 14;
  static const double _iconSize = 18;
  static const double _iconGap = 8;

  static (IconData, String) _content(
    BuildContext context,
    TopicReplyEntryState state,
  ) {
    final l10n = context.l10n;
    return switch (state) {
      TopicReplyEntryState.reply => (
        Symbols.edit_rounded,
        l10n.topicDetail_replyEntryHint,
      ),
      TopicReplyEntryState.replyPrivateMessage => (
        Symbols.edit_rounded,
        l10n.topicDetail_replyEntryPrivateHint,
      ),
      TopicReplyEntryState.login => (
        Symbols.login_rounded,
        l10n.topicDetail_replyEntryLogin,
      ),
      TopicReplyEntryState.closed => (
        Symbols.lock_rounded,
        l10n.topicDetail_replyEntryClosed,
      ),
      TopicReplyEntryState.noPermission => (
        Symbols.block_rounded,
        l10n.topicDetail_replyEntryNoPermission,
      ),
    };
  }

  static TextStyle? _textStyle(ThemeData theme) => theme.textTheme.bodyMedium;

  Widget _buildLabel(
    BuildContext context,
    ThemeData theme,
    String hint,
    Color foreground,
  ) {
    final style = _textStyle(theme)?.copyWith(color: foreground);
    Widget text(String? draft) => Text.rich(
      draft == null
          ? TextSpan(text: hint)
          : TextSpan(
              children: [
                TextSpan(
                  text: '${context.l10n.drafts_draft}  ',
                  style: TextStyle(
                    color: context.emphasis.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // 草稿是用户原文，短代码按站点规则判定（不用 inline）
                TextSpan(
                  style: TextStyle(color: theme.colorScheme.onSurface),
                  children: EmojiText.buildEmojiSpans(context, draft, style),
                ),
              ],
            ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    final listenable = draftListenable;
    // 草稿只对能回复的形态有意义
    if (listenable == null || !state.interactive) return text(null);
    return ValueListenableBuilder<String?>(
      valueListenable: listenable,
      builder: (context, draft, _) =>
          text(state == TopicReplyEntryState.login ? null : draft),
    );
  }

  /// 完整放下提示文案所需的宽度：楼层计数让位的依据
  static double naturalWidth(BuildContext context, TopicReplyEntryState state) {
    final (_, label) = _content(context, state);
    final painter = TextPainter(
      text: TextSpan(text: label, style: _textStyle(Theme.of(context))),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return _horizontalPadding * 2 + _iconSize + _iconGap + width;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label) = _content(context, state);
    final interactive = state.interactive;
    final foreground = interactive
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(context.shapes.radius(9999)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: interactive ? onTap : null,
        child: SizedBox(
          height: _height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
            child: Row(
              children: [
                Icon(icon, size: _iconSize, color: foreground),
                const SizedBox(width: _iconGap),
                Expanded(child: _buildLabel(context, theme, label, foreground)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 楼层计数：上行「12 / 345」，下行该位置的日期；点按打开时间线。
/// 拖动定位中显示目标楼层。宽度由调用方按话题测定后固定。
class _FloorCounter extends StatelessWidget {
  const _FloorCounter({
    required this.width,
    required this.compact,
    required this.streamIndexListenable,
    required this.scrubIndexListenable,
    required this.totalCount,
    required this.infoSource,
    required this.onTap,
  });

  final double width;

  /// 紧凑形态只显示当前楼层号，省去「/ 总数」
  final bool compact;
  final ValueListenable<int> streamIndexListenable;
  final ValueListenable<int?> scrubIndexListenable;
  final int totalCount;
  final TopicPositionInfoSource? infoSource;
  final VoidCallback onTap;

  static const double horizontalPadding = 6;
  static const _tabular = [FontFeature.tabularFigures()];

  static TextStyle? numberStyle(ThemeData theme) =>
      theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        fontFeatures: _tabular,
        height: 1.2,
      );

  static TextStyle? totalStyle(ThemeData theme) =>
      theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: _tabular,
        height: 1.2,
      );

  static TextStyle? dateStyle(ThemeData theme) => theme.textTheme.labelSmall
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.2);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: context.l10n.progressGesture_action_openTimeline,
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(12),
        ),
        child: SizedBox(
          width: width,
          height: 44,
          // 楼层号滚动中连续变化，独立图层避免与列表脏区互相放大
          child: RepaintBoundary(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                streamIndexListenable,
                scrubIndexListenable,
              ]),
              builder: (context, _) {
                final scrubbing = scrubIndexListenable.value != null;
                final index =
                    scrubIndexListenable.value ?? streamIndexListenable.value;
                final date = infoSource?.dateAt(index);
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$index',
                            style: numberStyle(theme)?.copyWith(
                              color: scrubbing
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          if (!compact)
                            TextSpan(
                              text: ' / $totalCount',
                              style: totalStyle(theme),
                            ),
                        ],
                      ),
                      maxLines: 1,
                    ),
                    if (date != null)
                      Text(
                        TimeUtils.formatSmartDate(date),
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: dateStyle(theme),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 已读色和未读色沿底栏顶边相接，底栏收起后沿页面底边显示。
class TopicProgressLine extends StatelessWidget {
  const TopicProgressLine({
    super.key,
    required this.streamIndexListenable,
    this.readingPositionListenable,
    required this.totalCount,
    this.floatingEdge,
  });

  final ValueListenable<int> streamIndexListenable;
  final ValueListenable<double>? readingPositionListenable;
  final int totalCount;
  final TopicFloatingBarEdge? floatingEdge;

  @override
  Widget build(BuildContext context) {
    final reading = readingPositionListenable;
    final progress = reading == null
        ? null
        : Animation<double>.fromValueListenable(
            reading,
            transformer: (value) => TopicProgressTrack.readingFraction(
              streamIndexListenable.value,
              totalCount,
              value,
            ),
          );
    return SizedBox(
      height:
          floatingEdge?.size.height ?? TopicBottomBarMetrics.progressLineHeight,
      child: ValueListenableBuilder<int>(
        valueListenable: streamIndexListenable,
        builder: (context, index, _) => TopicProgressTrack(
          surface: floatingEdge != null
              ? TopicProgressSurface.floating
              : TopicProgressSurface.docked,
          floatingEdge: floatingEdge,
          progress: TopicProgressTrack.fraction(index, totalCount),
          readingProgress: progress,
        ),
      ),
    );
  }
}
