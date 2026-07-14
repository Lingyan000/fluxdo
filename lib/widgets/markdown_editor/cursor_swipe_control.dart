/// 光标滑钮(手势光标):按住钮在工具栏上水平滑动,光标随手指连续
/// 移动 —— 把工具栏变成光标触控板,替代手指戳
/// 屏定位(遮挡/点不准/微调痛苦)。
///
/// - 每滑动 [stepPx] 触发一步 [onMove](方向 ±1),带触觉;滑出按钮
///   范围手势继续有效(pan 已被本控件独占,不与工具栏滚动打架);
/// - 旁挂「选择」小开关:开启后滑动 = 扩选(onMove extend=true),
///   再次点击或收起键盘自然复位。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class CursorSwipeControl extends StatefulWidget {
  const CursorSwipeControl({super.key, required this.onMove});

  /// 移动一步:[dir] = ±1,[extend] = 选择模式(扩选)。
  final void Function(int dir, {required bool extend}) onMove;

  @override
  State<CursorSwipeControl> createState() => _CursorSwipeControlState();
}

class _CursorSwipeControlState extends State<CursorSwipeControl> {
  static const double _stepPx = 12;

  bool _selecting = false;
  bool _dragging = false;
  double _acc = 0;

  void _onDragStart(DragStartDetails d) {
    setState(() => _dragging = true);
    _acc = 0;
    HapticFeedback.selectionClick();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _acc += d.delta.dx;
    while (_acc.abs() >= _stepPx) {
      final dir = _acc > 0 ? 1 : -1;
      _acc -= dir * _stepPx;
      widget.onMove(dir, extend: _selecting);
      HapticFeedback.selectionClick();
    }
  }

  void _onDragEnd() {
    if (mounted) setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // 光标滑钮:按住水平拖动驱动光标
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: (_) => _onDragEnd(),
        onHorizontalDragCancel: _onDragEnd,
        child: Tooltip(
          message: '按住左右滑动移动光标',
          child: Container(
            key: const ValueKey('cursor-swipe-knob'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: _dragging
                  ? scheme.primary.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: FaIcon(
              FontAwesomeIcons.leftRight,
              size: 18,
              color:
                  _dragging ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      // 选择开关:开启后滑动 = 扩选
      IconButton(
        key: const ValueKey('cursor-select-toggle'),
        visualDensity: VisualDensity.compact,
        tooltip: _selecting ? '滑动扩选中(点击关闭)' : '开启滑动选择',
        icon: FaIcon(
          FontAwesomeIcons.iCursor,
          size: 16,
          color: _selecting ? scheme.primary : scheme.onSurfaceVariant,
        ),
        isSelected: _selecting,
        onPressed: () => setState(() => _selecting = !_selecting),
      ),
    ]);
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
