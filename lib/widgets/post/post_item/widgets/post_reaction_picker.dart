import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';

String _getEmojiUrl(String emojiName) {
  return EmojiHandler().getEmojiUrl(emojiName);
}

// ============================== 布局常量 ==============================

const double _kItemSize = 40.0;
const double _kIconSize = 26.0;
const double _kItemSpacing = 1.0;
const double _kPadding = 4.0;
const int _kCrossAxisCount = 5;
const double _kHighlightScale = 1.35;

const Duration _kEnterDuration = Duration(milliseconds: 180);
const Duration _kExitDuration = Duration(milliseconds: 160);
const Duration _kDesktopHoverLeaveDelay = Duration(milliseconds: 120);

/// 移动端按下后等待多久才真正启动 picker 衍生动画。
/// 这段时间内 picker 完全不存在(Timer 还在排队,Overlay 还没插入),
/// 用户在此期间抬手 = pure tap,toggleLike 正常触发,无任何视觉残留。
/// 超过这段时间仍按住才进入"长按意图",启动 picker 衍生。
const Duration kReactionPickerOpenDelay = Duration(milliseconds: 80);

/// 长按手势识别阈值:必须 ≥ kReactionPickerOpenDelay + _kEnterDuration,
/// 保证 onLongPressStart 触发时 picker 动画已完整跑完,haptic 与视觉完成同时发生
const Duration kReactionPickerLongPressDuration =
    Duration(milliseconds: 260);

// ============================== 控制器 ==============================

/// picker 的工作模式：
/// - [touch]：移动端长按手势驱动；动画完整跑完 180ms 才算"展开完成"
/// - [desktop]：桌面端 hover 触发；按下即直接展开
enum ReactionPickerMode { touch, desktop }

/// 表情选择器控制器，由触发入口（PostActionBar）持有，贯穿按下→展开→拖动→抬起整个生命周期
class ReactionPickerController {
  ReactionPickerController({
    required this.vsync,
    required this.onReactionSelected,
  });

  final TickerProvider vsync;
  final void Function(String reactionId) onReactionSelected;

  // 用普通字段 + 显式 init,而不是 `late final ... = AnimationController(...)`。
  // 后者会在 dispose 阶段被首次访问时触发 lazy init,这时 State 已 deactivated,
  // AnimationController 构造函数走 TickerProviderStateMixin.createTicker →
  // 查 TickerMode 这一 inherited widget,因为 element 已 inactive,抛
  // "Looking up a deactivated widget's ancestor is unsafe"。
  AnimationController? _animation;
  AnimationController get animation =>
      _animation ??= AnimationController(
        vsync: vsync,
        duration: _kEnterDuration,
        reverseDuration: _kExitDuration,
      );

  OverlayEntry? _entry;
  _OverlayBinding? _binding;
  Timer? _desktopLeaveTimer;
  bool _closing = false;
  bool _disposed = false;

  /// 监听祖先 Scrollable 的位置变化，滚动时立刻关闭 picker
  /// （否则桌面端鼠标不动、列表被滚动后 picker 会"飘"在原地）
  final List<ScrollPosition> _watchedPositions = [];

  /// 监听屏幕尺寸变化(旋转/键盘弹起)和 App lifecycle(失焦/后台),
  /// 任一发生都立即关闭 picker,避免 geometry 错位或 picker 残留
  _ReactionPickerLifecycleObserver? _lifecycleObserver;

  // 上一次启动时计算好的几何数据
  Rect _buttonRect = Rect.zero;
  double _pickerLeft = 0;
  double _pickerTop = 0;
  double _pickerWidth = 0;
  double _pickerHeight = 0;
  Alignment _transformAlignment = Alignment.center;
  List<String> _reactions = const [];
  PostReaction? _currentUserReaction;
  ThemeData? _theme;
  ReactionPickerMode _mode = ReactionPickerMode.touch;

  // 当前 picker rect、item rect、highlight
  Rect get pickerRect =>
      Rect.fromLTWH(_pickerLeft, _pickerTop, _pickerWidth, _pickerHeight);
  Rect get buttonRect => _buttonRect;
  Alignment get transformAlignment => _transformAlignment;
  List<String> get reactions => _reactions;
  PostReaction? get currentUserReaction => _currentUserReaction;
  ThemeData? get theme => _theme;
  ReactionPickerMode get mode => _mode;

  int? _highlightIndex;
  int? get highlightIndex => _highlightIndex;

  /// 是否处于"选择模式"（移动端 = 长按阈值已达成；桌面端 = 一直为 true）
  bool _inSelectionMode = false;
  bool get inSelectionMode => _inSelectionMode;

  /// 移动端长按松手后停驻，允许用户抬起手指后再点击选择。
  bool _touchPinned = false;
  bool get touchPinned => _touchPinned;

  bool get isOpen => _entry != null && !_closing;
  bool get isClosing => _closing;

  /// 打开 picker。计算几何、插入 OverlayEntry、启动正向动画
  void open({
    required BuildContext context,
    required Rect buttonRect,
    required List<String> reactions,
    required PostReaction? currentUserReaction,
    required ThemeData theme,
    required ReactionPickerMode mode,
  }) {
    if (_disposed) return;
    if (reactions.isEmpty) return;

    // 如果正在收回，直接复用：取消收回，重新正向播放
    if (_entry != null && _closing) {
      _closing = false;
      animation.forward();
      return;
    }
    if (_entry != null) return;

    _buttonRect = buttonRect;
    _reactions = reactions;
    _currentUserReaction = currentUserReaction;
    _theme = theme;
    _mode = mode;
    _highlightIndex = null;
    _inSelectionMode = mode == ReactionPickerMode.desktop;
    _touchPinned = false;

    _computeGeometry(context);

    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(builder: (_) {
      return _ReactionPickerOverlay(
        controller: this,
        onBindingReady: (b) => _binding = b,
      );
    });
    overlay.insert(_entry!);

    _attachScrollListeners(context);
    _attachLifecycleObserver();

    animation.forward(from: 0);
  }

  /// 沿 context 向上找所有 Scrollable，订阅其 position 变化
  void _attachScrollListeners(BuildContext context) {
    _detachScrollListeners();
    // 顺着 context 链找祖先 Scrollable；可能嵌套多层（外层主滚动 + 内层列表）
    BuildContext? ctx = context;
    while (ctx != null) {
      final state = Scrollable.maybeOf(ctx);
      if (state == null) break;
      final position = state.position;
      position.isScrollingNotifier.addListener(_onScrollingChanged);
      _watchedPositions.add(position);
      ctx = state.context;
    }
  }

  void _detachScrollListeners() {
    for (final p in _watchedPositions) {
      p.isScrollingNotifier.removeListener(_onScrollingChanged);
    }
    _watchedPositions.clear();
  }

  /// 注册屏幕指标 / App 生命周期监听:
  /// - didChangeMetrics: 屏幕旋转、键盘弹起 → 几何错位 → 关闭
  /// - didChangeAppLifecycleState: 失焦/后台 → picker 残留 → 关闭
  void _attachLifecycleObserver() {
    _detachLifecycleObserver();
    _lifecycleObserver = _ReactionPickerLifecycleObserver(onClose: close);
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
  }

  void _detachLifecycleObserver() {
    final obs = _lifecycleObserver;
    if (obs != null) {
      WidgetsBinding.instance.removeObserver(obs);
      _lifecycleObserver = null;
    }
  }

  void _onScrollingChanged() {
    // 任一祖先 Scrollable 开始滚动 → 立即关闭，避免 picker 飘在原地
    for (final p in _watchedPositions) {
      if (p.isScrollingNotifier.value) {
        close();
        return;
      }
    }
  }

  void _computeGeometry(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final screenHeight = mediaQuery.size.height;
    final padding = mediaQuery.padding;

    final count = _reactions.length;
    final cols = count < _kCrossAxisCount ? count : _kCrossAxisCount;
    final rows = (count / _kCrossAxisCount).ceil();

    _pickerWidth =
        (_kItemSize * cols) + (_kItemSpacing * (cols - 1)) + (_kPadding * 2) + 4.0;
    _pickerHeight =
        (_kItemSize * rows) + (_kItemSpacing * (rows - 1)) + (_kPadding * 2);

    _pickerLeft =
        (_buttonRect.left + _buttonRect.width / 2) - (_pickerWidth / 2);
    if (_pickerLeft < 16) _pickerLeft = 16;
    if (_pickerLeft + _pickerWidth > screenWidth - 16) {
      _pickerLeft = screenWidth - _pickerWidth - 16;
    }

    // 默认气泡在按钮上方，预留 12px 间隙
    bool isAbove = true;
    _pickerTop = _buttonRect.top - _pickerHeight - 12;
    if (_pickerTop < padding.top + 8) {
      _pickerTop = _buttonRect.bottom + 12;
      isAbove = false;
    }
    // 防止超出屏幕底
    if (_pickerTop + _pickerHeight > screenHeight - padding.bottom - 8) {
      _pickerTop = screenHeight - padding.bottom - 8 - _pickerHeight;
    }

    final buttonCenterX = _buttonRect.left + _buttonRect.width / 2;
    final relativeX = (buttonCenterX - _pickerLeft) / _pickerWidth;
    final alignmentX = relativeX * 2 - 1;
    final alignmentY = isAbove ? 1.0 : -1.0;
    _transformAlignment = Alignment(alignmentX, alignmentY);
  }

  /// 长按阈值达成 / 桌面 hover 触发后进入"选择模式"，允许更新 highlight
  void enterSelectionMode() {
    if (_disposed || !isOpen) return;
    if (_inSelectionMode) return;
    _touchPinned = false;
    _inSelectionMode = true;
  }

  /// 移动端长按已展开但没有滑中表情时，让 picker 留在屏幕上。
  /// 停驻后 picker 自己接收点击，空白处点击关闭。
  void pinForTouchSelection() {
    if (_disposed || !isOpen) return;
    if (_mode != ReactionPickerMode.touch) return;
    _highlightIndex = null;
    _inSelectionMode = false;
    _touchPinned = true;
    _entry?.markNeedsBuild();
  }

  /// 根据指针的全局坐标更新 highlight
  void updateHighlight(Offset globalPos) {
    if (_disposed || !isOpen) return;
    if (!_inSelectionMode) return;
    final rects = _binding?.itemRects;
    if (rects == null || rects.isEmpty) return;

    int? newIndex;
    for (int i = 0; i < rects.length; i++) {
      final r = rects[i];
      if (r == null) continue;
      if (r.inflate(4).contains(globalPos)) {
        newIndex = i;
        break;
      }
    }

    if (newIndex != _highlightIndex) {
      _highlightIndex = newIndex;
      if (newIndex != null) {
        HapticFeedback.selectionClick();
      }
      _entry?.markNeedsBuild();
    }
  }

  /// 提交选中（如果有 highlight）
  void commitSelection() {
    if (_disposed) return;
    final idx = _highlightIndex;
    if (idx != null && idx >= 0 && idx < _reactions.length) {
      HapticFeedback.lightImpact();
      onReactionSelected(_reactions[idx]);
    }
    close();
  }

  /// 直接选中指定 id（桌面端点击 emoji 用）
  void selectReaction(String id) {
    if (_disposed) return;
    HapticFeedback.lightImpact();
    onReactionSelected(id);
    close();
  }

  /// 关闭 picker：反向播放动画，结束后真正 dispose entry
  void close() {
    if (_disposed) return;
    if (_entry == null || _closing) return;
    _closing = true;
    _highlightIndex = null;
    _touchPinned = false;
    _desktopLeaveTimer?.cancel();
    _desktopLeaveTimer = null;
    animation.reverse().whenCompleteOrCancel(_disposeEntryIfNeeded);
  }

  void _disposeEntryIfNeeded() {
    if (!_closing) return;
    _entry?.remove();
    _entry = null;
    _binding = null;
    _closing = false;
    _inSelectionMode = false;
    _highlightIndex = null;
    _touchPinned = false;
    _detachScrollListeners();
    _detachLifecycleObserver();
  }

  // ============================== 桌面端 hover 安全区 ==============================

  /// 桌面端鼠标 hover 进入 picker 或按钮区域：取消"延迟关闭"定时器
  void onDesktopHoverEnterSafeZone() {
    _desktopLeaveTimer?.cancel();
    _desktopLeaveTimer = null;
  }

  /// 桌面端鼠标离开安全区：300ms 后自动关闭
  void onDesktopHoverLeaveSafeZone() {
    if (!isOpen || _mode != ReactionPickerMode.desktop) return;
    _desktopLeaveTimer?.cancel();
    _desktopLeaveTimer = Timer(_kDesktopHoverLeaveDelay, close);
  }

  /// 鼠标位置变化：判断是否在安全区内，并相应地启动/取消延迟关闭
  void onDesktopPointerHover(Offset globalPos) {
    if (!isOpen || _mode != ReactionPickerMode.desktop) return;
    final inSafe =
        pickerRect.inflate(8).contains(globalPos) || _buttonRect.contains(globalPos);
    if (inSafe) {
      onDesktopHoverEnterSafeZone();
      updateHighlight(globalPos);
    } else {
      onDesktopHoverLeaveSafeZone();
    }
  }

  // ============================== Item rect 上报 ==============================

  /// item widget build 完毕后上报自己的全局 Rect
  void reportItemRect(int index, Rect rect) {
    _binding?.reportItemRect(index, rect);
  }

  // ============================== 生命周期 ==============================

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _desktopLeaveTimer?.cancel();
    _detachScrollListeners();
    _detachLifecycleObserver();
    _entry?.remove();
    _entry = null;
    _binding = null;
    // 仅在曾经触发过动画时 dispose,避免 dispose 流程中首次 lazy init
    _animation?.dispose();
  }
}

/// 屏幕指标 / App 生命周期变化时关闭 picker。
/// 由 [ReactionPickerController] 在 picker open 期间注册,close/dispose 时移除。
class _ReactionPickerLifecycleObserver extends WidgetsBindingObserver {
  _ReactionPickerLifecycleObserver({required this.onClose});

  final VoidCallback onClose;

  @override
  void didChangeMetrics() => onClose();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) onClose();
  }
}

// ============================== Overlay binding ==============================

/// Overlay state 暴露给 controller 的回调接口
class _OverlayBinding {
  _OverlayBinding({
    required this.itemRects,
    required this.reportItemRect,
  });

  final List<Rect?> itemRects;
  final void Function(int index, Rect rect) reportItemRect;
}

// ============================== Overlay widget ==============================

class _ReactionPickerOverlay extends StatefulWidget {
  const _ReactionPickerOverlay({
    required this.controller,
    required this.onBindingReady,
  });

  final ReactionPickerController controller;
  final void Function(_OverlayBinding) onBindingReady;

  @override
  State<_ReactionPickerOverlay> createState() => _ReactionPickerOverlayState();
}

class _ReactionPickerOverlayState extends State<_ReactionPickerOverlay> {
  late final List<Rect?> _itemRects =
      List<Rect?>.filled(widget.controller.reactions.length, null);

  @override
  void initState() {
    super.initState();
    widget.onBindingReady(
      _OverlayBinding(
        itemRects: _itemRects,
        reportItemRect: _reportItemRect,
      ),
    );
  }

  void _reportItemRect(int index, Rect rect) {
    if (index < 0 || index >= _itemRects.length) return;
    // 动画期间 rect 不稳定，只在接近完全展开时接受写入
    if (widget.controller.animation.value < 0.95) return;
    _itemRects[index] = rect;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final theme = ctrl.theme;
    if (theme == null) return const SizedBox.shrink();

    return Stack(
      children: [
        // 全屏点击层：桌面端和移动端停驻后用于点击空白处关闭。
        if (ctrl.mode == ReactionPickerMode.desktop || ctrl.touchPinned)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: ctrl.close,
              child: ctrl.mode == ReactionPickerMode.desktop
                  ? Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerHover: (e) =>
                          ctrl.onDesktopPointerHover(e.position),
                      onPointerMove: (e) =>
                          ctrl.onDesktopPointerHover(e.position),
                      child: const SizedBox.expand(),
                    )
                  : const SizedBox.expand(),
            ),
          ),

        // picker 主体
        AnimatedBuilder(
          animation: ctrl.animation,
          builder: (context, _) {
            // 入场和收回都用线性曲线：scale 完全跟随长按时长 / 抬手后剩余时间。
            // 用户中途抬手时反向播放从当前 value 接着走，体感上"按多深、收多深"。
            final t = ctrl.animation.value;
            final scale = t.clamp(0.0, 1.0);
            final opacity = t.clamp(0.0, 1.0);

            return Positioned(
              left: ctrl.pickerRect.left,
              top: ctrl.pickerRect.top,
              child: IgnorePointer(
                // 移动端长按拖选时：picker 不接收指针事件，所有手势走父层 RawGestureDetector。
                // 移动端停驻/桌面端：picker 需要接收 tap，IgnorePointer 关闭。
                ignoring:
                    ctrl.mode == ReactionPickerMode.touch && !ctrl.touchPinned,
                child: Transform.scale(
                  scale: scale,
                  alignment: ctrl.transformAlignment,
                  child: Opacity(
                    opacity: opacity,
                    child: _buildPickerBody(theme),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildPickerBody(ThemeData theme) {
    final ctrl = widget.controller;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: ctrl.pickerRect.width,
        height: ctrl.pickerRect.height,
        padding: const EdgeInsets.all(_kPadding),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 16,
              spreadRadius: 2,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
        child: Wrap(
          spacing: _kItemSpacing,
          runSpacing: _kItemSpacing,
          alignment: WrapAlignment.center,
          children: [
            for (int i = 0; i < ctrl.reactions.length; i++)
              _ReactionItem(
                index: i,
                reactionId: ctrl.reactions[i],
                isCurrent: ctrl.currentUserReaction?.id == ctrl.reactions[i],
                isHighlighted: ctrl.highlightIndex == i,
                onTap:
                    (ctrl.mode == ReactionPickerMode.desktop ||
                        ctrl.touchPinned)
                    ? () => ctrl.selectReaction(ctrl.reactions[i])
                    : null,
                onRectReported: (r) => _reportItemRect(i, r),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================== 单项 ==============================

class _ReactionItem extends StatefulWidget {
  const _ReactionItem({
    required this.index,
    required this.reactionId,
    required this.isCurrent,
    required this.isHighlighted,
    required this.onTap,
    required this.onRectReported,
  });

  final int index;
  final String reactionId;
  final bool isCurrent;
  final bool isHighlighted;
  final VoidCallback? onTap;
  final void Function(Rect rect) onRectReported;

  @override
  State<_ReactionItem> createState() => _ReactionItemState();
}

class _ReactionItemState extends State<_ReactionItem> {
  final GlobalKey _key = GlobalKey();

  void _reportRect() {
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    widget.onRectReported(topLeft & box.size);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportRect());
  }

  @override
  void didUpdateWidget(covariant _ReactionItem old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportRect());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = widget.isHighlighted ? _kHighlightScale : 1.0;

    Widget content = Container(
      key: _key,
      width: _kItemSize,
      height: _kItemSize,
      decoration: BoxDecoration(
        color: widget.isCurrent
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Image(
          image: emojiImageProvider(_getEmojiUrl(widget.reactionId)),
          width: _kIconSize,
          height: _kIconSize,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.emoji_emotions_outlined, size: 24),
        ),
      ),
    );

    if (widget.onTap != null) {
      content = GestureDetector(onTap: widget.onTap, child: content);
    }

    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutBack,
      child: content,
    );
  }
}

// ============================== 桌面端兼容入口（已废弃） ==============================
//
// 旧版 `PostReactionPicker.show` 已被移除。
// 调用方应使用 [ReactionPickerController] + [RawGestureDetector] 模式，
// 由触发入口（如 [PostActionBar]）持有 controller，移动端走长按驱动、
// 桌面端走 hover 驱动，共用同一套 overlay 与选择逻辑。
