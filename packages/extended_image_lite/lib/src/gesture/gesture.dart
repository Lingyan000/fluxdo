import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../image/raw_image.dart';
import '../utils.dart';
import '../typedef.dart';
import 'page_view/gesture_page_view.dart';
import 'slide_page.dart';
import 'utils.dart';

Map<Object?, GestureDetails?> _gestureDetailsCache =
    <Object?, GestureDetails?>{};

///clear the gesture details
void clearGestureDetailsCache() {
  _gestureDetailsCache.clear();
}

bool _defaultCanScaleImage(GestureDetails? details) => true;

/// scale idea from https://github.com/flutter/flutter/blob/master/examples/layers/widgets/gestures.dart
/// zoom image
class ExtendedImageGesture extends StatefulWidget {
  const ExtendedImageGesture(
    this.extendedImageState, {
    this.imageBuilder,
    CanScaleImage? canScaleImage,
    super.key,
  }) : canScaleImage = canScaleImage ?? _defaultCanScaleImage;
  final ExtendedImageState extendedImageState;
  final ImageBuilderForGesture? imageBuilder;
  final CanScaleImage canScaleImage;
  @override
  ExtendedImageGestureState createState() => ExtendedImageGestureState();
}

class ExtendedImageGestureState extends State<ExtendedImageGesture>
    with TickerProviderStateMixin {
  ///details for gesture
  GestureDetails? _gestureDetails;
  late Offset _normalizedOffset;
  double? _startingScale;
  late Offset _startingOffset;
  Offset? _pointerDownPosition;
  late GestureAnimation _gestureAnimation;
  bool _isGestureAnimationInitialized = false;
  GestureConfig? _gestureConfig;
  ExtendedImageGesturePageViewState? _pageViewState;
  ExtendedImageSlidePageState? get extendedImageSlidePageState =>
      widget.extendedImageState.slidePageState;

  GestureDetails? get gestureDetails => _gestureDetails;

  set gestureDetails(GestureDetails? value) {
    if (mounted) {
      setState(() {
        _gestureDetails = value;
        _gestureConfig?.gestureDetailsIsChanged?.call(_gestureDetails);
      });
    }
  }

  GestureConfig? get imageGestureConfig => _gestureConfig;

  Offset? get pointerDownPosition => _pointerDownPosition;

  @override
  Widget build(BuildContext context) {
    if (_gestureConfig!.cacheGesture) {
      _gestureDetailsCache[widget.extendedImageState.imageStreamKey] =
          _gestureDetails;
    }

    Widget image = ExtendedRawImage(
      image: widget.extendedImageState.extendedImageInfo?.image,
      width: widget.extendedImageState.imageWidget.width,
      height: widget.extendedImageState.imageWidget.height,
      scale: widget.extendedImageState.extendedImageInfo?.scale ?? 1.0,
      color: widget.extendedImageState.imageWidget.color,
      colorBlendMode: widget.extendedImageState.imageWidget.colorBlendMode,
      fit: widget.extendedImageState.imageWidget.fit,
      alignment: widget.extendedImageState.imageWidget.alignment,
      repeat: widget.extendedImageState.imageWidget.repeat,
      centerSlice: widget.extendedImageState.imageWidget.centerSlice,
      matchTextDirection:
          widget.extendedImageState.imageWidget.matchTextDirection,
      invertColors: widget.extendedImageState.invertColors,
      filterQuality: widget.extendedImageState.imageWidget.filterQuality,
      beforePaintImage: widget.extendedImageState.imageWidget.beforePaintImage,
      afterPaintImage: widget.extendedImageState.imageWidget.afterPaintImage,
      gestureDetails: _gestureDetails,
      layoutInsets: widget.extendedImageState.imageWidget.layoutInsets,
    );

    if (extendedImageSlidePageState != null) {
      image =
          widget.extendedImageState.imageWidget.heroBuilderForSlidingPage?.call(
            image,
          ) ??
          image;
      if (extendedImageSlidePageState!.widget.slideType ==
          SlideType.onlyImage) {
        image = Transform.translate(
          offset: extendedImageSlidePageState!.offset,
          child: Transform.scale(
            scale: extendedImageSlidePageState!.scale,
            child: image,
          ),
        );
      }
    }

    image = widget.imageBuilder?.call(image, imageGestureState: this) ?? image;

    image = GestureDetector(
      onScaleStart: handleScaleStart,
      onScaleUpdate: handleScaleUpdate,
      onScaleEnd: handleScaleEnd,
      onDoubleTap: _handleDoubleTap,
      behavior: _gestureConfig?.hitTestBehavior,
      child: image,
    );

    image = Listener(
      onPointerDown: _handlePointerDown,
      onPointerSignal: _handlePointerSignal,
      behavior: _gestureConfig!.hitTestBehavior,
      child: image,
    );

    return image;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageViewState = null;
    if (_gestureConfig!.inPageView) {
      _pageViewState =
          context.findAncestorStateOfType<ExtendedImageGesturePageViewState>();
      _pageViewState?.extendedImageGestureState = this;
    }
  }

  @override
  void didUpdateWidget(ExtendedImageGesture oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initGestureConfig();
    _pageViewState = null;
    if (_gestureConfig!.inPageView) {
      _pageViewState =
          context.findAncestorStateOfType<ExtendedImageGesturePageViewState>();
      _pageViewState?.extendedImageGestureState = this;
    }
  }

  @override
  void dispose() {
    _gestureAnimation.stop();
    _gestureAnimation.dispose();
    _pageViewState?.extendedImageGestureStates.remove(this);

    // 如果正在驱动滑动关闭时被销毁（如图片加载状态变化导致 widget 树重建），
    // 需要通知 SlidePageState 结束滑动，避免页面卡在中间位置
    if (extendedImageSlidePageState != null &&
        extendedImageSlidePageState!.isSliding) {
      final slidePageState = extendedImageSlidePageState!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (slidePageState.mounted && slidePageState.isSliding) {
          slidePageState.endSlide(ScaleEndDetails());
        }
      });
    }

    super.dispose();
  }

  void handleDoubleTap({double? scale, Offset? doubleTapPosition}) {
    doubleTapPosition ??= _pointerDownPosition;
    scale ??= _gestureConfig!.initialScale;
    handleScaleStart(ScaleStartDetails(focalPoint: doubleTapPosition!));
    handleScaleUpdate(
      ScaleUpdateDetails(
        focalPoint: doubleTapPosition,
        scale: scale / _startingScale!,
        focalPointDelta: Offset.zero,
      ),
    );
    if (scale < _gestureConfig!.minScale || scale > _gestureConfig!.maxScale) {
      handleScaleEnd(ScaleEndDetails());
    }
  }

  @override
  void initState() {
    super.initState();
    _initGestureConfig();
    // 滑动关闭进行中因树重建(如大图加载完成替换 loading 层)而新建时,
    // 接管滑动驱动 —— 否则回弹/结算动画只通知旧(已卸载)载体,图片
    // 定格在切换瞬间的偏移处
    extendedImageSlidePageState?.rebindSlideTarget(gestureState: this);
  }

  void reset() {
    _gestureConfig =
        widget.extendedImageState.imageWidget.initGestureConfigHandler?.call(
          widget.extendedImageState,
        ) ??
        GestureConfig();

    gestureDetails = GestureDetails(
      totalScale: _gestureConfig!.initialScale,
      offset: Offset.zero,
      initialAlignment: _gestureConfig!.initialAlignment,
    );
  }

  void slide() {
    if (mounted) {
      setState(() {
        _gestureDetails!.slidePageOffset = extendedImageSlidePageState?.offset;
      });
    }
  }

  void _handleDoubleTap() {
    if (widget.extendedImageState.imageWidget.onDoubleTap != null) {
      widget.extendedImageState.imageWidget.onDoubleTap!(this);
      return;
    }

    if (!mounted) {
      return;
    }

    gestureDetails = GestureDetails(
      offset: Offset.zero,
      totalScale: _gestureConfig!.initialScale,
    );
  }

  void _handlePointerDown(PointerDownEvent pointerDownEvent) {
    _pointerDownPosition = pointerDownEvent.position;
    _gestureAnimation.stop();

    _pageViewState?.extendedImageGestureState = this;
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
                (dy.abs() > dx.abs() ? dy : dx) *
                    _gestureConfig!.speed /
                    1000.0,
              ),
          focalPointDelta: Offset.zero,
        ),
      );
      handleScaleEnd(ScaleEndDetails());
    }
  }

  void handleScaleEnd(ScaleEndDetails details) {
    if (extendedImageSlidePageState != null &&
        extendedImageSlidePageState!.isSliding) {
      extendedImageSlidePageState!.endSlide(details);
      return;
    }

    // 兜底：isSliding 已为 false 但页面仍处于偏移状态（竞态导致），强制回弹
    if (extendedImageSlidePageState != null) {
      extendedImageSlidePageState!.resetIfNeeded();
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
    if (_gestureDetails!.totalScale!.greaterThan(_gestureConfig!.maxScale)) {
      final double velocity =
          (_gestureDetails!.totalScale! - _gestureConfig!.maxScale) /
          _gestureConfig!.maxScale;

      _gestureAnimation.animationScale(
        _gestureDetails!.totalScale,
        _gestureConfig!.maxScale,
        velocity,
      );
      return;
    }

    //animate back to minScale if gesture fell smaller than the minScale specified
    if (_gestureDetails!.totalScale!.lessThan(_gestureConfig!.minScale)) {
      final double velocity =
          (_gestureConfig!.minScale - _gestureDetails!.totalScale!) /
          _gestureConfig!.minScale;

      _gestureAnimation.animationScale(
        _gestureDetails!.totalScale,
        _gestureConfig!.minScale,
        velocity,
      );
      return;
    }

    // ===== 惯性滑动处理 =====
    if (_gestureDetails!.actionType == ActionType.pan) {
      final layoutRect = _gestureDetails!.layoutRect;
      final destinationRect = _gestureDetails!.destinationRect;
      final currentOffset = _gestureDetails!.offset!;
      final physics = _gestureConfig!.inertiaPhysics;

      // 处理惯性滑动
      final double magnitude = details.velocity.pixelsPerSecond.distance;

      if (magnitude >= physics.minVelocity && layoutRect != null && destinationRect != null) {
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

        // 启动惯性滑动动画
        _gestureAnimation.animateInertia(
          currentOffset,
          details.velocity.pixelsPerSecond,
          physics,
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
        );
      }
    }
  }

  void handleScaleStart(ScaleStartDetails details) {
    _gestureAnimation.stop();
    _normalizedOffset =
        (details.focalPoint - _gestureDetails!.offset!) /
        _gestureDetails!.totalScale!;
    _startingScale = _gestureDetails!.totalScale;
    _startingOffset = details.focalPoint;
  }

  void handleScaleUpdate(ScaleUpdateDetails details) {
    if (extendedImageSlidePageState != null &&
        details.scale == 1.0 &&
        (_gestureDetails!.totalScale ?? 1) <= 1 &&
        _gestureDetails!.userOffset &&
        _gestureDetails!.actionType == ActionType.pan) {
      final Offset totalDelta = details.focalPointDelta;
      bool updateGesture = false;
      if (!extendedImageSlidePageState!.isSliding) {
        final slideAxis = extendedImageSlidePageState!.widget.slideAxis;
        // 水平方向主导：仅当 slideAxis 包含水平方向时才触发 slide
        if (slideAxis != SlideAxis.vertical &&
            totalDelta.dx != 0 &&
            totalDelta.dx.abs().greaterThan(totalDelta.dy.abs())) {
          if (_gestureDetails!.computeHorizontalBoundary) {
            if (totalDelta.dx > 0) {
              updateGesture = _gestureDetails!.boundary.left;
            } else {
              updateGesture = _gestureDetails!.boundary.right;
            }
          } else {
            updateGesture = true;
          }
        }
        // 垂直方向主导：仅当 slideAxis 包含垂直方向时才触发 slide
        if (slideAxis != SlideAxis.horizontal &&
            totalDelta.dy != 0 &&
            totalDelta.dy.abs().greaterThan(totalDelta.dx.abs())) {
          if (_gestureDetails!.computeVerticalBoundary) {
            if (totalDelta.dy < 0) {
              updateGesture = _gestureDetails!.boundary.bottom;
            } else {
              updateGesture = _gestureDetails!.boundary.top;
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
        extendedImageSlidePageState!.slide(
          details.focalPointDelta,
          extendedImageGestureState: this,
        );
      }
    }

    if (extendedImageSlidePageState != null &&
        extendedImageSlidePageState!.isSliding) {
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
              _gestureDetails!.movePage(details.focalPointDelta, axis));

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
        widget.canScaleImage(_gestureDetails)
            ? clampScale(
              _startingScale! * details.scale * _gestureConfig!.speed,
              _gestureConfig!.animationMinScale,
              _gestureConfig!.animationMaxScale,
            )
            : _gestureDetails!.totalScale;

    //no more zoom
    if (details.scale != 1.0 &&
        ((_gestureDetails!.totalScale!.equalTo(
                  _gestureConfig!.animationMinScale,
                ) &&
                scale!.lessThanOrEqualTo(_gestureDetails!.totalScale!)) ||
            (_gestureDetails!.totalScale!.equalTo(
                  _gestureConfig!.animationMaxScale,
                ) &&
                scale!.greaterThanOrEqualTo(_gestureDetails!.totalScale!)))) {
      return;
    }

    Offset offset =
        (details.scale == 1.0
            ? details.focalPoint * _gestureConfig!.speed
            : _startingOffset) -
        _normalizedOffset * scale!;

    if (mounted &&
        (offset != _gestureDetails!.offset ||
            scale != _gestureDetails!.totalScale)) {
      gestureDetails = GestureDetails(
        offset: offset,
        totalScale: scale,
        gestureDetails: _gestureDetails,
        actionType: details.scale != 1.0 ? ActionType.zoom : ActionType.pan,
      );
    }
  }

  void _initGestureConfig() {
    final double? initialScale = _gestureConfig?.initialScale;
    final InitialAlignment? initialAlignment = _gestureConfig?.initialAlignment;
    _gestureConfig =
        widget.extendedImageState.imageWidget.initGestureConfigHandler?.call(
          widget.extendedImageState,
        ) ??
        GestureConfig();

    if (_gestureDetails == null ||
        initialScale != _gestureConfig!.initialScale ||
        initialAlignment != _gestureConfig!.initialAlignment) {
      _gestureDetails = GestureDetails(
        totalScale: _gestureConfig!.initialScale,
        offset: Offset.zero,
        initialAlignment: _gestureConfig!.initialAlignment,
      );
    }

    if (_gestureConfig!.cacheGesture) {
      final GestureDetails? cache =
          _gestureDetailsCache[widget.extendedImageState.imageStreamKey];
      if (cache != null) {
        _gestureDetails = cache;
      }
    }
    _gestureDetails ??= GestureDetails(
      totalScale: _gestureConfig!.initialScale,
      offset: Offset.zero,
    );

    // 释放旧的手势动画，避免 Ticker 泄漏
    if (_isGestureAnimationInitialized) {
      _gestureAnimation.stop();
      _gestureAnimation.dispose();
    }
    _isGestureAnimationInitialized = true;

    _gestureAnimation = GestureAnimation(
      this,
      offsetCallBack: (Offset value) {
        gestureDetails = GestureDetails(
          offset: value,
          totalScale: _gestureDetails!.totalScale,
          gestureDetails: _gestureDetails,
        );
      },
      scaleCallBack: (double scale) {
        gestureDetails = GestureDetails(
          offset: _gestureDetails!.offset,
          totalScale: scale,
          gestureDetails: _gestureDetails,
          actionType: ActionType.zoom,
          userOffset: false,
        );
      },
    );
  }

  double _reverseIf(double scaleDetal) {
    if (_gestureConfig?.reverseMousePointerScrollDirection ?? false) {
      return -scaleDetal;
    } else {
      return scaleDetal;
    }
  }

  Widget wrapGestureWidget(
    Widget child, {
    double? imageWidth,
    double? imageHeight,
    BoxFit? imageFit,
    Rect? rect,
    bool copy = false,
  }) {
    child = CustomSingleChildLayout(
      delegate: GestureWidgetDelegateFromState(
        this,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        imageFit: imageFit,
        rect: rect,
        copy: copy,
      ),
      child: child,
    );

    if (extendedImageSlidePageState != null) {
      child =
          widget.extendedImageState.imageWidget.heroBuilderForSlidingPage?.call(
            child,
          ) ??
          child;
      if (extendedImageSlidePageState!.widget.slideType ==
          SlideType.onlyImage) {
        child = Transform.translate(
          offset: extendedImageSlidePageState!.offset,
          child: Transform.scale(
            scale: extendedImageSlidePageState!.scale,
            child: child,
          ),
        );
      }
    }

    return child;
  }
}

class GestureWidgetDelegateFromState extends SingleChildLayoutDelegate {
  GestureWidgetDelegateFromState(
    this.state, {
    this.imageFit,
    this.imageHeight,
    this.imageWidth,
    this.rect,
    this.copy = false,
  });

  final ExtendedImageGestureState state;
  final double? imageWidth;
  final double? imageHeight;
  final BoxFit? imageFit;
  final Rect? rect;
  final bool copy;

  Rect? destinationRect;

  Rect _getDestinationRect(Rect rect) {
    return destinationRect ??= GestureWidgetDelegateFromState.getRectFormState(
      rect,
      state,
      width: imageWidth,
      height: imageHeight,
      fit: imageFit,
      copy: copy,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return _getDestinationRect(rect ?? (Offset.zero & size)).topLeft;
  }

  @override
  bool shouldRelayout(GestureWidgetDelegateFromState oldDelegate) {
    return destinationRect != oldDelegate.destinationRect ||
        imageWidth != oldDelegate.imageWidth ||
        imageHeight != oldDelegate.imageHeight ||
        imageFit != oldDelegate.imageFit ||
        rect != oldDelegate.rect ||
        copy != oldDelegate.copy;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.tight(
      _getDestinationRect(rect ?? Offset.zero & constraints.biggest).size,
    );
  }

  @override
  Size getSize(BoxConstraints constraints) {
    destinationRect = _getDestinationRect(
      rect ?? Offset.zero & constraints.biggest,
    );
    return super.getSize(constraints);
  }

  static Rect getRectFormState(
    Rect rect,
    ExtendedImageGestureState state, {
    double? width,
    double? height,
    BoxFit? fit,
    bool copy = false,
  }) {
    final GestureDetails? gestureDetails = state.gestureDetails;

    if (gestureDetails != null && gestureDetails.slidePageOffset != null) {
      rect = rect.shift(-gestureDetails.slidePageOffset!);
    }

    Rect destinationRect = _computeDestinationRect(
      rect: rect,
      inputSize: Size(
        width ??
            state.widget.extendedImageState.extendedImageInfo!.image.width
                .toDouble(),
        height ??
            state.widget.extendedImageState.extendedImageInfo!.image.height
                .toDouble(),
      ),
      fit: fit ?? state.widget.extendedImageState.imageWidget.fit,
    );

    if (gestureDetails != null) {
      GestureDetails gd = gestureDetails;
      if (copy) {
        gd = gestureDetails.copy();
      }
      destinationRect = gd.calculateFinalDestinationRect(rect, destinationRect);

      if (gd.slidePageOffset != null) {
        destinationRect = destinationRect.shift(gd.slidePageOffset!);
      }
    }
    return destinationRect;
  }
}

class GestureWidgetDelegateFromRect extends SingleChildLayoutDelegate {
  GestureWidgetDelegateFromRect(this.destinationRect);

  final Rect destinationRect;
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return destinationRect.topLeft;
  }

  @override
  bool shouldRelayout(GestureWidgetDelegateFromState oldDelegate) {
    return destinationRect != oldDelegate.destinationRect;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.tight(destinationRect.size);
  }
}

/// Helper function to calculate destination rect
Rect _computeDestinationRect({
  required Rect rect,
  required Size inputSize,
  BoxFit? fit,
}) {
  Size outputSize = rect.size;
  Size sourceSize = inputSize;
  final BoxFit fittedSize = fit ?? BoxFit.contain;

  late final Size fittedSizes;
  switch (fittedSize) {
    case BoxFit.fill:
      fittedSizes = outputSize;
      break;
    case BoxFit.contain:
      fittedSizes = _applyBoxFitInternal(BoxFit.contain, sourceSize, outputSize);
      break;
    case BoxFit.cover:
      fittedSizes = _applyBoxFitInternal(BoxFit.cover, sourceSize, outputSize);
      break;
    case BoxFit.fitWidth:
      fittedSizes = Size(outputSize.width, sourceSize.height * outputSize.width / sourceSize.width);
      break;
    case BoxFit.fitHeight:
      fittedSizes = Size(sourceSize.width * outputSize.height / sourceSize.height, outputSize.height);
      break;
    case BoxFit.none:
      fittedSizes = sourceSize;
      break;
    case BoxFit.scaleDown:
      fittedSizes = _applyBoxFitInternal(BoxFit.scaleDown, sourceSize, outputSize);
      break;
  }

  final double dx = (outputSize.width - fittedSizes.width) / 2.0;
  final double dy = (outputSize.height - fittedSizes.height) / 2.0;

  return Rect.fromLTWH(
    rect.left + dx,
    rect.top + dy,
    fittedSizes.width,
    fittedSizes.height,
  );
}

Size _applyBoxFitInternal(BoxFit fit, Size inputSize, Size outputSize) {
  if (inputSize.height <= 0.0 || inputSize.width <= 0.0 || outputSize.height <= 0.0 || outputSize.width <= 0.0) {
    return Size.zero;
  }

  Size fittedSize;
  switch (fit) {
    case BoxFit.contain:
      if (outputSize.width / outputSize.height > inputSize.width / inputSize.height) {
        fittedSize = Size(inputSize.width * outputSize.height / inputSize.height, outputSize.height);
      } else {
        fittedSize = Size(outputSize.width, inputSize.height * outputSize.width / inputSize.width);
      }
      break;
    case BoxFit.cover:
      if (outputSize.width / outputSize.height > inputSize.width / inputSize.height) {
        fittedSize = Size(outputSize.width, inputSize.height * outputSize.width / inputSize.width);
      } else {
        fittedSize = Size(inputSize.width * outputSize.height / inputSize.height, outputSize.height);
      }
      break;
    case BoxFit.scaleDown:
      fittedSize = _applyBoxFitInternal(BoxFit.contain, inputSize, outputSize);
      if (fittedSize.width > inputSize.width || fittedSize.height > inputSize.height) {
        fittedSize = inputSize;
      }
      break;
    default:
      fittedSize = inputSize;
  }
  return fittedSize;
}
