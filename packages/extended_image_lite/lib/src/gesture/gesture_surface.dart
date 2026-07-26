import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../typedef.dart';
import '../utils.dart';
import 'gesture_controller.dart';
import 'page_view/gesture_page_view.dart';
import 'slide_page.dart';
import 'utils.dart';

/// 双击回调(新架构:回传常驻手势层 State)
typedef SurfaceDoubleTap = void Function(GestureSurfaceState state);

/// 常驻手势层 —— 查看器会话内一次挂载、终身不换的事件载体。
///
/// 替代旧架构中会随 LoadState 树切换销毁的两个载体
/// (ExtendedImageGesture / ExtendedImageSlidePageHandler):
/// 手势结果全部写入 [ImageGestureController],绘制层监听 controller
/// 重绘;载体不死,rebindSlideTarget/dispose 兜底等补丁失去存在必要。
///
/// 手势处理逻辑(缩放/平移/slide 仲裁/PageView 让渡/惯性边界)自
/// gesture.dart 的 ExtendedImageGestureState 逐段搬运,物理与仲裁
/// 数值零改动;唯一差异是状态读写从 State 字段换成 controller。
class GestureSurface extends StatefulWidget {
  const GestureSurface({
    super.key,
    required this.controller,
    required this.child,
    this.onDoubleTap,
    CanScaleImage? canScaleImage,
    this.enableSlideOutPage = false,
    this.inPageView = false,
  }) : canScaleImage = canScaleImage ?? _defaultCanScaleImage;

  final ImageGestureController controller;
  final Widget child;
  final SurfaceDoubleTap? onDoubleTap;
  final CanScaleImage canScaleImage;

  /// 是否参与祖先 ExtendedImageSlidePage 的下滑关闭
  final bool enableSlideOutPage;

  /// 是否在 ExtendedImageGesturePageView 中(需要注册仲裁)
  final bool inPageView;

  static bool _defaultCanScaleImage(GestureDetails? details) => true;

  @override
  GestureSurfaceState createState() => GestureSurfaceState();
}

class GestureSurfaceState extends State<GestureSurface>
    with TickerProviderStateMixin
    implements DoubleTapTarget, GesturePageViewArbiter {
  late Offset _normalizedOffset;
  double? _startingScale;
  late Offset _startingOffset;
  Offset? _pointerDownPosition;
  late GestureAnimation _gestureAnimation;

  ExtendedImageSlidePageState? _slidePageState;
  ExtendedImageGesturePageViewState? _pageViewState;

  ImageGestureController get controller => widget.controller;
  GestureConfig get _gestureConfig => controller.config;

  @override
  GestureDetails? get gestureDetails => controller.details;

  @override
  set gestureDetails(GestureDetails? value) {
    controller.details = value;
  }

  @override
  Offset? get pointerDownPosition => _pointerDownPosition;

  ExtendedImageSlidePageState? get extendedImageSlidePageState =>
      _slidePageState;

  @override
  void initState() {
    super.initState();
    _gestureAnimation = GestureAnimation(
      this,
      offsetCallBack: (Offset value) {
        gestureDetails = GestureDetails(
          offset: value,
          totalScale: gestureDetails!.totalScale,
          gestureDetails: gestureDetails,
        );
      },
      scaleCallBack: (double scale) {
        gestureDetails = GestureDetails(
          offset: gestureDetails!.offset,
          totalScale: scale,
          gestureDetails: gestureDetails,
          actionType: ActionType.zoom,
          userOffset: false,
        );
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _slidePageState = null;
    if (widget.enableSlideOutPage) {
      _slidePageState =
          context.findAncestorStateOfType<ExtendedImageSlidePageState>();
    }
    _pageViewState = null;
    if (widget.inPageView) {
      _pageViewState =
          context.findAncestorStateOfType<ExtendedImageGesturePageViewState>();
      _pageViewState?.registerArbiter(this);
    }
  }

  @override
  void dispose() {
    _gestureAnimation.stop();
    _gestureAnimation.dispose();
    _doubleTapController?.dispose();
    _doubleTapController = null;
    _pageViewState?.unregisterArbiter(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget result = GestureDetector(
      onScaleStart: handleScaleStart,
      onScaleUpdate: handleScaleUpdate,
      onScaleEnd: handleScaleEnd,
      onDoubleTap: _handleDoubleTap,
      behavior: _gestureConfig.hitTestBehavior,
      child: widget.child,
    );

    result = Listener(
      onPointerDown: _handlePointerDown,
      onPointerSignal: _handlePointerSignal,
      behavior: _gestureConfig.hitTestBehavior,
      child: result,
    );

    return result;
  }

  // ===== DoubleTapTarget =====

  /// 双击缩放动画(unbounded,value 即缩放值)。持在手势层:与其他
  /// 动画一样被新指针落下打断,不会在真实拖拽开始后继续回灌
  /// handleScaleStart 清掉会话锚点。
  AnimationController? _doubleTapController;
  VoidCallback? _doubleTapTick;

  /// 进行中双击动画的目标(打断"缩回初始"时快进到终值用)
  double? _doubleTapTargetScale;
  Offset? _doubleTapTargetPosition;

  @override
  void animateDoubleTapZoom({
    required double targetScale,
    Offset? doubleTapPosition,
  }) {
    doubleTapPosition ??= _pointerDownPosition;
    final controller = _doubleTapController ??= AnimationController.unbounded(
      vsync: this,
    );
    if (_doubleTapTick != null) {
      controller.removeListener(_doubleTapTick!);
      _doubleTapTick = null;
    }
    controller.stop();

    final double begin =
        gestureDetails?.totalScale ?? _gestureConfig.initialScale;
    final Offset? position = doubleTapPosition;
    _doubleTapTargetScale = targetScale;
    _doubleTapTargetPosition = position;
    _doubleTapTick = () {
      handleDoubleTap(scale: controller.value, doubleTapPosition: position);
    };
    // 临界阻尼 k=400(ω=20)+ 朝目标初速 ω·Δ:解析解退化为纯指数
    // 衰减(快起慢收,95% 行程 ~150ms);零初速起步缓,双击缩小会
    // "挂"在满宽一瞬,不利落。
    const double omega = 20.0;
    controller
      ..value = begin
      ..addListener(_doubleTapTick!);
    controller
        .animateWith(
          SpringSimulation(
            SpringDescription.withDampingRatio(
              mass: 1,
              stiffness: omega * omega,
              ratio: 1,
            ),
            begin,
            targetScale,
            omega * (targetScale - begin),
          ),
        )
        .then((_) {
          // 仅自然完成时 resolve(被打断不触发):精确落到目标值,
          // 消掉弹簧容差残差(totalScale<=1 是下滑关闭的硬前提)
          if (!mounted) return;
          _doubleTapTargetScale = null;
          _doubleTapTargetPosition = null;
          handleDoubleTap(scale: targetScale, doubleTapPosition: position);
        });
  }

  @override
  void handleDoubleTap({double? scale, Offset? doubleTapPosition}) {
    doubleTapPosition ??= _pointerDownPosition;
    scale ??= _gestureConfig.initialScale;
    handleScaleStart(ScaleStartDetails(focalPoint: doubleTapPosition!));
    handleScaleUpdate(
      ScaleUpdateDetails(
        focalPoint: doubleTapPosition,
        scale: scale / _startingScale!,
        focalPointDelta: Offset.zero,
      ),
    );
    // 双击落点整备(仅落点帧生效:landed≈请求值):
    // 1. 锚点公式浮点往返留 ±1ULP 残差,请求值即真值,精确覆写;
    // 2. 落在初始倍率及以下时置 actionType=pan —— 下滑关闭门控要求
    //    pan,而合成 update 的落点帧写的是 zoom;快甩只有一个 update
    //    帧,残留 zoom 会把该帧吞成无效惯性,表现为「双击缩回后
    //    快速下甩时灵时不灵」。
    final GestureDetails? current = gestureDetails;
    final double? landed = current?.totalScale;
    if (current != null && landed != null && landed.equalTo(scale)) {
      final bool armSlide = scale.lessThanOrEqualTo(
        _gestureConfig.initialScale,
      );
      if (landed != scale ||
          (armSlide && current.actionType != ActionType.pan)) {
        gestureDetails = GestureDetails(
          offset: current.offset,
          totalScale: scale,
          gestureDetails: current,
          actionType: armSlide ? ActionType.pan : ActionType.zoom,
        );
      }
    }
    if (scale < _gestureConfig.minScale || scale > _gestureConfig.maxScale) {
      handleScaleEnd(ScaleEndDetails());
    }
  }

  void _handleDoubleTap() {
    if (widget.onDoubleTap != null) {
      widget.onDoubleTap!(this);
      return;
    }
    if (!mounted) {
      return;
    }
    gestureDetails = GestureDetails(
      offset: Offset.zero,
      totalScale: _gestureConfig.initialScale,
    );
  }

  // ===== 指针事件 =====

  void _handlePointerDown(PointerDownEvent pointerDownEvent) {
    _pointerDownPosition = pointerDownEvent.position;
    _gestureAnimation.stop();
    _stopDoubleTapAnimation();
    _pageViewState?.registerArbiter(this);
  }

  /// 停掉双击缩放动画(新指针落下/新会话开始时,防止旧动画继续
  /// 回灌 handleScaleStart 清掉真实拖拽的会话锚点)。
  ///
  /// 若被打断的动画目标是「缩回 ≤ 初始倍率」,直接快进到终值:
  /// 用户此刻的意图通常是"缩回后马上下滑关闭",让 scale 停在
  /// 1.0x 段(如 1.4)会卡住 totalScale<=1 的滑动关闭门控,表现为
  /// 时灵时不灵。放大方向不快进(中断放大再拖拽是自然操作)。
  void _stopDoubleTapAnimation() {
    final controller = _doubleTapController;
    if (controller == null) {
      return;
    }
    if (_doubleTapTick != null) {
      controller.removeListener(_doubleTapTick!);
      _doubleTapTick = null;
    }
    controller.stop();
    final double? target = _doubleTapTargetScale;
    final Offset? position = _doubleTapTargetPosition;
    _doubleTapTargetScale = null;
    _doubleTapTargetPosition = null;
    if (target != null &&
        position != null &&
        target.lessThanOrEqualTo(_gestureConfig.initialScale) &&
        !(gestureDetails?.totalScale ?? 1.0).equalTo(target)) {
      handleDoubleTap(scale: target, doubleTapPosition: position);
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.kind == PointerDeviceKind.mouse) {
      handleScaleStart(ScaleStartDetails(focalPoint: event.position));
      final double dy = event.scrollDelta.dy;
      final double dx = event.scrollDelta.dx;
      handleScaleUpdate(
        ScaleUpdateDetails(
          focalPoint: event.position,
          scale:
              1.0 +
              _reverseIf(
                (dy.abs() > dx.abs() ? dy : dx) * _gestureConfig.speed / 1000.0,
              ),
          focalPointDelta: Offset.zero,
        ),
      );
      handleScaleEnd(ScaleEndDetails());
    }
  }

  double _reverseIf(double scaleDetal) {
    if (_gestureConfig.reverseMousePointerScrollDirection) {
      return -scaleDetal;
    } else {
      return scaleDetal;
    }
  }

  // ===== 缩放/平移状态机(自 ExtendedImageGestureState 逐段搬运)=====

  @override
  void handleScaleStart(ScaleStartDetails details) {
    _gestureAnimation.stop();
    _normalizedOffset =
        (details.focalPoint - gestureDetails!.offset!) /
        gestureDetails!.totalScale!;
    _startingScale = gestureDetails!.totalScale;
    _startingOffset = details.focalPoint;
  }

  @override
  void handleScaleUpdate(ScaleUpdateDetails details) {
    if (_slidePageState != null &&
        details.scale == 1.0 &&
        (gestureDetails!.totalScale ?? 1) <= 1 &&
        gestureDetails!.userOffset &&
        gestureDetails!.actionType == ActionType.pan) {
      final Offset totalDelta = details.focalPointDelta;
      bool updateGesture = false;
      if (!_slidePageState!.isSliding) {
        final slideAxis = _slidePageState!.widget.slideAxis;
        // 水平方向主导：仅当 slideAxis 包含水平方向时才触发 slide
        if (slideAxis != SlideAxis.vertical &&
            totalDelta.dx != 0 &&
            totalDelta.dx.abs().greaterThan(totalDelta.dy.abs())) {
          if (gestureDetails!.computeHorizontalBoundary) {
            if (totalDelta.dx > 0) {
              updateGesture = gestureDetails!.boundary.left;
            } else {
              updateGesture = gestureDetails!.boundary.right;
            }
          } else {
            updateGesture = true;
          }
        }
        // 垂直方向主导：仅当 slideAxis 包含垂直方向时才触发 slide
        if (slideAxis != SlideAxis.horizontal &&
            totalDelta.dy != 0 &&
            totalDelta.dy.abs().greaterThan(totalDelta.dx.abs())) {
          if (gestureDetails!.computeVerticalBoundary) {
            if (totalDelta.dy < 0) {
              updateGesture = gestureDetails!.boundary.bottom;
            } else {
              updateGesture = gestureDetails!.boundary.top;
            }
          } else {
            updateGesture = true;
          }
        }
      } else {
        updateGesture = true;
      }
      final double delta = (details.focalPoint - _startingOffset).distance;
      if (delta.greaterThan(minGesturePageDelta) && updateGesture) {
        _slidePageState!.slide(details.focalPointDelta, controller: controller);
      }
    }

    if (_slidePageState != null && _slidePageState!.isSliding) {
      return;
    }

    // totalScale > 1 and page view is starting to move
    if (_pageViewState != null) {
      final ExtendedImageGesturePageViewState pageViewState = _pageViewState!;

      final Axis axis = pageViewState.widget.scrollDirection;
      final bool movePage =
          _pageViewState!.isDraging ||
          (details.pointerCount == 1 &&
              details.scale == 1 &&
              gestureDetails!.movePage(details.focalPointDelta, axis));

      if (movePage) {
        if (!pageViewState.isDraging) {
          pageViewState.onDragDown(
            DragDownDetails(globalPosition: details.focalPoint),
          );
          pageViewState.onDragStart(
            DragStartDetails(globalPosition: details.focalPoint),
          );
        }
        Offset delta = details.focalPointDelta;
        delta =
            axis == Axis.horizontal ? Offset(delta.dx, 0) : Offset(0, delta.dy);

        pageViewState.onDragUpdate(
          DragUpdateDetails(
            globalPosition: details.focalPoint,
            delta: delta,
            primaryDelta: axis == Axis.horizontal ? delta.dx : delta.dy,
          ),
        );

        return;
      }
    }
    final double? scale =
        widget.canScaleImage(gestureDetails)
            ? _clampScaleWithConfig(
              _startingScale! * details.scale * _gestureConfig.speed,
            )
            : gestureDetails!.totalScale;

    //no more zoom
    if (details.scale != 1.0 &&
        ((gestureDetails!.totalScale!.equalTo(
                  _gestureConfig.animationMinScale,
                ) &&
                scale!.lessThanOrEqualTo(gestureDetails!.totalScale!)) ||
            (gestureDetails!.totalScale!.equalTo(
                  _gestureConfig.animationMaxScale,
                ) &&
                scale!.greaterThanOrEqualTo(gestureDetails!.totalScale!)))) {
      return;
    }

    Offset offset =
        (details.scale == 1.0
            ? details.focalPoint * _gestureConfig.speed
            : _startingOffset) -
        _normalizedOffset * scale!;

    if (mounted &&
        (offset != gestureDetails!.offset ||
            scale != gestureDetails!.totalScale)) {
      gestureDetails = GestureDetails(
        offset: offset,
        totalScale: scale,
        gestureDetails: gestureDetails,
        actionType: details.scale != 1.0 ? ActionType.zoom : ActionType.pan,
      );
    }
  }

  /// 捏合缩放钳制:超出 [minScale, maxScale] 的部分按阻尼系数衰减
  /// (超上限 ×0.05 / 超下限 ×0.15)—— 越界越捏越重;
  /// animationMin/Max 仍为硬顶。
  double _clampScaleWithConfig(double raw) {
    double result = raw;
    if (raw > _gestureConfig.maxScale) {
      result = _gestureConfig.maxScale + (raw - _gestureConfig.maxScale) * 0.05;
    } else if (raw < _gestureConfig.minScale) {
      result = _gestureConfig.minScale - (_gestureConfig.minScale - raw) * 0.15;
    }
    return clampScale(
      result,
      _gestureConfig.animationMinScale,
      _gestureConfig.animationMaxScale,
    );
  }

  @override
  void handleScaleEnd(ScaleEndDetails details) {
    if (_slidePageState != null && _slidePageState!.isSliding) {
      _slidePageState!.endSlide(details);
      return;
    }

    if (_pageViewState != null && _pageViewState!.isDraging) {
      _pageViewState!.onDragEnd(
        DragEndDetails(
          velocity:
              _pageViewState!.widget.scrollDirection == Axis.horizontal
                  ? Velocity(
                    pixelsPerSecond: Offset(
                      details.velocity.pixelsPerSecond.dx,
                      0,
                    ),
                  )
                  : Velocity(
                    pixelsPerSecond: Offset(
                      0,
                      details.velocity.pixelsPerSecond.dy,
                    ),
                  ),
          primaryVelocity:
              _pageViewState!.widget.scrollDirection == Axis.horizontal
                  ? details.velocity.pixelsPerSecond.dx
                  : details.velocity.pixelsPerSecond.dy,
        ),
      );
      return;
    }

    //animate back to maxScale if gesture exceeded the maxScale specified
    if (gestureDetails!.totalScale!.greaterThan(_gestureConfig.maxScale)) {
      _gestureAnimation.animationScaleSpring(
        gestureDetails!.totalScale!,
        _gestureConfig.maxScale,
      );
      return;
    }

    //animate back to minScale if gesture fell smaller than the minScale specified
    if (gestureDetails!.totalScale!.lessThan(_gestureConfig.minScale)) {
      _gestureAnimation.animationScaleSpring(
        gestureDetails!.totalScale!,
        _gestureConfig.minScale,
      );
      return;
    }

    // ===== 惯性滑动处理(摩擦衰减,撞边即停) =====
    if (gestureDetails!.actionType == ActionType.pan) {
      final layoutRect = gestureDetails!.layoutRect;
      final destinationRect = gestureDetails!.destinationRect;
      final currentOffset = gestureDetails!.offset;
      if (layoutRect == null || destinationRect == null || currentOffset == null) {
        return;
      }

      final double magnitude = details.velocity.pixelsPerSecond.distance;
      if (magnitude < _minInertiaVelocity) {
        return;
      }

      // 基于当前 destinationRect 与 layoutRect 的相对位置计算边界
      double minX, maxX, minY, maxY;

      if (destinationRect.width > layoutRect.width) {
        // 图片比视口宽，计算允许的滑动范围
        // 往左滑动（offset.dx 减小）的极限：图片右边与视口右边对齐
        minX = currentOffset.dx - (destinationRect.right - layoutRect.right);
        // 往右滑动（offset.dx 增大）的极限：图片左边与视口左边对齐
        maxX = currentOffset.dx + (layoutRect.left - destinationRect.left);
      } else {
        // 图片比视口窄，不允许水平滑动
        minX = currentOffset.dx;
        maxX = currentOffset.dx;
      }

      if (destinationRect.height > layoutRect.height) {
        // 图片比视口高，计算允许的滑动范围
        // 往上滑动（offset.dy 减小）的极限：图片底边与视口底边对齐
        minY = currentOffset.dy - (destinationRect.bottom - layoutRect.bottom);
        // 往下滑动（offset.dy 增大）的极限：图片顶边与视口顶边对齐
        maxY = currentOffset.dy + (layoutRect.top - destinationRect.top);
      } else {
        // 图片比视口矮，不允许垂直滑动
        minY = currentOffset.dy;
        maxY = currentOffset.dy;
      }

      _gestureAnimation.animateInertia(
        currentOffset,
        details.velocity.pixelsPerSecond,
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
      );
    }
  }

  /// 惯性最低启动速度(px/s)
  static const double _minInertiaVelocity = 50.0;
}
