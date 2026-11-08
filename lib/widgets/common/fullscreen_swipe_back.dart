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
// 4. 取消返回后的回弹可再次按住接管,沿用当前进度与同一次 navigator
//    手势计数;系统取消触摸始终回到当前页,不按过半阈值提交返回。
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

const double _kMinFlingVelocity = 1.0; // Screen widths per second.

// The duration it takes for a dropped swipe page animation to complete.
const Duration _kDroppedSwipePageAnimationDuration = Duration(
  milliseconds: 350,
);

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
  DelegatedTransitionBuilder? get delegatedTransition =>
      inner.delegatedTransition;

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
      return inner.buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    return inner.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      _FullscreenBackGestureDetector<T>(route: route, child: child),
    );
  }
}

// Called by _FullscreenBackGestureDetector when a pop ("back") drag start
// gesture is detected. The returned controller handles all of the subsequent
// drag events.
_FullscreenBackGestureController<T> _startPopGesture<T>(
  PageRoute<T> route,
  VoidCallback onFinished,
) {
  assert(route.popGestureEnabled);

  return _FullscreenBackGestureController<T>(
    navigator: route.navigator!,
    getIsCurrent: () => route.isCurrent,
    getIsActive: () => route.isActive,
    // ignore: invalid_use_of_protected_member
    controller: route.controller!, // protected access
    onFinished: onFinished,
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
    required this.route,
    required this.child,
  });

  final Widget child;

  final PageRoute<T> route;

  @override
  _FullscreenBackGestureDetectorState<T> createState() =>
      _FullscreenBackGestureDetectorState<T>();
}

class _FullscreenBackGestureDetectorState<T>
    extends State<_FullscreenBackGestureDetector<T>> {
  _FullscreenBackGestureController<T>? _backGestureController;
  int? _pointer;
  bool _pointerCanceled = false;

  late HorizontalDragGestureRecognizer _recognizer;

  @override
  void initState() {
    super.initState();
    _recognizer = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onlyAcceptDragOnThreshold = true
      ..onStart = _handleDragStart
      ..onUpdate = _handleDragUpdate
      ..onEnd = _handleDragEnd
      ..onCancel = _handleDragCancel;
  }

  @override
  void dispose() {
    _recognizer.dispose();

    _backGestureController?.dispose();
    _backGestureController = null;
    super.dispose();
  }

  void _handleDragStart(DragStartDetails details) {
    assert(mounted);
    if (_backGestureController != null) return;
    // PopScope or navigation can change after pointer down but before the drag
    // wins. Only start a fresh gesture while the route still allows it.
    if (!widget.route.popGestureEnabled || !widget.route.isCurrent) return;
    _backGestureController = _startPopGesture<T>(widget.route, () {
      _backGestureController = null;
    });
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    assert(mounted);
    _backGestureController?.dragUpdate(
      _convertToLogical(details.primaryDelta! / context.size!.width),
    );
  }

  void _handleDragEnd(DragEndDetails details) {
    assert(mounted);
    _backGestureController?.dragEnd(
      _convertToLogical(
        details.velocity.pixelsPerSecond.dx / context.size!.width,
      ),
      canceled: _pointerCanceled,
    );
  }

  void _handleDragCancel() {
    assert(mounted);
    // This can be called even if start is not called, paired with the "down" event
    // that we don't consider here.
    final gesture = _backGestureController;
    if (gesture != null && !gesture.isSettling) {
      gesture.dragEnd(0.0, canceled: true);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null ||
        event.buttons != kPrimaryMouseButton ||
        _hitsPlatformView(event)) {
      return;
    }
    final gesture = _backGestureController;
    if (gesture != null) {
      // Bypass only the animation-completed check for our own returning
      // gesture. Respect navigation changes and all route pop vetoes.
      final route = widget.route;
      if (!gesture.canResume ||
          !route.isCurrent ||
          route.isFirst ||
          route.willHandlePopInternally ||
          // Match the framework's pop veto, including legacy WillPopScope.
          // ignore: deprecated_member_use, invalid_use_of_protected_member
          route.hasScopedWillPopCallback ||
          route.popDisposition == RoutePopDisposition.doNotPop ||
          !route.secondaryAnimation!.isDismissed) {
        return;
      }
      gesture.resume();
    } else if (!widget.route.popGestureEnabled ||
        !widget.route.isCurrent ||
        widget.route.popGestureInProgress) {
      return;
    }
    _pointer = event.pointer;
    _pointerCanceled = false;
    _recognizer.addPointer(event);
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_pointer == event.pointer) {
      // DragGestureRecognizer reports onEnd even for an accepted drag that
      // receives PointerCancelEvent. Remember the raw termination reason.
      _pointerCanceled = event is PointerCancelEvent;
      _pointer = null;
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
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
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
    required this.onFinished,
  }) {
    navigator.didStartUserGesture();
  }

  final AnimationController controller;
  final NavigatorState navigator;
  final ValueGetter<bool> getIsActive;
  final ValueGetter<bool> getIsCurrent;
  final VoidCallback onFinished;
  bool _finished = false;
  bool _returning = false;
  bool isSettling = false;

  bool get canResume =>
      !_finished && isSettling && _returning && getIsCurrent();

  void resume() {
    assert(canResume);
    controller.removeStatusListener(_handleAnimationStatus);
    isSettling = false;
    controller.stop();
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _finish();
    }
  }

  void _finish({bool defer = false}) {
    if (_finished) return;
    _finished = true;
    controller.removeStatusListener(_handleAnimationStatus);
    onFinished();
    void release() {
      if (navigator.mounted) navigator.didStopUserGesture();
    }

    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => release());
    } else {
      release();
    }
  }

  void dispose() => _finish(defer: true);

  /// The drag gesture has changed by [delta]. The total range of the drag
  /// should be 0.0 to 1.0.
  void dragUpdate(double delta) {
    controller.value -= delta;
  }

  /// The drag gesture has ended with a horizontal motion of [velocity] as a
  /// fraction of screen width per second.
  void dragEnd(double velocity, {bool canceled = false}) {
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
    } else if (canceled) {
      animateForward = true;
    } else if (velocity.abs() >= _kMinFlingVelocity) {
      // If the user releases the page before mid screen with sufficient velocity,
      // or after mid screen, we should animate the page out. Otherwise, the page
      // should be animated back in.
      animateForward = velocity <= 0;
    } else {
      animateForward = controller.value > 0.5;
    }

    isSettling = true;
    _returning = animateForward;
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
      controller.addStatusListener(_handleAnimationStatus);
    } else {
      _finish();
    }
  }
}
