import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';

String _getEmojiUrl(String emojiName) {
  return EmojiHandler().getEmojiUrl(emojiName);
}

// ============================== 布局常量 ==============================

const double _kItemSize = 44.0;
const double _kIconSize = 28.0;
const double _kItemSpacing = 4.0;
const double _kPadding = 8.0;
const int _kCrossAxisCount = 5;

/// 面板与按钮之间的间隙
const double _kButtonGap = 12.0;

/// 高亮项放大倍数、相邻项让位缩小倍数
const double _kHighlightScale = 1.25;
const double _kNeighborScale = 0.94;

/// 高亮项上浮距离:单行时上浮明显,多行时上浮会压到上一行,只轻轻抬一下
const double _kLiftSingleRow = 6.0;
const double _kLiftMultiRow = 2.0;

/// 名称气泡与面板边缘的间隙(需容纳高亮项放大 + 上浮后越出面板的部分)
const double _kTooltipGap = 14.0;

/// 手指拖离面板多远开始弱化、弱化到底(此时松手 = 取消)
const double _kDismissStartDistance = 28.0;
const double _kDismissFullDistance = 140.0;

const Duration _kEnterDuration = Duration(milliseconds: 240);
const Duration _kExitDuration = Duration(milliseconds: 160);
const Duration _kFlightDuration = Duration(milliseconds: 240);
const Duration _kHighlightDuration = Duration(milliseconds: 130);
const Duration _kDismissDuration = Duration(milliseconds: 120);
const Duration _kDesktopHoverLeaveDelay = Duration(milliseconds: 120);

/// 移动端长按手势识别阈值。picker 只在 onLongPressStart(长按在手势竞技场
/// 胜出)之后才插入 Overlay 并播放衍生动画:按下阶段什么都不做,滚动列表
/// 时无论起手多慢都不会闪出 picker。
///
/// 低于框架默认的 kLongPressTimeout(500ms)保持跟手,但也不宜太短:
/// 阈值内位移未超过 touch slop 的慢速滚动起手会被判成长按。
const Duration kReactionPickerLongPressDuration =
    Duration(milliseconds: 350);

// ============================== 控制器 ==============================

/// picker 的工作模式：
/// - [touch]：移动端长按手势驱动；长按识别成功后展开，拖动选择，松手即选
/// - [desktop]：桌面端 hover 触发；hover 高亮，点击选择
enum ReactionPickerMode { touch, desktop }

/// 选中后表情从面板槽位飞回按钮的一段飞行
class _Flight {
  const _Flight({
    required this.id,
    required this.from,
    required this.to,
    required this.startScale,
  });

  final String id;
  final Offset from;
  final Offset to;
  final double startScale;

  /// 二次贝塞尔:控制点抬高,轨迹带一点弧度而不是直线砸下去
  Offset at(double t) {
    final control = Offset.lerp(from, to, 0.5)! - const Offset(0, 24);
    final a = Offset.lerp(from, control, t)!;
    final b = Offset.lerp(control, to, t)!;
    return Offset.lerp(a, b, t)!;
  }
}

/// 表情选择器控制器，由触发入口（PostActionBar）持有，贯穿展开→拖动→抬起→飞回整个生命周期
class ReactionPickerController {
  ReactionPickerController({
    required this.vsync,
    required this.onReactionSelected,
  });

  final TickerProvider vsync;

  /// 选中的表情飞抵按钮时回调。调用方在此提交并做按钮弹跳,
  /// 表情落地的瞬间按钮换成新表情,视觉上是"它落进去了"。
  final void Function(String reactionId) onReactionSelected;

  // 用普通字段 + 显式 init,而不是 `late final ... = AnimationController(...)`。
  // 后者会在 dispose 阶段被首次访问时触发 lazy init,这时 State 已 deactivated,
  // AnimationController 构造函数走 TickerProviderStateMixin.createTicker →
  // 查 TickerMode 这一 inherited widget,因为 element 已 inactive,抛
  // "Looking up a deactivated widget's ancestor is unsafe"。
  AnimationController? _enter;

  /// 展开/收回主进度:面板形变与表情错峰弹出都由它驱动
  AnimationController get enter => _enter ??= AnimationController(
        vsync: vsync,
        duration: _kEnterDuration,
        reverseDuration: _kExitDuration,
      );

  CurvedAnimation? _morph;

  /// 面板形变进度:展开 easeOutCubic 干脆落定,收回 easeInCubic 被吸回去
  Animation<double> get morph => _morph ??= CurvedAnimation(
        parent: enter,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

  AnimationController? _flightAnim;
  AnimationController get flightAnim => _flightAnim ??= AnimationController(
        vsync: vsync,
        duration: _kFlightDuration,
      );

  OverlayEntry? _entry;
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
  Rect _pickerRect = Rect.zero;
  bool _isAbove = true;
  int _rows = 1;
  int _columns = 1;

  /// 每个表情槽位的最终全局矩形。由几何直接算出,不依赖布局后上报,
  /// 面板还在长的时候拖选就已经能命中。
  List<Rect> _itemRects = const [];

  /// 弹出次序:离按钮中心越近越先弹,像从按住的位置往外扩散
  List<int> _popRank = const [];

  List<String> _reactions = const [];
  PostReaction? _currentUserReaction;
  ThemeData? _theme;
  ReactionPickerMode _mode = ReactionPickerMode.touch;

  Rect get pickerRect => _pickerRect;
  Rect get buttonRect => _buttonRect;
  bool get isAbove => _isAbove;
  int get rows => _rows;
  int get columns => _columns;
  List<Rect> get itemRects => _itemRects;
  List<int> get popRank => _popRank;
  List<String> get reactions => _reactions;
  PostReaction? get currentUserReaction => _currentUserReaction;
  ThemeData? get theme => _theme;
  ReactionPickerMode get mode => _mode;

  int? _highlightIndex;
  int? get highlightIndex => _highlightIndex;

  /// 手指拖离面板的弱化程度 0..1:面板随之缩小变淡,到 1 时松手即取消
  double _dismissT = 0;
  double get dismissT => _dismissT;

  /// 移动端长按松手后停驻，允许用户抬起手指后再点击选择。
  bool _touchPinned = false;
  bool get touchPinned => _touchPinned;

  /// 高亮项始终向远离按钮的一侧浮起，面板翻到按钮下方时方向随之翻转。
  double get highlightLift =>
      (_rows == 1 ? _kLiftSingleRow : _kLiftMultiRow) * (_isAbove ? 1 : -1);

  _Flight? _flight;

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
    // 飞行中不重开:等表情落地、entry 清理完再说
    if (_flight != null) return;

    // 如果正在收回，直接复用：取消收回，重新正向播放
    if (_entry != null && _closing) {
      _closing = false;
      enter.forward();
      return;
    }
    if (_entry != null) return;

    _buttonRect = buttonRect;
    _reactions = reactions;
    _currentUserReaction = currentUserReaction;
    _theme = theme;
    _mode = mode;
    _highlightIndex = null;
    _dismissT = 0;
    _touchPinned = false;
    _flight = null;

    _computeGeometry(context);

    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (_) => _ReactionPickerOverlay(controller: this),
    );
    overlay.insert(_entry!);

    _attachScrollListeners(context);
    _attachLifecycleObserver();

    enter.forward(from: 0);
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
    final availableWidth = screenWidth - padding.horizontal - 32;
    final fittingColumns = math.max(
      1,
      ((availableWidth - _kPadding * 2 + _kItemSpacing) /
              (_kItemSize + _kItemSpacing))
          .floor(),
    );
    final cols = math.min(count, math.min(_kCrossAxisCount, fittingColumns));
    final rows = (count / cols).ceil();
    _rows = rows;
    _columns = cols;

    final width =
        (_kItemSize * cols) + (_kItemSpacing * (cols - 1)) + (_kPadding * 2);
    final height =
        (_kItemSize * rows) + (_kItemSpacing * (rows - 1)) + (_kPadding * 2);

    double left = _buttonRect.center.dx - width / 2;
    final minLeft = padding.left + 16;
    final maxLeft = math.max(minLeft, screenWidth - padding.right - width - 16);
    left = left.clamp(minLeft, maxLeft);

    // 默认面板在按钮上方；放不下则翻到下方
    _isAbove = true;
    double top = _buttonRect.top - height - _kButtonGap;
    final tooltipHeight = mediaQuery.textScaler.scale(12) * 1.2 + 10;
    if (top < padding.top + 12 + _kTooltipGap + tooltipHeight) {
      top = _buttonRect.bottom + _kButtonGap;
      _isAbove = false;
    }
    // 防止超出屏幕底
    if (top + height > screenHeight - padding.bottom - 8) {
      top = screenHeight - padding.bottom - 8 - height;
    }
    _pickerRect = Rect.fromLTWH(left, top, width, height);

    // 每个槽位的最终矩形;末行不满时居中(与原 Wrap 的 center 对齐一致)
    final step = _kItemSize + _kItemSpacing;
    final rects = List<Rect>.generate(count, (i) {
      final row = i ~/ cols;
      final col = i % cols;
      final inRow = math.min(count - row * cols, cols);
      final rowOffset = (cols - inRow) * step / 2;
      return Rect.fromLTWH(
        left + _kPadding + rowOffset + col * step,
        top + _kPadding + row * step,
        _kItemSize,
        _kItemSize,
      );
    });
    _itemRects = rects;

    // 弹出次序:按到按钮中心的距离排,rank[i] = 第 i 项第几个弹
    final origin = _buttonRect.center;
    final order = List<int>.generate(count, (i) => i)
      ..sort((a, b) {
        final da = (rects[a].center - origin).distanceSquared;
        final db = (rects[b].center - origin).distanceSquared;
        return da.compareTo(db);
      });
    final rank = List<int>.filled(count, 0);
    for (var r = 0; r < order.length; r++) {
      rank[order[r]] = r;
    }
    _popRank = rank;
  }

  /// 移动端长按已展开但没有滑中表情时，让 picker 留在屏幕上。
  /// 停驻后 picker 自己接收点击，空白处点击关闭。
  void pinForTouchSelection() {
    if (_disposed || !isOpen) return;
    if (_mode != ReactionPickerMode.touch) return;
    _highlightIndex = null;
    _dismissT = 0;
    _touchPinned = true;
    _entry?.markNeedsBuild();
  }

  /// 移动端松手:滑中表情即选;拖得太远即取消;否则停驻等点选
  void releaseTouch() {
    if (_disposed || !isOpen) return;
    if (_highlightIndex != null) {
      commitSelection();
    } else if (_dismissT >= 1) {
      close();
    } else {
      pinForTouchSelection();
    }
  }

  /// 根据指针的全局坐标更新 highlight 与拖离弱化（拖选 / 桌面 hover）；
  /// 停驻后改为点选，不再跟随指针
  void updateHighlight(Offset globalPos) {
    if (_disposed || !isOpen || _touchPinned || _flight != null) return;
    final rects = _itemRects;
    if (rects.isEmpty) return;

    int? newIndex;
    for (int i = 0; i < rects.length; i++) {
      if (rects[i].inflate(_kItemSpacing / 2).contains(globalPos)) {
        newIndex = i;
        break;
      }
    }

    // 拖离弱化只对触摸拖选有意义;桌面端离开安全区走延迟关闭。
    // 安全区 = 面板与按钮的并集:长按起手时手指还在按钮上,不算拖离
    double dismiss = 0;
    if (_mode == ReactionPickerMode.touch && newIndex == null) {
      final r = _pickerRect.expandToInclude(_buttonRect);
      final dx = math.max(math.max(r.left - globalPos.dx, globalPos.dx - r.right), 0.0);
      final dy = math.max(math.max(r.top - globalPos.dy, globalPos.dy - r.bottom), 0.0);
      final distance = math.sqrt(dx * dx + dy * dy);
      dismiss = ((distance - _kDismissStartDistance) /
              (_kDismissFullDistance - _kDismissStartDistance))
          .clamp(0.0, 1.0);
    }

    var changed = false;
    if (newIndex != _highlightIndex) {
      _highlightIndex = newIndex;
      if (newIndex != null) {
        HapticFeedback.selectionClick();
      }
      changed = true;
    }
    if (dismiss != _dismissT) {
      _dismissT = dismiss;
      changed = true;
    }
    if (changed) _entry?.markNeedsBuild();
  }

  /// 提交选中（如果有 highlight）
  void commitSelection() {
    if (_disposed) return;
    final idx = _highlightIndex;
    if (idx != null && idx >= 0 && idx < _reactions.length) {
      _startFlight(idx);
    } else {
      close();
    }
  }

  /// 直接选中指定 id（桌面端 / 停驻后点击 emoji 用）
  void selectReaction(String id) {
    if (_disposed) return;
    final idx = _reactions.indexOf(id);
    if (idx < 0) {
      close();
      return;
    }
    _startFlight(idx);
  }

  /// 选中的表情从槽位飞回按钮,面板同时收回;落地时才真正提交
  void _startFlight(int idx) {
    if (_flight != null) return;
    HapticFeedback.lightImpact();
    final wasHighlighted = _highlightIndex == idx;
    final center = Offset.lerp(
      _buttonRect.center,
      _itemRects[idx].center,
      morph.value,
    )!;
    final from = center - Offset(0, wasHighlighted ? highlightLift : 0);
    // like 图标在胶囊最右:右内边距 12 + 图标半径 10
    final to = Offset(_buttonRect.right - 22, _buttonRect.center.dy);
    _flight = _Flight(
      id: _reactions[idx],
      from: from,
      to: to,
      startScale: wasHighlighted ? _kHighlightScale : 1.0,
    );
    _highlightIndex = null;
    _dismissT = 0;
    _touchPinned = false;
    _desktopLeaveTimer?.cancel();
    _desktopLeaveTimer = null;
    _closing = true;
    enter.reverse().whenCompleteOrCancel(_disposeEntryIfNeeded);
    flightAnim.forward(from: 0).whenCompleteOrCancel(_onFlightDone);
  }

  void _onFlightDone() {
    if (_disposed) return;
    final f = _flight;
    _flight = null;
    if (f != null && flightAnim.value >= 1) {
      onReactionSelected(f.id);
    }
    _disposeEntryIfNeeded();
  }

  /// 关闭 picker：反向播放动画，结束后真正 dispose entry
  void close() {
    if (_disposed) return;
    if (_entry == null || _closing) return;
    _closing = true;
    _highlightIndex = null;
    _dismissT = 0;
    _touchPinned = false;
    _desktopLeaveTimer?.cancel();
    _desktopLeaveTimer = null;
    enter.reverse().whenCompleteOrCancel(_disposeEntryIfNeeded);
  }

  /// 收回动画与飞行都结束后才移除 entry
  void _disposeEntryIfNeeded() {
    if (_disposed || !_closing) return;
    if (enter.isAnimating || _flight != null) return;
    _entry?.remove();
    _entry = null;
    _closing = false;
    _highlightIndex = null;
    _dismissT = 0;
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

  /// 桌面端鼠标离开安全区：延迟后自动关闭
  void onDesktopHoverLeaveSafeZone() {
    if (!isOpen || _mode != ReactionPickerMode.desktop) return;
    _desktopLeaveTimer?.cancel();
    _desktopLeaveTimer = Timer(_kDesktopHoverLeaveDelay, close);
  }

  /// 鼠标位置变化：判断是否在安全区内，并相应地启动/取消延迟关闭
  void onDesktopPointerHover(Offset globalPos) {
    if (!isOpen || _mode != ReactionPickerMode.desktop) return;
    final inSafe = _pickerRect.inflate(8).contains(globalPos) ||
        _buttonRect.inflate(12).contains(globalPos);
    if (inSafe) {
      onDesktopHoverEnterSafeZone();
      updateHighlight(globalPos);
    } else {
      onDesktopHoverLeaveSafeZone();
    }
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
    _flight = null;
    // 仅在曾经触发过动画时 dispose,避免 dispose 流程中首次 lazy init
    _morph?.dispose();
    _enter?.dispose();
    _flightAnim?.dispose();
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

// ============================== Overlay widget ==============================

class _ReactionPickerOverlay extends StatefulWidget {
  const _ReactionPickerOverlay({required this.controller});

  final ReactionPickerController controller;

  @override
  State<_ReactionPickerOverlay> createState() => _ReactionPickerOverlayState();
}

class _ReactionPickerOverlayState extends State<_ReactionPickerOverlay> {
  /// 上一次高亮的标签与位置:高亮消失时气泡原地淡出,不会先跳空再消失
  String? _tooltipLabel;
  double _tooltipX = 0;

  ReactionPickerController get ctrl => widget.controller;

  late final Listenable _animations =
      Listenable.merge([ctrl.enter, ctrl.flightAnim]);

  bool get _interactive =>
      !ctrl.isClosing &&
      (ctrl.mode == ReactionPickerMode.desktop || ctrl.touchPinned);

  @override
  Widget build(BuildContext context) {
    final theme = ctrl.theme;
    if (theme == null) return const SizedBox.shrink();

    Widget body = Stack(
      // 动画层始终占满浮层；名称提示尚未出现时，不能被空占位压成零尺寸。
      fit: StackFit.expand,
      children: [
        // 全屏点击层：桌面端和移动端停驻后用于点击空白处关闭。
        if (_interactive)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: ctrl.close,
              child: const SizedBox.expand(),
            ),
          ),
        AnimatedBuilder(
          animation: _animations,
          builder: (context, _) => _buildAnimated(context, theme),
        ),
      ],
    );
    // 桌面端 hover 跟踪放在最外层:指针停在表情上时事件照样经过祖先,
    // 不会被表情自己的命中区挡掉
    if (ctrl.mode == ReactionPickerMode.desktop) {
      body = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (e) => ctrl.onDesktopPointerHover(e.position),
        onPointerMove: (e) => ctrl.onDesktopPointerHover(e.position),
        child: body,
      );
    }
    return body;
  }

  Widget _buildAnimated(BuildContext context, ThemeData theme) {
    final t = ctrl.enter.value;
    final m = ctrl.morph.value;
    final closing = ctrl.isClosing;
    final highlight = ctrl.highlightIndex;
    final lift = ctrl.highlightLift;
    final count = ctrl.reactions.length;

    // 面板:从按钮胶囊形变到面板胶囊,起点与按钮重合所以先透明再显形
    final panelRect = Rect.lerp(ctrl.buttonRect, ctrl.pickerRect, m)!;
    final finalRadius = ctrl.rows == 1 ? 26.0 : 24.0;
    final radius = lerpDouble(ctrl.buttonRect.height / 2, finalRadius, m)!;
    final panelOpacity = (m / 0.35).clamp(0.0, 1.0);

    final items = <Widget>[];
    Widget? highlightedItem;
    for (int i = 0; i < count; i++) {
      // 飞行层接过原表情，避免槽位与飞回动画同时画出两份。
      if (ctrl._flight?.id == ctrl.reactions[i]) continue;
      final isHighlighted = highlight == i;
      final isNeighbor = highlight != null &&
          !isHighlighted &&
          (i - highlight).abs() == 1 &&
          i ~/ ctrl.columns == highlight ~/ ctrl.columns;
      // 展开:按 rank 错峰、easeOutBack 弹出;收回:跟着形变一起缩
      final double pop;
      if (closing) {
        pop = m;
      } else {
        final rank = ctrl.popRank[i];
        final start = 0.08 + 0.22 * (count > 1 ? rank / (count - 1) : 0);
        pop = Interval(start, start + 0.7, curve: Curves.easeOutBack)
            .transform(t);
      }
      if (pop <= 0) continue;
      // 槽位跟着面板形变走:从按钮中心衍生到最终位置,收回时原路吸回
      final finalRect = ctrl.itemRects[i];
      final rect = Rect.lerp(
        Rect.fromCenter(
          center: ctrl.buttonRect.center,
          width: _kItemSize,
          height: _kItemSize,
        ),
        finalRect,
        m,
      )!;
      final item = Positioned.fromRect(
        key: ValueKey(i),
        rect: rect,
        child: _ReactionItem(
          reactionId: ctrl.reactions[i],
          isCurrent: ctrl.currentUserReaction?.id == ctrl.reactions[i],
          isHighlighted: isHighlighted,
          isNeighbor: isNeighbor,
          pop: pop,
          lift: lift,
          onTap: _interactive
              ? () => ctrl.selectReaction(ctrl.reactions[i])
              : null,
        ),
      );
      // 高亮项最后加入,放大后盖在相邻项之上
      if (isHighlighted) {
        highlightedItem = item;
      } else {
        items.add(item);
      }
    }
    if (highlightedItem != null) items.add(highlightedItem);

    // 拖离时整层围绕面板中心轻微缩小；松手停驻时保持稳定。
    final weaken = ctrl.dismissT;
    final layerScale = 1 - 0.06 * weaken;
    final layerOpacity = 1 - 0.5 * weaken;
    final size = MediaQuery.sizeOf(context);
    final center = ctrl.pickerRect.center;
    final layerAlignment = Alignment(
      center.dx / size.width * 2 - 1,
      center.dy / size.height * 2 - 1,
    );

    Widget layer = Stack(
      children: [
        Positioned.fromRect(
          rect: panelRect,
          child: IgnorePointer(
            child: Opacity(
              opacity: panelOpacity,
              child: _PanelSurface(theme: theme, radius: radius),
            ),
          ),
        ),
        ...items,
      ],
    );
    layer = AnimatedScale(
      scale: layerScale,
      alignment: layerAlignment,
      duration: _kDismissDuration,
      curve: Curves.easeOut,
      child: AnimatedOpacity(
        opacity: layerOpacity,
        duration: _kDismissDuration,
        child: layer,
      ),
    );

    return Stack(
      children: [
        // 移动端长按拖选时：面板不接收指针事件，所有手势走父层 RawGestureDetector。
        // 移动端停驻/桌面端：表情需要接收 tap。
        Positioned.fill(
          child: IgnorePointer(ignoring: !_interactive, child: layer),
        ),
        _buildTooltip(theme, highlight, closing),
        if (ctrl._flight != null) _buildFlight(ctrl._flight!),
      ],
    );
  }

  /// 高亮项的名称气泡:反色胶囊,位于面板外侧(上方或下方),跟随高亮项横移
  Widget _buildTooltip(ThemeData theme, int? highlight, bool closing) {
    final visible = highlight != null && !closing;
    if (highlight != null) {
      _tooltipLabel = ctrl.reactions[highlight].replaceAll('_', ' ');
      _tooltipX = ctrl.itemRects[highlight].center.dx;
    }
    final label = _tooltipLabel;
    if (label == null) return const SizedBox.shrink();

    final anchorY = ctrl.isAbove
        ? ctrl.pickerRect.top - _kTooltipGap
        : ctrl.pickerRect.bottom + _kTooltipGap;
    final safe = MediaQuery.paddingOf(context);

    return Positioned.fill(
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _tooltipX),
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
          builder: (context, x, child) {
            return CustomSingleChildLayout(
              delegate: _TooltipLayoutDelegate(
                anchor: Offset(x, anchorY),
                growsDown: !ctrl.isAbove,
                safeInsets: safe,
              ),
              child: child,
            );
          },
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: _kHighlightDuration,
            child: AnimatedScale(
              scale: visible ? 1 : 0.85,
              duration: _kHighlightDuration,
              curve: Curves.easeOutBack,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.inverseSurface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 选中的表情沿弧线飞回按钮:起飞时是高亮放大态,落地前缩到图标大小并淡出
  Widget _buildFlight(_Flight flight) {
    final ft = Curves.easeInOutCubic.transform(ctrl.flightAnim.value);
    final p = flight.at(ft);
    final scale = lerpDouble(flight.startScale, 20 / _kIconSize, ft)!;
    final size = _kIconSize * scale;
    final opacity = ft < 0.85 ? 1.0 : 1 - (ft - 0.85) / 0.15;
    return Positioned(
      left: p.dx - size / 2,
      top: p.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: _EmojiImage(reactionId: flight.id, size: size),
        ),
      ),
    );
  }
}

/// 面板底面：轻底色配两层柔和投影，深色下用细描边保持边界清晰。
class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.theme, required this.radius});

  final ThemeData theme;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.28 : 0.09),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.16 : 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(
            alpha: dark ? 0.4 : 0.2,
          ),
          width: 0.5,
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// tooltip 药丸定位：以 [anchor] 为水平中心 / 垂直端点摆放，
/// 测得药丸实际尺寸后整体 clamp 在屏幕安全区内。
class _TooltipLayoutDelegate extends SingleChildLayoutDelegate {
  const _TooltipLayoutDelegate({
    required this.anchor,
    required this.growsDown,
    required this.safeInsets,
  });

  /// 锚点：面板在上方时为药丸底边中点，面板在下方（[growsDown]）时为顶边中点
  final Offset anchor;
  final bool growsDown;
  final EdgeInsets safeInsets;

  static const double _margin = 12.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: math.max(0, constraints.maxWidth - _margin * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double x = (anchor.dx - childSize.width / 2).clamp(
      _margin,
      math.max(_margin, size.width - _margin - childSize.width),
    );
    final rawY = growsDown ? anchor.dy : anchor.dy - childSize.height;
    final double y = rawY.clamp(
      safeInsets.top + _margin,
      math.max(
        safeInsets.top + _margin,
        size.height - safeInsets.bottom - _margin - childSize.height,
      ),
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_TooltipLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      growsDown != oldDelegate.growsDown ||
      safeInsets != oldDelegate.safeInsets;
}

// ============================== 单项 ==============================

class _ReactionItem extends StatelessWidget {
  const _ReactionItem({
    required this.reactionId,
    required this.isCurrent,
    required this.isHighlighted,
    required this.isNeighbor,
    required this.pop,
    required this.lift,
    required this.onTap,
  });

  final String reactionId;

  /// 我当前的 reaction：用淡色圆角底标记，与滑选高亮使用同一种形状。
  final bool isCurrent;
  final bool isHighlighted;

  /// 高亮项同行相邻:略缩小让位
  final bool isNeighbor;

  /// 弹出进度(easeOutBack 会略超过 1)
  final double pop;

  /// 高亮上浮距离
  final double lift;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final borderRadius = BorderRadius.circular(14);
    final highlightScale = isHighlighted
        ? _kHighlightScale
        : isNeighbor
            ? _kNeighborScale
            : 1.0;

    final background = isCurrent
        ? theme.colorScheme.primaryContainer
        : isHighlighted
            ? primary.withValues(alpha: 0.1)
            : primary.withValues(alpha: 0);

    Widget content = AnimatedContainer(
      duration: _kHighlightDuration,
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: borderRadius,
      ),
      child: Center(
        child: _EmojiImage(reactionId: reactionId, size: _kIconSize),
      ),
    );

    if (onTap != null) {
      // 按压反馈与选中底色保持相同圆角，整个槽位均可点击。
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          splashFactory: NoSplash.splashFactory,
          highlightColor: primary.withValues(alpha: 0.08),
          child: content,
        ),
      );
    }

    return Semantics(
      button: true,
      selected: isCurrent,
      label: reactionId.replaceAll('_', ' '),
      child: Transform.scale(
        scale: pop,
        child: AnimatedSlide(
          offset: Offset(0, isHighlighted ? -lift / _kItemSize : 0),
          duration: _kHighlightDuration,
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: highlightScale,
            duration: _kHighlightDuration,
            curve: Curves.easeOutCubic,
            child: content,
          ),
        ),
      ),
    );
  }
}

class _EmojiImage extends StatelessWidget {
  const _EmojiImage({required this.reactionId, required this.size});

  final String reactionId;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: emojiImageProvider(_getEmojiUrl(reactionId)),
      width: size,
      height: size,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) =>
          Icon(Symbols.emoji_emotions_rounded, size: size * 0.9),
    );
  }
}
