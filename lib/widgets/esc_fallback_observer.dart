import 'package:flutter/material.dart';

/// ESC「路由级自动兜底」登记表 + NavigatorObserver。
///
/// 背景:全局快捷键 handler 对 closeOverlay 没有全局兜底动作——早年论证
/// 否决过「无差别全局 maybePop」(同步 handler 无法感知事件是否会被后续
/// 管线消费,会与图片查看器等自管理页抢跑双 pop)。结果是每个全屏页都要
/// 显式 opt-in,实际 50+ 页零接入,「ESC 有的页面能关有的不行」。
///
/// 本机制不属于被否决的那类:按 **route 精确登记**(didPush 登记、
/// didPop/didRemove/didReplace 注销),分发端只在「栈顶登记路由
/// isCurrent」时才 maybePop——不是盲兜底:
/// - 弹层/PopupRoute 不登记(surface 机制照旧优先);
/// - 页面显式注册的 context/scope 回调仍然优先(分发序:surface →
///   context 回调 → 本兜底 → global);
/// - maybePop 尊重 PopScope(编辑器弹「放弃草稿?」确认是期望语义);
/// - 图片查看器等自带本地 ESC 的页面:全局 handler 消费后事件不再进
///   焦点管线,本地 CallbackShortcuts 收不到,仍是单次 pop,无双 pop。
///
/// 多 Navigator:根 Navigator 与设置页内栏各挂一个实例、共享静态登记表,
/// LIFO 全局序=push 时序——设置内栏有子页时 ESC 先退子页,退到内栏基层
/// (isFirst 不登记)后落回设置页自身 surface 关整页。
///
/// 仅桌面消费(全局快捷键 handler 只在桌面注册),移动端登记无副作用。
class EscFallbackObserver extends NavigatorObserver {
  /// 全局登记栈(按 push 时序,跨 Navigator 共享)。
  static final List<EscFallbackEntry> _registry = [];

  /// 弹层(PopupRoute)登记表,与页面表分开:弹层不参与「路由级 ESC
  /// 兜底」的 maybePop 链,只供分发端识别「嵌套 Navigator 上正开着
  /// 弹层」。根 Navigator 的弹层分发端从根栈顶就能看到,但嵌套
  /// Navigator(设置页内栏)里的底部弹框/菜单对根栈不可见——根栈顶
  /// 仍是宿主页路由,旧流程会把 ESC 错发给页面级 surface/detail 回调
  /// (关掉平行视界的层,弹框却还开着)。
  static final List<EscFallbackEntry> _popupRegistry = [];

  /// 取当前应被 ESC 兜底关闭的登记项:LIFO 从栈顶找第一个仍 isCurrent
  /// (自己的 Navigator 视角)的路由。被弹层盖住时 isCurrent=false,
  /// 自然让位;嵌套 Navigator(设置内栏)还要求宿主路由自身也在根栈顶,
  /// 设置页被其他全屏页盖住时内栏子页不截胡。
  static EscFallbackEntry? resolveCurrent() => _resolveIn(_registry);

  /// 取当前活跃的弹层登记项(判据与 [resolveCurrent] 同:自身栈顶 +
  /// 宿主路由在根栈顶)。
  static EscFallbackEntry? resolveCurrentPopup() => _resolveIn(_popupRegistry);

  static EscFallbackEntry? _resolveIn(List<EscFallbackEntry> registry) {
    for (var i = registry.length - 1; i >= 0; i--) {
      final entry = registry[i];
      final navigator = entry.route.navigator;
      if (navigator == null || !navigator.mounted) continue;
      if (!entry.route.isCurrent) continue;
      final hostRoute = ModalRoute.of(navigator.context);
      if (hostRoute != null && !hostRoute.isCurrent) continue;
      return entry;
    }
    return null;
  }

  bool _shouldTrack(Route<dynamic> route) {
    // 只兜全屏页面路由:弹层(PopupRoute)走 surface/内置兜底,首路由
    // 无可退。
    return route is PageRoute && !route.isFirst;
  }

  void _track(Route<dynamic> route) {
    if (_shouldTrack(route)) _registry.add(EscFallbackEntry(route: route));
    if (route is PopupRoute) {
      _popupRegistry.add(EscFallbackEntry(route: route));
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _track(route);

  void _remove(Route<dynamic> route) {
    _registry.removeWhere((e) => e.route == route);
    _popupRegistry.removeWhere((e) => e.route == route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _remove(oldRoute);
    if (newRoute != null) _track(newRoute);
  }
}

class EscFallbackEntry {
  const EscFallbackEntry({required this.route});

  final Route<dynamic> route;

  /// 本登记路由是否处在 [hostRoute] 体内的嵌套 Navigator 里
  /// (设置页内栏子页 → 宿主是设置页路由)。
  bool isNestedInside(Route<dynamic> hostRoute) {
    final navigator = route.navigator;
    if (navigator == null || !navigator.mounted) return false;
    return ModalRoute.of(navigator.context) == hostRoute;
  }

  /// 关闭:在路由自己的 Navigator 上 maybePop(尊重 PopScope)。
  void close() => route.navigator?.maybePop();
}
