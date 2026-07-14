/// 光标滑钮(手势光标):按住钮在工具栏上水平滑动,光标随手指连续
/// 移动 —— 把工具栏变成光标触控板,替代手指戳
/// 屏定位(遮挡/点不准/微调痛苦)。
///
/// - 每滑动 [stepPx] 触发一步 [onMove](方向 ±1),带触觉;
/// - **按下即独占手势**(eager claim):外层同向手势(左滑预览/返回
///   手势/工具栏横滚)一概抢不走 —— 按住滑钮 = 控制权归光标;
/// - **单击滑钮 = 切换选择模式**(常亮高亮示意):开启后滑动 = 扩选。
///   点按语义并入同一识别器(位移 < 阈值 = 单击),单控件全包。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:app_icons/app_icons.dart';

class CursorSwipeControl extends StatefulWidget {
  const CursorSwipeControl({
    super.key,
    this.onMove,
    this.onPointerStart,
    this.onPointerMove,
    this.onPointerEnd,
  }) : assert(onMove != null || onPointerStart != null,
            '步进(onMove)与指针(onPointer*)模式二选一');

  /// 步进模式(水平):每步 [dir] = ±1,[extend] = 选择开关态。
  final void Function(int dir, {required bool extend})? onMove;

  /// 指针模式(二维虚拟指针):按下起步,返回 false = 编辑器无光标,
  /// 本次拖动忽略。与 [onPointerMove]/[onPointerEnd] 成组。
  final bool Function({required bool extend})? onPointerStart;

  /// 指针模式:拖动增量(原始 delta,二维)。
  final ValueChanged<Offset>? onPointerMove;

  final VoidCallback? onPointerEnd;

  @override
  State<CursorSwipeControl> createState() => _CursorSwipeControlState();
}

/// 按下即宣称胜出的 pan:滑钮区域内手势独占,外层同向识别器
/// (页面左滑预览/返回手势)按不进竞技场。
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  _EagerPanGestureRecognizer({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _CursorSwipeControlState extends State<CursorSwipeControl> {
  static const double _stepPx = 12;

  /// 位移小于该值的按放 = 单击(切换选择模式)。
  static const double _tapSlop = 8;

  bool _selecting = false;
  bool _dragging = false;
  double _acc = 0;
  bool _pointerLive = false;

  /// 本次手势是否已越过 tapSlop 进入拖动(lazy start:按下不立刻
  /// start,否则单击也会驱动一次空拖 —— 指针模式的 start 会落光标)。
  bool _moved = false;
  Offset _total = Offset.zero;

  bool get _pointerMode => widget.onPointerStart != null;

  void _onDown() {
    _acc = 0;
    _total = Offset.zero;
    _moved = false;
    _pointerLive = false;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _total += d.delta;
    if (!_moved) {
      if (_total.distance < _tapSlop) return;
      _moved = true;
      if (_pointerMode) {
        _pointerLive = widget.onPointerStart!(extend: _selecting);
        if (!_pointerLive) return;
      }
      setState(() => _dragging = true);
      HapticFeedback.selectionClick();
      // 起步前累计的位移一并补上
      if (_pointerMode && _pointerLive) {
        widget.onPointerMove?.call(_total);
        return;
      }
      _acc = _total.dx;
    } else if (_pointerMode) {
      if (_pointerLive) widget.onPointerMove?.call(d.delta);
      return;
    } else {
      _acc += d.delta.dx;
    }
    if (_pointerMode) return;
    while (_acc.abs() >= _stepPx) {
      final dir = _acc > 0 ? 1 : -1;
      _acc -= dir * _stepPx;
      widget.onMove!(dir, extend: _selecting);
      HapticFeedback.selectionClick();
    }
  }

  void _onDragEnd() {
    if (!_moved) {
      // 未越过 tapSlop = 单击:切换选择模式
      setState(() => _selecting = !_selecting);
      HapticFeedback.selectionClick();
      return;
    }
    if (_pointerMode && _pointerLive) {
      _pointerLive = false;
      widget.onPointerEnd?.call();
    }
    if (mounted) setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _dragging || _selecting;
    // 单控件单识别器:按下即独占(外层左滑预览抢不走);位移 < 阈值
    // 的按放 = 单击切换选择模式;越过阈值 = 拖动(移动/扩选)
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _EagerPanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerPanGestureRecognizer>(
          () => _EagerPanGestureRecognizer(debugOwner: this),
          (r) {
            r
              ..onDown = ((_) => _onDown())
              ..onUpdate = _onDragUpdate
              ..onEnd = ((_) => _onDragEnd())
              ..onCancel = _onDragEnd;
          },
        ),
      },
      // 不用 Tooltip:其长按触发与「按住拖动」手势冲突(按住先弹提示,
      // 拖不起来)。说明留给 Semantics(无障碍)。
      child: Semantics(
        label: _selecting ? '选择模式:滑动选择文本,单击退出' : '按住滑动移动光标,单击进入选择模式',
        child: Container(
          key: const ValueKey('cursor-swipe-knob'),
          width: 44,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? scheme.primary.withValues(alpha: _dragging ? 0.18 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: _selecting
              ? Icon(
                  Symbols.text_select_start_rounded,
                  size: 20,
                  color: scheme.primary,
                )
              : FaIcon(
                  FontAwesomeIcons.iCursor,
                  size: 19,
                  color:
                      active ? scheme.primary : scheme.onSurfaceVariant,
                ),
        ),
      ),
    );
  }
}

/// 文本选区按 grapheme 移动一步(emoji/代理对不劈半)。返回新选区,
/// 无变化返回 null。非扩选且有选区时先折叠到方向侧(系统方向键语义)。
TextSelection? moveTextSelectionByGrapheme(
  TextEditingValue value,
  int dir, {
  required bool extend,
}) {
  final sel = value.selection;
  if (!sel.isValid) return null;
  final text = value.text;
  if (!extend && !sel.isCollapsed) {
    return TextSelection.collapsed(offset: dir < 0 ? sel.start : sel.end);
  }
  final from = sel.extentOffset;
  final int to;
  if (dir < 0) {
    to = from <= 0
        ? 0
        : from - text.substring(0, from).characters.last.length;
  } else {
    to = from >= text.length
        ? text.length
        : from + text.substring(from).characters.first.length;
  }
  if (to == from) return null;
  return extend
      ? sel.copyWith(extentOffset: to)
      : TextSelection.collapsed(offset: to);
}
