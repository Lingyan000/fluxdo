import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'm3e_flags.dart';

/// 一个联排按钮项。
class M3eButtonGroupItem<T> {
  final T value;
  final Widget label;
  final Widget? icon;

  const M3eButtonGroupItem({
    required this.value,
    required this.label,
    this.icon,
  });
}

/// M3E 联排选择按钮：选中项的圆角和底色连续变化，按住拖动时弹性拉伸。
///
/// 复用原有接口、字号与内边距；按压仅改变绘制，不挤压邻项或改变组的尺寸。
/// 关闭 M3E 时继续使用原生 [SegmentedButton]。
class M3eButtonGroup<T> extends StatefulWidget {
  final List<M3eButtonGroupItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry itemPadding;

  const M3eButtonGroup({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  @override
  State<M3eButtonGroup<T>> createState() => _M3eButtonGroupState<T>();
}

class _M3eButtonGroupState<T> extends State<M3eButtonGroup<T>> {
  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return SegmentedButton<T>(
        segments: [
          for (final item in widget.items)
            ButtonSegment<T>(
              value: item.value,
              label: item.label,
              icon: item.icon,
            ),
        ],
        selected: {widget.selected},
        onSelectionChanged: (values) => widget.onSelected(values.first),
        showSelectedIcon: false,
      );
    }
    return _ConnectedRow(
      children: [
        for (var i = 0; i < widget.items.length; i++)
          Expanded(
            key: ValueKey(widget.items[i].value),
            child: _ConnectedButton(
              selected: widget.items[i].value == widget.selected,
              first: i == 0,
              last: i == widget.items.length - 1,
              padding: widget.itemPadding,
              icon: widget.items[i].icon,
              label: widget.items[i].label,
              onSelected: () => widget.onSelected(widget.items[i].value),
            ),
          ),
      ],
    );
  }
}

/// 最近按下的按钮最后绘制，膨胀边缘不会被相邻按钮遮住。
class _ConnectedRow extends Row {
  const _ConnectedRow({required super.children}) : super(spacing: 3);

  @override
  RenderFlex createRenderObject(BuildContext context) =>
      _ConnectedRenderRow(textDirection: Directionality.of(context));
}

class _ConnectedRenderRow extends RenderFlex {
  _ConnectedRenderRow({required TextDirection textDirection})
    : super(
        direction: Axis.horizontal,
        spacing: 3,
        textDirection: textDirection,
      );

  RenderBox? _raised;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is! PointerDownEvent) return;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final offset = (child.parentData! as FlexParentData).offset;
      if ((offset & child.size).contains(entry.localPosition)) {
        _raised = child;
        markNeedsPaint();
        break;
      }
    }
  }

  @override
  void dropChild(RenderObject child) {
    if (identical(child, _raised)) _raised = null;
    super.dropChild(child);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    void paintChild(RenderBox child) => context.paintChild(
      child,
      offset + (child.parentData! as FlexParentData).offset,
    );
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (!identical(child, _raised)) paintChild(child);
    }
    if (_raised case final raised?) paintChild(raised);
  }
}

class _ConnectedButton extends StatefulWidget {
  const _ConnectedButton({
    required this.selected,
    required this.first,
    required this.last,
    required this.padding,
    required this.label,
    required this.icon,
    required this.onSelected,
  });
  final bool selected, first, last;
  final EdgeInsetsGeometry padding;
  final Widget label;
  final Widget? icon;
  final VoidCallback onSelected;

  @override
  State<_ConnectedButton> createState() => _ConnectedButtonState();
}

class _ConnectedButtonState extends State<_ConnectedButton>
    with TickerProviderStateMixin {
  // 对齐 FlClash / prism_ui ElasticPress 的跟手、阻尼和回弹节奏。
  static final _releaseSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 311,
    ratio: .593,
  );
  static final _trackingSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 120),
  );
  late final _press = AnimationController.unbounded(vsync: this);
  late final _pullX = AnimationController.unbounded(vsync: this);
  late final _pullY = AnimationController.unbounded(vsync: this);
  int? _pointer;
  int? _moveFrame;
  Offset? _pendingPull;
  Offset _origin = Offset.zero;
  bool _pressed = false;
  bool _releasing = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _press.addListener(_settlePress);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _releasing = false;
      for (final controller in [_press, _pullX, _pullY]) {
        controller.value = 0;
      }
    }
  }

  void _springTo(
    AnimationController controller,
    double target,
    SpringDescription spring,
  ) {
    controller.animateWith(
      SpringSimulation(
        spring,
        controller.value,
        target,
        controller.velocity,
        snapToEnd: true,
      ),
    );
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    _pressed = value;
    if (_reduceMotion) return;
    _releasing = !value;
    if (value) {
      HapticFeedback.selectionClick();
      _springTo(_press, 1, _releaseSpring);
    } else {
      _springTo(_pullX, 0, _releaseSpring);
      _springTo(_pullY, 0, _releaseSpring);
      _settlePress();
    }
  }

  // 快速点击也完整膨胀一次，再回到静止形状。
  void _settlePress() {
    if (!_releasing || _press.value < .975) return;
    _releasing = false;
    _springTo(_press, 0, _releaseSpring);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null || event.buttons & kPrimaryButton == 0) return;
    _pointer = event.pointer;
    _origin = event.localPosition;
    _setPressed(true);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!mounted || event.pointer != _pointer || _reduceMotion) return;
    _pendingPull = event.localPosition - _origin;
    _moveFrame ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _moveFrame = null;
      final delta = _pendingPull;
      _pendingPull = null;
      if (mounted && _pointer != null && delta != null && !_reduceMotion) {
        _trackPull(delta);
      }
    });
  }

  void _trackPull(Offset delta) {
    final size = (context.findRenderObject()! as RenderBox).size;
    final limit = size.shortestSide * 7 / 32;
    if (limit <= 0) return;
    // 位移逐渐趋近上限，拖出按钮后也不会无限拉长。
    double resisted(double distance) =>
        limit * (1 - 1 / (distance.abs() * .55 / limit + 1)) * distance.sign;
    _springTo(_pullX, resisted(delta.dx), _trackingSpring);
    _springTo(_pullY, resisted(delta.dy), _trackingSpring);
  }

  void _handlePointerEnd(PointerEvent event) {
    if (!mounted || event.pointer != _pointer) return;
    _cancelPointer();
  }

  void _cancelPointer() {
    if (!mounted) return;
    _pointer = null;
    _pendingPull = null;
    if (_moveFrame case final frame?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
      _moveFrame = null;
    }
    _setPressed(false);
  }

  void _handleHighlightChanged(bool value) {
    // 拖动由识别器独占并取消 InkWell 的点击，只保留键盘激活的高亮反馈。
    // 键盘激活没有指针，继续通过高亮状态触发膨胀。
    if (_pointer == null) _setPressed(value);
  }

  @override
  void dispose() {
    if (_moveFrame case final frame?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
    }
    _press.dispose();
    _pullX.dispose();
    _pullY.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final direction = Directionality.of(context);
    final outer = math.max(
      24.0,
      (MediaQuery.textScalerOf(context).scale(20) +
              widget.padding.resolve(direction).vertical) /
          2,
    );
    return RawGestureDetector(
      excludeFromSemantics: true,
      gestures: {
        _ConnectedDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_ConnectedDragRecognizer>(
              () => _ConnectedDragRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onDown = _handlePointerDown
                ..onMove = _handlePointerMove
                ..onEnd = _handlePointerEnd
                ..onCancel = _cancelPointer,
            ),
      },
      child: RepaintBoundary(
        child: _ConnectedPressTransform(
          press: _press,
          pullX: _pullX,
          pullY: _pullY,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.selected ? 1 : 0),
            duration: _reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            builder: (context, amount, _) {
              final inner = 8 + (outer - 8) * amount;
              final shape = RoundedSuperellipseBorder(
                borderRadius: BorderRadiusDirectional.horizontal(
                  start: Radius.circular(widget.first ? outer : inner),
                  end: Radius.circular(widget.last ? outer : inner),
                ),
              );
              final foreground = Color.lerp(
                scheme.onSurfaceVariant,
                scheme.onPrimary,
                amount,
              )!;
              return Semantics(
                button: true,
                selected: widget.selected,
                inMutuallyExclusiveGroup: true,
                child: Material(
                  color: Color.lerp(
                    scheme.surfaceContainerHigh,
                    scheme.primary,
                    amount,
                  ),
                  shape: shape,
                  clipBehavior: Clip.antiAlias,
                  animationDuration: Duration.zero,
                  child: InkWell(
                    customBorder: shape,
                    onTap: widget.onSelected,
                    onHighlightChanged: _handleHighlightChanged,
                    splashFactory: NoSplash.splashFactory,
                    child: Padding(
                      padding: widget.padding,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            IconTheme.merge(
                              data: IconThemeData(size: 18, color: foreground),
                              child: widget.icon!,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: DefaultTextStyle.merge(
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.lerp(
                                  FontWeight.w500,
                                  FontWeight.w600,
                                  amount,
                                ),
                                color: foreground,
                              ),
                              child: widget.label,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 移动超过容差后赢得手势竞争，取消点击、父级滚动/翻页等竞争手势。
/// 未拖动的普通点击仍交给内部 InkWell，保留原回调与键盘语义。
class _ConnectedDragRecognizer extends OneSequenceGestureRecognizer {
  _ConnectedDragRecognizer({super.debugOwner});
  ValueChanged<PointerDownEvent>? onDown;
  ValueChanged<PointerMoveEvent>? onMove;
  ValueChanged<PointerEvent>? onEnd;
  VoidCallback? onCancel;
  PointerDownEvent? _down;
  bool _dragging = false;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _down == null &&
      event.buttons == kPrimaryButton &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _down = event;
    _dragging = false;
    startTrackingPointer(event.pointer, event.transform);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (down == null || event.pointer != down.pointer) return;
    if (event is PointerMoveEvent) {
      if (!_dragging &&
          (event.position - down.position).distance >
              computeHitSlop(event.kind, gestureSettings)) {
        resolve(GestureDisposition.accepted);
      }
      if (_dragging) onMove?.call(event);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      final dragging = _dragging;
      _down = null;
      onEnd?.call(event);
      if (!dragging) resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (_down?.pointer == pointer) _dragging = true;
  }

  @override
  void rejectGesture(int pointer) {
    if (_down?.pointer != pointer) return;
    _down = null;
    _dragging = false;
    stopTrackingPointer(pointer);
    onCancel?.call();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
  @override
  String get debugDescription => 'connected button drag';
}

/// 只变换绘制，布局和指针命中使用按钮静止时的范围。
class _ConnectedPressTransform extends SingleChildRenderObjectWidget {
  const _ConnectedPressTransform({
    required this.press,
    required this.pullX,
    required this.pullY,
    required super.child,
  });

  final Animation<double> press, pullX, pullY;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ConnectedPressRenderBox(press, pullX, pullY);

  @override
  void updateRenderObject(
    BuildContext context,
    _ConnectedPressRenderBox renderObject,
  ) => renderObject.update(press, pullX, pullY);
}

class _ConnectedPressRenderBox extends RenderProxyBox {
  _ConnectedPressRenderBox(this.press, this.pullX, this.pullY);
  Animation<double> press, pullX, pullY;
  double get _press => press.value;
  Offset get _pull => Offset(pullX.value, pullY.value);

  void _listen(bool add) {
    for (final animation in [press, pullX, pullY]) {
      if (add) {
        animation.addListener(_tick);
      } else {
        animation.removeListener(_tick);
      }
    }
  }

  void update(
    Animation<double> press,
    Animation<double> pullX,
    Animation<double> pullY,
  ) {
    if (this.press == press && this.pullX == pullX && this.pullY == pullY) {
      return;
    }
    if (attached) _listen(false);
    this.press = press;
    this.pullX = pullX;
    this.pullY = pullY;
    if (attached) _listen(true);
    _tick();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen(true);
  }

  @override
  void detach() {
    _listen(false);
    super.detach();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Matrix4 get _transform {
    if (size.isEmpty) return Matrix4.identity();
    // 大小不同的按钮最多膨胀 16 dp；按移动方向分别拉伸两个轴。
    final swell = 1 + _press * math.min(.25, 16 / size.longestSide);
    final scaleX = swell * (1 + _pull.dx.abs() / size.width * .5);
    final scaleY = swell * (1 + _pull.dy.abs() / size.height * .5);
    final center = size.center(Offset.zero);
    return Matrix4.diagonal3Values(scaleX, scaleY, 1)..setTranslationRaw(
      center.dx * (1 - scaleX) + _pull.dx,
      center.dy * (1 - scaleY) + _pull.dy,
      0,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null ||
        size.isEmpty ||
        (_press == 0 && _pull == Offset.zero)) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      super.paint,
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }
}
