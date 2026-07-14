/// 光标滑钮(手势光标):按住钮在工具栏上水平滑动,光标随手指连续
/// 移动 —— 把工具栏变成光标触控板,替代手指戳
/// 屏定位(遮挡/点不准/微调痛苦)。
///
/// - 每滑动 [stepPx] 触发一步 [onMove](方向 ±1),带触觉;滑出按钮
///   范围手势继续有效(pan 已被本控件独占,不与工具栏滚动打架);
/// - **单击滑钮 = 切换选择模式**(常亮高亮示意):开启后滑动 = 扩选。
///   单控件承载移动+选择,不占第二个按钮位(底部工具栏寸土寸金)。
library;

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

class _CursorSwipeControlState extends State<CursorSwipeControl> {
  static const double _stepPx = 12;

  bool _selecting = false;
  bool _dragging = false;
  double _acc = 0;
  bool _pointerLive = false;

  bool get _pointerMode => widget.onPointerStart != null;

  void _onDragStart(DragStartDetails d) {
    _acc = 0;
    if (_pointerMode) {
      _pointerLive = widget.onPointerStart!(extend: _selecting);
      if (!_pointerLive) return;
    }
    setState(() => _dragging = true);
    HapticFeedback.selectionClick();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_pointerMode) {
      if (_pointerLive) widget.onPointerMove?.call(d.delta);
      return;
    }
    _acc += d.delta.dx;
    while (_acc.abs() >= _stepPx) {
      final dir = _acc > 0 ? 1 : -1;
      _acc -= dir * _stepPx;
      widget.onMove!(dir, extend: _selecting);
      HapticFeedback.selectionClick();
    }
  }

  void _onDragEnd() {
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
    // 单控件:按住拖 = 移动/扩选;单击 = 切换选择模式(高亮常亮)
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _selecting = !_selecting);
        HapticFeedback.selectionClick();
      },
      // 指针模式 = 二维 pan(可跨行漂移);步进模式只认水平
      onPanStart: _pointerMode ? _onDragStart : null,
      onPanUpdate: _pointerMode ? _onDragUpdate : null,
      onPanEnd: _pointerMode ? (_) => _onDragEnd() : null,
      onPanCancel: _pointerMode ? _onDragEnd : null,
      onHorizontalDragStart: _pointerMode ? null : _onDragStart,
      onHorizontalDragUpdate: _pointerMode ? null : _onDragUpdate,
      onHorizontalDragEnd: _pointerMode ? null : (_) => _onDragEnd(),
      onHorizontalDragCancel: _pointerMode ? null : _onDragEnd,
      child: Tooltip(
        message: _selecting
            ? '选择模式:滑动即选择文本,单击退出'
            : '按住滑动移动光标;单击进入选择模式',
        child: Container(
          key: const ValueKey('cursor-swipe-knob'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? scheme.primary.withValues(alpha: _dragging ? 0.18 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: _selecting
              ? Icon(
                  Symbols.text_select_start_rounded,
                  size: 18,
                  color: scheme.primary,
                )
              : FaIcon(
                  FontAwesomeIcons.iCursor,
                  size: 18,
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
