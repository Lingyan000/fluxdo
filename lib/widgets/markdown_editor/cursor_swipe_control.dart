/// 光标滑钮(手势光标):按住钮在工具栏上水平滑动,光标随手指连续
/// 移动 —— 把工具栏变成光标触控板,替代手指戳
/// 屏定位(遮挡/点不准/微调痛苦)。
///
/// - 每滑动 [stepPx] 触发一步 [onMove](方向 ±1),带触觉;
/// - **按下即独占手势**(eager claim):外层同向手势(左滑预览/返回
///   手势/工具栏横滚)一概抢不走 —— 按住滑钮 = 控制权归光标;
/// - **单击滑钮 = 切换选择模式**(常亮高亮示意):开启后滑动 = 扩选。
///   点按语义并入同一识别器(位移 < 阈值 = 单击),单控件全包;
/// - 可发现性:**首次按下**在钮上方浮内联提示(前几次,持久计数后
///   永久收声)—— Tooltip 的长按触发与按住拖动冲突,已弃用。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:app_icons/app_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // ---- 首次使用内联提示(教学发生在按下瞬间,不参与命中) ----
  static const _kMoveHintKey = 'cursor_swipe_hint_move_left';
  static const _kSelectHintKey = 'cursor_swipe_hint_select_left';
  SharedPreferences? _prefs;
  int _moveHintLeft = 0;
  int _selectHintLeft = 0;
  OverlayEntry? _hint;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      _prefs = p;
      _moveHintLeft = p.getInt(_kMoveHintKey) ?? 3;
      _selectHintLeft = p.getInt(_kSelectHintKey) ?? 2;
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _removeHint();
    super.dispose();
  }

  void _showHint(String text, {Duration? autoHide}) {
    _removeHint();
    final overlay = Overlay.maybeOf(context);
    final box = context.findRenderObject() as RenderBox?;
    if (overlay == null || box == null || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    _hint = OverlayEntry(
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return Positioned(
          // 滑钮在工具栏右侧:右对齐屏缘,永不溢出
          right: 12,
          top: top - 42,
          child: IgnorePointer(
            child: Material(
              color: scheme.inverseSurface,
              borderRadius: BorderRadius.circular(8),
              elevation: 2,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.0,
                    color: scheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_hint!);
    if (autoHide != null) {
      _hintTimer?.cancel();
      _hintTimer = Timer(autoHide, _removeHint);
    }
  }

  void _removeHint() {
    _hint?.remove();
    _hint = null;
  }

  void _consume(String key, int left) {
    _prefs?.setInt(key, left);
  }

  void _onDown() {
    _acc = 0;
    _total = Offset.zero;
    _moved = false;
    _pointerLive = false;
    if (_moveHintLeft > 0) {
      _showHint('滑动移动光标 · 单击切换选择');
      _moveHintLeft--;
      _consume(_kMoveHintKey, _moveHintLeft);
    }
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _total += d.delta;
    if (!_moved) {
      if (_total.distance < _tapSlop) return;
      _moved = true;
      _removeHint(); // 已经会用了,教学即收
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
      _removeHint();
      setState(() => _selecting = !_selecting);
      HapticFeedback.selectionClick();
      if (_selecting && _selectHintLeft > 0) {
        _showHint('选择模式:滑动即选择文本',
            autoHide: const Duration(milliseconds: 1800));
        _selectHintLeft--;
        _consume(_kSelectHintKey, _selectHintLeft);
      }
      return;
    }
    _removeHint();
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
