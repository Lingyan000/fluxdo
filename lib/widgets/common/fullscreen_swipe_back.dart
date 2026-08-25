// 手势部分拷贝自 Flutter 3.44 cupertino/route.dart 的
// _CupertinoBackGestureDetector / _CupertinoBackGestureController
// (BSD 许可,版权归 The Flutter Authors)。
//
// 拷贝原因:官方返回手势的探测区硬编码在屏幕左缘 20px(_kBackGestureWidth,
// 私有常量,无公开参数可调),"全屏任意位置右滑返回"只能自带一份探测器。
// 驱动转场沿用官方私有 controller 的逐帧逻辑(fling 速度判定 + 350ms
// fastEaseInToSlowEaseOut 滑出);公开的 handleCommitBackGesture 是给
// Android 预测返回设计的(commit 后从 1.0 整段重播),不适合跟手拖拽。
//
// 与原文件的差异(其余逐行保真,升级 Flutter 后 diff 上游同步):
// 1. 探测区从左缘竖条(Stack + PositionedDirectional)改为整页 Listener
//    直接包住 child,translucent 不影响页面自身命中;
// 2. 新增 FullscreenSwipeBackTransitionsBuilder 装饰器,把探测器插进
//    任意 inner builder 的转场树;fullscreenDialog 与官方约定一致不挂
//    水平返回手势。
// 3. 落点命中平台视图(WebView 等)时不参赛。平台视图的手势代理只有
//    在竞技场独占时才立即获胜并实时转发触摸给原生视图;返回手势一旦
//    入场,裁决要拖到抬手 sweep,原生视图整个拖拽期间收不到事件,
//    上下左右滚动全部失效。这些区域让位后仍可用屏幕左缘官方手势返回。
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

const double _kMinFlingVelocity = 1.0; // Screen widths per second.

// The duration it takes for a dropped swipe page animation to complete.
const Duration _kDroppedSwipePageAnimationDuration = Duration(milliseconds: 350);

/// 全屏侧滑返回装饰器:转场视觉完全委托 [inner],仅在转场树里追加一个
/// 覆盖整页的 iOS 式返回手势探测器。
///
/// 与页面内水平滚动组件(PageView、代码块等)在手势竞技场公平竞争:
/// 命中路径更深的滚动组件先越过 touch slop 即获胜,返回手势自动让位,
/// 这些区域内仍可用屏幕左缘的官方边缘手势返回。
class FullscreenSwipeBackTransitionsBuilder extends PageTransitionsBuilder {
  const FullscreenSwipeBackTransitionsBuilder(this.inner);

  /// 提供转场视觉(及边缘手势)的原 builder。
  final PageTransitionsBuilder inner;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => inner.delegatedTransition;

  @override
  Duration get transitionDuration => inner.transitionDuration;

  @override
  Duration get reverseTransitionDuration => inner.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 竖向弹出的 fullscreenDialog 不挂水平返回手势(官方 Cupertino 同约定)。
    if (route.fullscreenDialog) {
      return inner.buildTransitions(route, context, animation, secondaryAnimation, child);
    }
    return inner.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      _FullscreenBackGestureDetector<T>(
        enabledCallback: () => route.popGestureEnabled,
        onStartPopGesture: () => _startPopGesture<T>(route),
        child: child,
      ),
    );
  }
}

// Called by _FullscreenBackGestureDetector when a pop ("back") drag start
// gesture is detected. The returned controller handles all of the subsequent
// drag events.
_FullscreenBackGestureController<T> _startPopGesture<T>(PageRoute<T> route) {
  assert(route.popGestureEnabled);

  return _FullscreenBackGestureController<T>(
    navigator: route.navigator!,
    getIsCurrent: () => route.isCurrent,
    getIsActive: () => route.isActive,
    // ignore: invalid_use_of_protected_member
    controller: route.controller!, // protected access
  );
}

/// This is the widget side of [_FullscreenBackGestureController].
///
/// This widget provides a gesture recognizer which, when it determines the
/// route can be closed with a back gesture, creates the controller and
/// feeds it the input from the gesture recognizer.
///
/// The gesture data is converted from absolute coordinates to logical
/// coordinates by this widget.
///
/// The type `T` specifies the return type of the route with which this gesture
/// detector is associated.
class _FullscreenBackGestureDetector<T> extends StatefulWidget {
  const _FullscreenBackGestureDetector({
    super.key,
    required this.enabledCallback,
    required this.onStartPopGesture,
    required this.child,
  });

  final Widget child;

  final ValueGetter<bool> enabledCallback;

  final ValueGetter<_FullscreenBackGestureController<T>> onStartPopGesture;

  @override
  _FullscreenBackGestureDetectorState<T> createState() =>
      _FullscreenBackGestureDetectorState<T>();
}

class _FullscreenBackGestureDetectorState<T>
    extends State<_FullscreenBackGestureDetector<T>> {
  _FullscreenBackGestureController<T>? _backGestureController;

  late HorizontalDragGestureRecognizer _recognizer;

  @override
  void initState() {
    super.initState();
    _recognizer = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onStart = _handleDragStart
      ..onUpdate = _handleDragUpdate
      ..onEnd = _handleDragEnd
      ..onCancel = _handleDragCancel;
  }

  @override
  void dispose() {
    _recognizer.dispose();

    // If this is disposed during a drag, call navigator.didStopUserGesture.
    if (_backGestureController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_backGestureController?.navigator.mounted ?? false) {
          _backGestureController?.navigator.didStopUserGesture();
        }
        _backGestureController = null;
      });
    }
    super.dispose();
  }

  void _handleDragStart(DragStartDetails details) {
    assert(mounted);
    assert(_backGestureController == null);
    _backGestureController = widget.onStartPopGesture();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    assert(mounted);
    assert(_backGestureController != null);
    _backGestureController!.dragUpdate(
      _convertToLogical(details.primaryDelta! / context.size!.width),
    );
  }

  void _handleDragEnd(DragEndDetails details) {
    assert(mounted);
    assert(_backGestureController != null);
    _backGestureController!.dragEnd(
      _convertToLogical(details.velocity.pixelsPerSecond.dx / context.size!.width),
    );
    _backGestureController = null;
  }

  void _handleDragCancel() {
    assert(mounted);
    // This can be called even if start is not called, paired with the "down" event
    // that we don't consider here.
    _backGestureController?.dragEnd(0.0);
    _backGestureController = null;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.enabledCallback() && !_hitsPlatformView(event)) {
      _recognizer.addPointer(event);
    }
  }

  /// 落点是否命中平台视图(WebView 等原生视图)。
  ///
  /// 平台视图的手势代理只有独占竞技场时才立即获胜并实时转发触摸;
  /// 返回手势参赛会把裁决拖到抬手,原生视图整个拖拽期间收不到事件,
  /// 内部滚动全部失效,因此这里直接弃权(左缘官方手势仍可用)。
  bool _hitsPlatformView(PointerDownEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is PlatformViewRenderBox ||
          target is RenderDarwinPlatformView) {
        return true;
      }
    }
    return false;
  }

  double _convertToLogical(double value) {
    return switch (Directionality.of(context)) {
      TextDirection.rtl => -value,
      TextDirection.ltr => value,
    };
  }

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasDirectionality(context));
    // 差异点:官方在 child 上叠一条左缘 20px 的探测竖条,这里整页监听;
    // translucent 只旁路收集 pointer,页面自身命中与滚动不受影响。
    return Listener(
      onPointerDown: _handlePointerDown,
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}

/// A controller for an iOS-style back gesture.
///
/// This is created by a [FullscreenSwipeBackTransitionsBuilder] in response
/// from a gesture caught by a [_FullscreenBackGestureDetector] widget, which
/// then also feeds it input from the gesture. It controls the animation
/// controller owned by the route, based on the input provided by the gesture
/// detector.
///
/// This class works entirely in logical coordinates (0.0 is new page
/// dismissed, 1.0 is new page on top).
///
/// The type `T` specifies the return type of the route with which this gesture
/// detector controller is associated.
class _FullscreenBackGestureController<T> {
  /// Creates a controller for an iOS-style back gesture.
  _FullscreenBackGestureController({
    required this.navigator,
    required this.controller,
    required this.getIsActive,
    required this.getIsCurrent,
  }) {
    navigator.didStartUserGesture();
  }

  final AnimationController controller;
  final NavigatorState navigator;
  final ValueGetter<bool> getIsActive;
  final ValueGetter<bool> getIsCurrent;

  /// The drag gesture has changed by [delta]. The total range of the drag
  /// should be 0.0 to 1.0.
  void dragUpdate(double delta) {
    controller.value -= delta;
  }

  /// The drag gesture has ended with a horizontal motion of [velocity] as a
  /// fraction of screen width per second.
  void dragEnd(double velocity) {
    // Fling in the appropriate direction.
    //
    // This curve has been determined through rigorously eyeballing native iOS
    // animations.
    const Curve animationCurve = Curves.fastEaseInToSlowEaseOut;
    final bool isCurrent = getIsCurrent();
    final bool animateForward;

    if (!isCurrent) {
      // If the page has already been navigated away from, then the animation
      // direction depends on whether or not it's still in the navigation stack,
      // regardless of velocity or drag position. For example, if a route is
      // being slowly dragged back by just a few pixels, but then a programmatic
      // pop occurs, the route should still be animated off the screen.
      // See https://github.com/flutter/flutter/issues/141268.
      animateForward = getIsActive();
    } else if (velocity.abs() >= _kMinFlingVelocity) {
      // If the user releases the page before mid screen with sufficient velocity,
      // or after mid screen, we should animate the page out. Otherwise, the page
      // should be animated back in.
      animateForward = velocity <= 0;
    } else {
      animateForward = controller.value > 0.5;
    }

    if (animateForward) {
      controller.animateTo(
        1.0,
        duration: _kDroppedSwipePageAnimationDuration,
        curve: animationCurve,
      );
    } else {
      if (isCurrent) {
        // This route is destined to pop at this point. Reuse navigator's pop.
        navigator.pop();
      }

      // The popping may have finished inline if already at the target destination.
      if (controller.isAnimating) {
        controller.animateBack(
          0.0,
          duration: _kDroppedSwipePageAnimationDuration,
          curve: animationCurve,
        );
      }
    }

    if (controller.isAnimating) {
      // Keep the userGestureInProgress in true state so we don't change the
      // curve of the page transition mid-flight since CupertinoPageTransition
      // depends on userGestureInProgress.
      late AnimationStatusListener animationStatusCallback;
      animationStatusCallback = (AnimationStatus status) {
        navigator.didStopUserGesture();
        controller.removeStatusListener(animationStatusCallback);
      };
      controller.addStatusListener(animationStatusCallback);
    } else {
      navigator.didStopUserGesture();
    }
  }
}
