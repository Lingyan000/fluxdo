import 'dart:math' as math;
import 'package:flutter/gestures.dart' show kPrimaryButton;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'm3e_flags.dart';

/// 只负责绘制弹性反馈；点击、长按和滚动仍由原控件处理。
/// 嵌套时由最外层统一绘制，避免按钮组和组内按钮重复形变。
class M3eElasticPress extends StatefulWidget {
  const M3eElasticPress({
    super.key,
    required this.child,
    this.enabled = true,
    this.selectionFeedback = false,
  });
  final Widget child;
  final bool enabled, selectionFeedback;
  @override
  State<M3eElasticPress> createState() => _ElasticPressState();
}

class _PressScope extends InheritedWidget {
  const _PressScope({required super.child});
  @override
  bool updateShouldNotify(_PressScope oldWidget) => false;
}

class _ElasticPressState extends State<M3eElasticPress>
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
    _reduceMotion =
        !M3eFlags.of(context).enabled ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled ||
        context.dependOnInheritedWidgetOfExactType<_PressScope>() != null;
    _resetIfDisabled();
  }

  @override
  void didUpdateWidget(M3eElasticPress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _resetIfDisabled();
  }

  void _resetIfDisabled() {
    if (_reduceMotion || !widget.enabled) {
      _cancelPointer();
      _pressed = false;
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
    if (_reduceMotion || !widget.enabled) return;
    _releasing = !value;
    if (value) {
      if (widget.selectionFeedback) HapticFeedback.selectionClick();
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
    if (!widget.enabled ||
        _reduceMotion ||
        _pointer != null ||
        event.buttons != kPrimaryButton) {
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _scroll = Scrollable.maybeOf(context)?.position.isScrollingNotifier;
    _scroll?.addListener(_onScroll);
    _setPressed(true);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!mounted || event.pointer != _pointer || _reduceMotion) return;
    _pendingPull = event.position - _origin;
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

  ValueNotifier<bool>? _scroll;
  void _onScroll() {
    if (_scroll?.value == true) _cancelPointer();
  }

  void _cancelPointer() {
    _scroll?.removeListener(_onScroll);
    _scroll = null;
    if (!mounted) return;
    _pointer = null;
    _pendingPull = null;
    if (_moveFrame case final frame?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
      _moveFrame = null;
    }
    _setPressed(false);
  }

  @override
  void dispose() {
    _scroll?.removeListener(_onScroll);
    if (_moveFrame case final frame?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
    }
    _press.dispose();
    _pullX.dispose();
    _pullY.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _handlePointerDown,
    onPointerMove: _handlePointerMove,
    onPointerUp: _handlePointerEnd,
    onPointerCancel: _handlePointerEnd,
    child: RepaintBoundary(
      child: _ElasticTransform(
        press: _press,
        pullX: _pullX,
        pullY: _pullY,
        child: _PressScope(child: widget.child),
      ),
    ),
  );
}

/// 只变换绘制，布局和指针命中使用按钮静止时的范围。
class _ElasticTransform extends SingleChildRenderObjectWidget {
  const _ElasticTransform({
    required this.press,
    required this.pullX,
    required this.pullY,
    required super.child,
  });

  final Animation<double> press, pullX, pullY;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ElasticRenderBox(press, pullX, pullY);

  @override
  void updateRenderObject(
    BuildContext context,
    _ElasticRenderBox renderObject,
  ) => renderObject.update(press, pullX, pullY);
}

class _ElasticRenderBox extends RenderProxyBox {
  _ElasticRenderBox(this.press, this.pullX, this.pullY);
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
