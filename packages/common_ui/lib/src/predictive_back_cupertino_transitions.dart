// 手势探测部分拷自 Flutter 3.44 material/predictive_back_page_transitions_builder.dart
// (BSD 许可,版权归 The Flutter Authors)。
//
// 存在理由:官方 PredictiveBackPageTransitionsBuilder 把非手势导航硬编码
// 到 FadeForwardsPageTransitionsBuilder(双页全屏 FadeTransition = 每帧两次
// 全屏 saveLayer,Impeller 上 push/pop 必抽一串,生产日志定案),且 push/
// 按钮返回永远走它 —— 无法在保留系统预测返回手势的同时避开。
//
// 与原文件的差异(其余逐行保真,升级 Flutter 后 diff 上游同步):
// 1. **唯一转场是 Cupertino 滑动**。官方在手势期渲染 shared-element 预览
//    (整页缩小+圆角+位移),非手势期用 FadeForwards —— 同一个页面按同一个
//    动作,会因「系统这次有没有按预测返回协议发事件」而呈现两种完全不同的
//    退出动画(三键返回键、被判成点击的快扫、注册态不对时,系统只发
//    popRoute,不发 startBackGesture)。用户实测「同一页面有时淡化有时
//    滑出」即此。故整段删除 shared-element 预览(约 250 行)与配套的
//    Expando 下层冻结机制:手势只驱动路由动画进度,视觉恒为 Cupertino
//    平移(它天生跟手,拖到哪停在哪),分支归一 ⇒ 观感确定。
// 2. transitionDuration 800ms → 400ms(Cupertino 时长)。
// 3. 只保留手势探测器(_PredictiveBackGestureDetector),它负责把系统手势
//    进度喂给 route 的 PredictiveBackRoute 接口;渲染完全交给 Cupertino。
// 4. 手势中途 Activity 进后台(挂后台/锁屏)时代打 cancel。系统不为被打断
//    的手势补发 commit/cancel,不收尾则 navigator.userGestureInProgress
//    计数永不归零 → popGestureEnabled 恒 false → 回前台后预测返回永久失效。
//    只在 phase 为 start/update 时代打:commit/cancel 之后的窗口内再代打,
//    会与收尾动画回调各触发一次 didStopUserGesture → 计数下溢(release 无
//    assert,计数变 -1)→ userGestureInProgress 永久 off-by-one 恒 false。
// 5. commit/cancel 按 phase 门控:binding 的认领者列表在 commit/cancel 后
//    不清空(仅下次 start 才清),而原生 MainActivity.onStop 每次锁屏都无
//    条件广播 cancelBackGesture,会打到上一次手势的陈旧认领者上 → 无配对
//    start 的 didStopUserGesture 让计数下溢 → 预测返回渲染全灭。非
//    start/update 一律忽略。
// 6. 文件尾新增 [buildPredictiveBackPageTransitions](上游没有):给不走
//    PageTransitionsTheme 的 PageRouteBuilder 自定义转场补挂手势探测器,
//    追加在上游内容之后,不打断上游类排布。
// 7. commit 自己收尾([_commitWithoutReplay]),不走框架的
//    handleCommitBackGesture —— 后者在同一次 commit 里 reverse 两次
//    (routes.dart:601-606),第二次硬拽回 1.0 重走 = 用户反馈的「返回重播」。
// 8. 探测器持有的 route 类型从 `PageRoute<dynamic>` 放宽到
//    `ModalRoute<dynamic>`,文件尾 helper 的类型闸门同步放宽。
//    预测返回**不是 PageRoute 专属能力**:PredictiveBackRoute 的实现体在
//    TransitionRoute(routes.dart:111 `implements PredictiveBackRoute`),
//    ModalBottomSheetRoute → PopupRoute → ModalRoute → TransitionRoute
//    与 PageRoute → ModalRoute → TransitionRoute 共享同一父类,四个 handler
//    和 popGestureEnabled 全都继承得到。上游写 PageRoute 只因
//    PageTransitionsBuilder.buildTransitions 的签名只喂 PageRoute<T> ——
//    那是入口的限制,不是能力的限制。放宽后底部弹框可跟手下滑。
//    实测:sheet 的 popGestureEnabled=true、手势进度驱动位移
//    6.7px→48.2px→150.0px 单调跟手、下层 page route isCurrent=false
//    (故不会同时认领)。
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Android 预测返回手势 + Cupertino 滑动转场。
///
/// 系统预测返回手势(Android U+)的进度直接驱动路由动画,Cupertino 平移
/// 随之跟手;push、按钮/程序化 pop、其它平台走同一套 Cupertino 转场 ——
/// **任何路径下同一页面的进出动画完全一致**(见文件头差异点 1)。
class PredictiveBackCupertinoPageTransitionsBuilder
    extends PageTransitionsBuilder {
  const PredictiveBackCupertinoPageTransitionsBuilder();

  /// Cupertino 时长(官方 shared-element 预览用 800ms,已不适用)
  static const int _kTransitionMilliseconds = 400;

  @override
  Duration get transitionDuration =>
      const Duration(milliseconds: _kTransitionMilliseconds);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _PredictiveBackGestureDetector(
      route: route,
      builder: (BuildContext context) {
        return const CupertinoPageTransitionsBuilder().buildTransitions(
          route,
          context,
          animation,
          secondaryAnimation,
          child,
        );
      },
    );
  }
}

typedef _PredictiveBackGestureDetectorWidgetBuilder =
    Widget Function(BuildContext context);

/// The phases of a predictive back gesture.
enum _PredictiveBackPhase {
  /// There is no active predictive back gesture in progress.
  idle,

  /// The user pointer has contacted the screen.
  start,

  /// The user pointer has moved.
  update,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture is successful and the current route
  /// should be popped.
  commit,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture should be canceled and the original route
  /// should be shown.
  cancel,
}

class _PredictiveBackGestureDetector extends StatefulWidget {
  const _PredictiveBackGestureDetector({
    required this.route,
    required this.builder,
  });

  final _PredictiveBackGestureDetectorWidgetBuilder builder;

  /// 差异点 8:上游此处是 `PageRoute<dynamic>`,本仓库放宽到 [ModalRoute]。
  ///
  /// 探测器只用到 `isCurrent`、`popGestureEnabled` 和 PredictiveBackRoute
  /// 的四个 handler —— 这些全部定义在 [ModalRoute] 及其父类
  /// `TransitionRoute`(它才是 `implements PredictiveBackRoute` 的那一层)。
  /// 上游写 `PageRoute` 是因为 `PageTransitionsBuilder.buildTransitions`
  /// 的签名只喂 `PageRoute<T>`,**那是入口的限制,不是能力的限制**。
  /// 放宽后 `ModalBottomSheetRoute`(PopupRoute 分支)也能认领手势。
  final ModalRoute<dynamic> route;

  @override
  State<_PredictiveBackGestureDetector> createState() =>
      _PredictiveBackGestureDetectorState();
}

class _PredictiveBackGestureDetectorState
    extends State<_PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  /// 差异点 4:后台/锁屏代打 cancel 后置位,忽略系统迟到的收尾事件,
  /// 直到下一次 startBackGesture 重新认领。
  bool _gestureForceCancelled = false;

  _PredictiveBackPhase _phase = _PredictiveBackPhase.idle;

  /// True when the predictive back gesture is enabled.
  bool get _isEnabled {
    return widget.route.isCurrent && widget.route.popGestureEnabled;
  }

  // Begin WidgetsBindingObserver.

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final bool gestureInProgress = !backEvent.isButtonEvent && _isEnabled;
    if (!gestureInProgress) {
      return false;
    }

    _phase = _PredictiveBackPhase.start;
    _gestureForceCancelled = false;
    _userGestureFinished = false;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_gestureForceCancelled) return;
    _phase = _PredictiveBackPhase.update;
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() {
    if (_gestureForceCancelled) return;
    // 差异点 5:只在手势活跃期收 cancel(陈旧认领者不得响应伪事件,
    // 否则 didStopUserGesture 无配对 start,计数下溢成负)。
    if (_phase != _PredictiveBackPhase.start &&
        _phase != _PredictiveBackPhase.update) {
      return;
    }
    _phase = _PredictiveBackPhase.cancel;
    widget.route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    if (_gestureForceCancelled) return;
    // 差异点 5:同 cancel
    if (_phase != _PredictiveBackPhase.start &&
        _phase != _PredictiveBackPhase.update) {
      return;
    }
    _phase = _PredictiveBackPhase.commit;
    _commitWithoutReplay();
  }

  /// 差异点 7:自己收尾 commit,不走框架的
  /// `TransitionRoute.handleCommitBackGesture`,消除**重播**。
  ///
  /// 框架 `_handleDragEnd(animateForward: false)` 在同一次 commit 里让
  /// 路由动画 reverse 了**两次**(routes.dart:601-606):
  /// ```dart
  /// navigator?.pop();                       // ①didPop → controller.reverse()
  ///                                         //   从当前进度反向 —— 正确、跟手
  /// if (_controller?.isAnimating ?? false) { // ①已置 animating,故必然成立
  ///   _controller!.reverse(from: _controller!.upperBound); // ②硬拽回 1.0 重走
  /// }
  /// ```
  /// ②把①的成果作废:页面刚从松手进度(如 0.6)往外走,下一帧被拽回
  /// 1.0 重新走一遍 —— 用户反馈的「返回时重放/动了两次」就是它。快扫
  /// 返回(进度仅 ~0.05)时落差高达 95%,观感最差;且这是**位置突变**,
  /// 缩短时长无从缓解(试过,已否决)。
  ///
  /// ①本身就是完整正确的收尾,故这里只做 `navigator.pop()`,不触发②。
  /// pop 是公开 API,不必碰 @protected 的 controller(自己驱动动画那条
  /// 路已验证不可行)。代价是要自管手势计数归零 —— 见
  /// [_finishUserGestureWhenSettled]。
  void _commitWithoutReplay() {
    final route = widget.route;
    final navigator = route.navigator;
    if (navigator == null) {
      // 拿不到 navigator:退回框架实现,至少保证路由出栈
      route.handleCommitBackGesture();
      return;
    }
    // 顺序要紧:必须先 pop 让退场动画起转,再挂归零监听。
    // 手势期的进度是被直接赋值(非动画驱动),此刻 animation.isAnimating
    // 为 false —— 若先挂监听会走「立即归零」分支,userGestureInProgress
    // 当帧就翻 false,依赖它的消费方(如查看器缩放松弛靠它判断手势是否
    // 结束)会在退场刚开始时就收工,后半段不再跟随。
    navigator.pop();
    _finishUserGestureWhenSettled(navigator, route.animation);
  }

  /// 手势计数归零(替代框架 `_handleDragEnd` 尾部的同名逻辑)。
  ///
  /// **必须恰好调用一次**:漏调 → userGestureInProgress 恒 true →
  /// popGestureEnabled 恒 false → 预测返回全局失效;重复调用 → 计数
  /// 下溢成负 → 同样全灭。两个坑都踩过(见差异点 4/5)。
  ///
  /// 与框架同口径:监听退场动画的 status,任一变化即归零并摘监听
  /// (框架用 controller,我们只有只读 animation,派发时机一致);
  /// 若 pop 已同步走完(无动画),立即归零。
  void _finishUserGestureWhenSettled(
    NavigatorState navigator,
    Animation<double>? animation,
  ) {
    if (_userGestureFinished) return;

    void finish() {
      if (_userGestureFinished) return;
      _userGestureFinished = true;
      navigator.didStopUserGesture();
    }

    if (animation == null || !animation.isAnimating) {
      finish();
      return;
    }
    late final AnimationStatusListener listener;
    listener = (AnimationStatus status) {
      animation.removeStatusListener(listener);
      finish();
    };
    animation.addStatusListener(listener);
  }

  /// 一次性标记:见 [_finishUserGestureWhenSettled]
  bool _userGestureFinished = false;

  /// 差异点 4:Activity 进后台(挂后台/锁屏)会打断进行中的手势,且系统
  /// 不再补发 commit/cancel;不收尾则 userGestureInProgress 计数永不归零,
  /// popGestureEnabled 恒 false,回前台后预测返回永久失效。
  /// hidden/paused 先后各触发一次,靠 _gestureForceCancelled 防重入。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (_gestureForceCancelled) return;
    if (_phase != _PredictiveBackPhase.start &&
        _phase != _PredictiveBackPhase.update) {
      return;
    }

    _gestureForceCancelled = true;
    _phase = _PredictiveBackPhase.cancel;
    widget.route.handleCancelBackGesture();
  }

  // End WidgetsBindingObserver.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

// —— 以下为本仓库追加,上游无对应物(差异点 6)——

/// 给 [PageRouteBuilder] 自定义转场补挂 Android 预测返回手势。
///
/// PageRouteBuilder 不走全局 PageTransitionsTheme,其转场树里没有
/// 手势探测器,系统预测返回手势无人认领 → 只能整 app 缩走。本函数在
/// 自定义转场外围补挂探测器:手势进度驱动路由动画,而视觉始终由
/// [transitionBuilder] 决定(方案 A 的单一分支原则 —— 同一路由在任何
/// 返回路径下动画一致)。
///
/// 认领手势还是 Hero 跟手飞行的前提:HeroController 只为 user gesture
/// 转场启动带 transitionOnUserGestures 的 Hero 飞行,不认领则 Hero 完全
/// 不飞(查看器/搜索胶囊依赖此)。
Widget buildPredictiveBackPageTransitions(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child, {
  required Widget Function(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  )
  transitionBuilder,
}) {
  // 差异点 8:闸门放宽到 ModalRoute(原为 PageRoute)。仍需这道检查 ——
  // 从弹窗以外的非 ModalRoute 上下文调用时静默降级,不挂探测器。
  final route = ModalRoute.of(context);
  if (route == null) {
    return transitionBuilder(context, animation, secondaryAnimation, child);
  }

  return _PredictiveBackGestureDetector(
    route: route,
    builder: (BuildContext context) =>
        transitionBuilder(context, animation, secondaryAnimation, child),
  );
}

/// 给底部弹框一类 [ModalRoute] 补挂 Android 预测返回手势(差异点 8)。
///
/// 与 [buildPredictiveBackPageTransitions] 的区别:调用方**已持有 route
/// 对象**(在 route 自己的 buildTransitions 里),不必从 context 反查。
///
/// **本函数不包任何视觉 widget** —— 只认领手势、把进度喂给路由动画。
/// 底部弹框的位移本来就绑 `route.animation`(`_ModalBottomSheetState` 里
/// `_sheetAnimation.parent = widget.route.animation`),而官方的手指下拉
/// 关闭就是改同一个 controller 的 value。于是手势进度天然驱动 sheet 跟手
/// 下滑,**与手指下拉关闭是同一套动画**,零新增动画代码。这也满足方案 A
/// 的单一分支原则:同一个 sheet 在任何关闭路径下动画一致。
///
/// 只在 Android 生效;其它平台原样返回 [child],零行为变化。
Widget wrapPredictiveBackForModalRoute({
  required ModalRoute<dynamic> route,
  required Widget child,
}) {
  if (defaultTargetPlatform != TargetPlatform.android) return child;
  return _PredictiveBackGestureDetector(
    route: route,
    builder: (BuildContext context) => child,
  );
}
