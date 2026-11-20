import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../utils/responsive.dart';
import '../controllers/topic_position_info.dart';
import 'topic_bottom_bar.dart';
import 'topic_filter_controls.dart';
import '../controllers/topic_reply_session.dart';

/// 话题详情页浮层
/// 包含底部操作栏、收起后的贴底进度线、回顶按钮与底栏手势的首次引导
///
/// 滚动中高频变化的状态一律走 ValueListenable 细粒度下沉,不要提升为
/// 本组件的构造参数(那会整棵重建底栏,实测单次 6~7ms):
/// - 整数楼层更新计数，楼内的连续阅读位置只更新进度线
/// - 底栏显隐([showBottomBarListenable],滚动方向切换即翻转)/ 回顶显隐
///   ([showBackToTopListenable])→ 只重建定位包装,内容经 VLB child 缓存
///   整棵短路
class TopicDetailOverlay extends ConsumerStatefulWidget {
  final ValueListenable<bool> showBottomBarListenable;
  final ValueListenable<bool> showBackToTopListenable;
  final ValueListenable<int> streamIndexListenable;
  final ValueListenable<double>? readingPositionListenable;
  final int totalCount;

  /// 当前加载窗口之前是否还有楼层：此时已加载内容的顶并非话题的顶
  final bool hasMoreBefore;
  final TopicReplyEntryState replyEntryState;

  /// 本话题未发出的回复草稿摘要（null = 无草稿）
  final ValueListenable<String?>? replyDraftListenable;
  final VoidCallback onReplyEntryTap;
  final VoidCallback onScrollToTop;

  /// 目录按钮（窄屏、有目录时由页面提供）与其显隐
  final Widget? tocButton;
  final ValueListenable<bool>? tocVisibleListenable;
  final VoidCallback onOpenTimeline;
  final bool bookmarked;
  final VoidCallback onBookmark;
  final ValueChanged<ProgressGestureAction> onGestureAction;
  final ValueChanged<int> onScrubCommit;
  final TopicPositionInfoSource? infoSource;

  final TopicFilterControls filter;

  /// 快捷回复会话（null 时底栏回复入口走完整编辑器）
  final TopicReplySession? replySession;

  /// 底栏回复入口胶囊的 key
  final GlobalKey replyEntryKey;

  const TopicDetailOverlay({
    super.key,
    required this.showBottomBarListenable,
    required this.showBackToTopListenable,
    required this.streamIndexListenable,
    this.readingPositionListenable,
    required this.totalCount,
    required this.hasMoreBefore,
    required this.replyEntryState,
    this.replyDraftListenable,
    required this.onReplyEntryTap,
    required this.onScrollToTop,
    this.tocButton,
    this.tocVisibleListenable,
    required this.onOpenTimeline,
    required this.bookmarked,
    required this.onBookmark,
    required this.onGestureAction,
    required this.onScrubCommit,
    this.infoSource,
    required this.filter,
    this.replySession,
    required this.replyEntryKey,
  });

  /// 回顶按钮显隐：随底栏一起出现（往回滑表示想回去），且不在顶部
  static bool backToTopVisible({
    required bool showBottomBar,
    required bool awayFromLoadedTop,
    required bool hasMoreBefore,
  }) => showBottomBar && (awayFromLoadedTop || hasMoreBefore);

  /// 悬浮按钮（回顶、目录）所在列的底边：栏展开时在栏上方，收起时贴底
  static double floatingButtonBase(BuildContext context, bool showBottomBar) =>
      showBottomBar
      ? TopicBottomBarMetrics.occupiedHeight(context) +
            TopicBottomBarMetrics.gap
      : TopicBottomBarMetrics.collapsedBase(context);

  /// 悬浮于栏上方的小号按钮（回顶、目录）尺寸
  static const double smallFabSize = 40;

  /// 悬浮于栏上方的元素与栏同宽对齐（贴底形态即屏幕两侧留白）
  static Widget alignWithBar(BuildContext context, Widget child) {
    final floating = TopicBottomBarMetrics.isFloating(context);
    final inset = floating ? TopicBottomBarMetrics.floatingMargin : 16.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: floating ? Breakpoints.maxContentWidth : double.infinity,
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  ConsumerState<TopicDetailOverlay> createState() => _TopicDetailOverlayState();
}

class _TopicDetailOverlayState extends ConsumerState<TopicDetailOverlay> {
  /// 底栏手势引导已展示次数；达到上限或用户关闭 / 用过拖动后不再出现
  static const String _hintCountKey = 'topic_bar_gesture_hint_count';
  static const int _hintMaxShows = 1;
  static const Duration _hintAutoHide = Duration(seconds: 6);

  static const Duration _motion = TopicBottomBarMetrics.motionDuration;

  final ValueNotifier<bool> _hintVisible = ValueNotifier<bool>(false);
  bool _hintChecked = false;

  /// 底栏回复入口胶囊：快捷回复面板与完整编辑器的变形起点（页面持有，
  /// 直接打开完整编辑器时也从它长出）
  GlobalKey get _replyEntryKey => widget.replyEntryKey;
  Timer? _hintTimer;

  @override
  void dispose() {
    _hintTimer?.cancel();
    _hintVisible.dispose();
    super.dispose();
  }

  void _maybeShowHint() {
    if (!mounted ||
        _hintChecked ||
        widget.filter.isNestedMode ||
        _composing ||
        widget.totalCount <= 1 ||
        !widget.showBottomBarListenable.value) {
      return;
    }
    if (!ref.read(preferencesProvider).progressGesturesEnabled) return;
    _hintChecked = true;
    final prefs = ref.read(sharedPreferencesProvider);
    final count = prefs.getInt(_hintCountKey) ?? 0;
    if (count >= _hintMaxShows) return;
    prefs.setInt(_hintCountKey, count + 1);
    _hintVisible.value = true;
    _hintTimer = Timer(_hintAutoHide, () => _hintVisible.value = false);
  }

  /// 用户关闭引导或已经用过拖动定位：不再展示
  void _finishHint() {
    _hintChecked = true;
    _hintTimer?.cancel();
    if (_hintVisible.value) _hintVisible.value = false;
    final prefs = ref.read(sharedPreferencesProvider);
    if ((prefs.getInt(_hintCountKey) ?? 0) < _hintMaxShows) {
      prefs.setInt(_hintCountKey, _hintMaxShows);
    }
  }

  @override
  Widget build(BuildContext context) {
    final floating = TopicBottomBarMetrics.isFloating(context);

    final bar = TopicBottomBar(
      streamIndexListenable: widget.streamIndexListenable,
      readingPositionListenable: widget.readingPositionListenable,
      totalCount: widget.totalCount,
      replyEntryState: widget.replyEntryState,
      replyDraftListenable: widget.replyDraftListenable,
      onReplyEntryTap: widget.onReplyEntryTap,
      onOpenTimeline: widget.onOpenTimeline,
      bookmarked: widget.bookmarked,
      onBookmark: widget.onBookmark,
      onGestureAction: widget.onGestureAction,
      onScrubCommit: widget.onScrubCommit,
      infoSource: widget.infoSource,
      onScrubStart: _finishHint,
      filter: widget.filter,
      replyEntryKey: _replyEntryKey,
      replyEntryHiddenListenable: widget.replySession?.presentedNotifier,
    );

    final stack = Stack(
      children: [
        // 收起后贴底的细进度线（嵌套视图无楼层进度）
        if (!widget.filter.isNestedMode)
          ValueListenableBuilder<bool>(
            valueListenable: widget.showBottomBarListenable,
            child: IgnorePointer(
              child: TopicProgressLine(
                streamIndexListenable: widget.streamIndexListenable,
                readingPositionListenable: widget.readingPositionListenable,
                totalCount: widget.totalCount,
              ),
            ),
            builder: (context, showBottomBar, child) => Positioned(
              key: const ValueKey('collapsed_progress_line'),
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                duration: _motion,
                curve: TopicBottomBarMetrics.motionCurve,
                opacity: showBottomBar ? 0 : 1,
                child: child,
              ),
            ),
          ),
        // 底部操作栏
        ValueListenableBuilder<bool>(
          valueListenable: widget.showBottomBarListenable,
          child: floating ? _wrapFloating(bar) : bar,
          builder: (context, showBottomBar, child) => AnimatedPositioned(
            key: const ValueKey('bottom_bar'),
            duration: _motion,
            curve: TopicBottomBarMetrics.motionCurve,
            left: 0,
            right: 0,
            bottom: showBottomBar
                ? 0
                : -TopicBottomBarMetrics.occupiedHeight(context),
            child: child!,
          ),
        ),
        // 悬浮按钮列（目录、回顶）：整列随底栏一起移动；单个按钮出现 /
        // 消失时高度折叠，其余按钮同步让位，而不是各自跳位
        ListenableBuilder(
          listenable: Listenable.merge([
            widget.showBottomBarListenable,
            ?widget.replySession?.activeNotifier,
          ]),
          child: TopicDetailOverlay.alignWithBar(
            context,
            Align(
              alignment: Alignment.bottomRight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.tocButton != null &&
                      widget.tocVisibleListenable != null)
                    ValueListenableBuilder<bool>(
                      valueListenable: widget.tocVisibleListenable!,
                      child: widget.tocButton,
                      builder: (context, visible, child) =>
                          _FloatingButtonSlot(visible: visible, child: child!),
                    ),
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      widget.showBottomBarListenable,
                      widget.showBackToTopListenable,
                    ]),
                    child: FloatingActionButton.small(
                      heroTag: null,
                      onPressed: widget.onScrollToTop,
                      tooltip: context.l10n.topicDetail_scrollToTop,
                      child: const Icon(Symbols.vertical_align_top_rounded),
                    ),
                    builder: (context, child) => _FloatingButtonSlot(
                      visible: TopicDetailOverlay.backToTopVisible(
                        showBottomBar: widget.showBottomBarListenable.value,
                        awayFromLoadedTop: widget.showBackToTopListenable.value,
                        hasMoreBefore: widget.hasMoreBefore,
                      ),
                      child: child!,
                    ),
                  ),
                ],
              ),
            ),
          ),
          builder: (context, child) => AnimatedPositioned(
            key: const ValueKey('floating_buttons'),
            // 快捷回复展开时栏变高，按钮列让开（淡出），收起后回位
            duration: TopicBottomBarMetrics.motionDuration,
            curve: TopicBottomBarMetrics.motionCurve,
            left: 0,
            right: 0,
            // 列底边对齐栏顶（收起时对齐页面底部），按钮间距由各槽位自带
            bottom:
                TopicDetailOverlay.floatingButtonBase(
                  context,
                  widget.showBottomBarListenable.value,
                ) -
                TopicBottomBarMetrics.gap,
            child: IgnorePointer(
              ignoring: _composing,
              child: AnimatedOpacity(
                duration: _motion,
                curve: TopicBottomBarMetrics.motionCurve,
                opacity: _composing ? 0 : 1,
                child: child,
              ),
            ),
          ),
        ),
        // 底栏真正可见时才计入一次引导。
        if (!widget.filter.isNestedMode &&
            widget.totalCount > 1 &&
            ref.watch(
              preferencesProvider.select((p) => p.progressGesturesEnabled),
            ))
          ListenableBuilder(
            listenable: Listenable.merge([
              widget.showBottomBarListenable,
              _hintVisible,
              ?widget.replySession?.activeNotifier,
            ]),
            child: TopicDetailOverlay.alignWithBar(
              context,
              Center(child: _GestureHintBubble(onClose: _finishHint)),
            ),
            builder: (context, child) {
              if (!_hintChecked &&
                  widget.showBottomBarListenable.value &&
                  !_composing) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _maybeShowHint(),
                );
              }
              final visible =
                  _hintVisible.value &&
                  widget.showBottomBarListenable.value &&
                  !_composing;
              return Positioned(
                key: const ValueKey('bar_gesture_hint'),
                left: 0,
                right: 0,
                bottom:
                    TopicBottomBarMetrics.occupiedHeight(context) +
                    TopicBottomBarMetrics.gap,
                child: IgnorePointer(
                  ignoring: !visible,
                  child: AnimatedOpacity(
                    duration: _motion,
                    opacity: visible ? 1 : 0,
                    child: child,
                  ),
                ),
              );
            },
          ),
      ],
    );

    final session = widget.replySession;
    if (session == null) return stack;
    // 快捷回复展开时，返回键先收起它而不是离开话题
    return ValueListenableBuilder<bool>(
      valueListenable: session.activeNotifier,
      child: stack,
      builder: (context, active, child) => PopScope(
        canPop: !active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) session.close();
        },
        child: child!,
      ),
    );
  }

  bool get _composing => widget.replySession?.active ?? false;

  /// 悬浮形态：卡片宽度跟随帖子列，离底边留出安全区与边距
  Widget _wrapFloating(Widget bar) {
    return Padding(
      padding: EdgeInsets.only(
        left: TopicBottomBarMetrics.floatingMargin,
        right: TopicBottomBarMetrics.floatingMargin,
        bottom:
            MediaQuery.paddingOf(context).bottom +
            TopicBottomBarMetrics.floatingMargin,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: Breakpoints.maxContentWidth,
          ),
          child: bar,
        ),
      ),
    );
  }
}

class _GestureHintBubble extends StatelessWidget {
  const _GestureHintBubble({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onInverseSurface;
    return Material(
      color: theme.colorScheme.inverseSurface,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(16),
      ),
      elevation: 4,
      shadowColor: Colors.black26,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, top: 4, bottom: 4, right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.swap_horiz_rounded, size: 18, color: foreground),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                context.l10n.topicDetail_barGestureHint,
                style: theme.textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ),
            IconButton(
              onPressed: onClose,
              icon: Icon(Symbols.close_rounded, size: 18, color: foreground),
              tooltip: context.l10n.common_close,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

/// 悬浮按钮列里的一个槽位：显隐时缩放淡入淡出，并把自身高度（含与下方
/// 按钮的间距）折叠掉，让同列其余按钮同步滑动让位
class _FloatingButtonSlot extends StatelessWidget {
  const _FloatingButtonSlot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 1 : 0),
      duration: TopicBottomBarMetrics.motionDuration,
      curve: TopicBottomBarMetrics.motionCurve,
      child: Padding(
        padding: const EdgeInsets.only(bottom: TopicBottomBarMetrics.gap),
        child: child,
      ),
      // 不裁剪：按钮阴影要完整；折叠到 0 时内容已淡出
      builder: (context, v, child) => IgnorePointer(
        ignoring: !visible,
        // widthFactor 1：槽位宽度收缩到按钮本身，否则 Align 撑满整列、
        // 按钮会被居中到栏中间
        child: Align(
          widthFactor: 1,
          heightFactor: v,
          child: Opacity(
            opacity: v,
            child: Transform.scale(scale: 0.6 + 0.4 * v, child: child),
          ),
        ),
      ),
    );
  }
}
