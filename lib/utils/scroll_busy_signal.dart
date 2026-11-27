import 'package:flutter/widgets.dart';

/// 全局滚动繁忙信号:近期是否有列表在滚动。
///
/// 由 app 根部的 NotificationListener 喂入(见 main.dart 的
/// MaterialApp.builder),后台维护类任务动手前查询让路 —— 典型是
/// cf_clearance 的 WebView cookie 兜底轮询:一趟平台主线程 IPC,与
/// vsync 分发/触摸事件同线程,滚动中执行会直接顶出掉帧(诊断时间轴
/// "[STALL] 平台主线程阻塞"的来源之一)。周期任务跳过本轮即可,
/// 下一轮自然补上;不适用于用户正在等结果的前台请求。
class ScrollBusySignal {
  ScrollBusySignal._();

  static DateTime _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);
  static final Set<BuildContext> _activeScrollContexts = {};

  /// 滚动静默判定窗口:最后一次滚动通知后 1s 内视为繁忙
  /// (覆盖惯性滚动的整个衰减尾巴)
  static const _busyWindow = Duration(seconds: 1);

  /// 滚动通知到达时调用(赋值级开销,每帧多次调用无碍)
  static void touch() => _lastScrollAt = DateTime.now();

  /// 统一接入 ScrollNotification:同时维护实时滚动态([isScrolling])与
  /// 1s 静默窗口([isBusy])。按滚动容器 context 追踪，兼容嵌套滚动。
  static void onScrollNotification(ScrollNotification notification) {
    final ctx = notification.context;
    if (notification is ScrollStartNotification) {
      touch();
      if (ctx != null) _activeScrollContexts.add(ctx);
    } else if (notification is ScrollUpdateNotification) {
      touch();
      if (notification.dragDetails != null && ctx != null) {
        _activeScrollContexts.add(ctx);
      }
    } else if (notification is ScrollEndNotification) {
      touch();
      if (ctx != null) _activeScrollContexts.remove(ctx);
    }
  }

  /// 当前是否存在尚未结束的滚动会话（含拖动与惯性滑行）。
  static bool get isScrolling {
    if (_activeScrollContexts.isEmpty) return false;
    _activeScrollContexts.removeWhere((ctx) => !ctx.mounted);
    return _activeScrollContexts.isNotEmpty;
  }

  static bool get isBusy =>
      isScrolling || DateTime.now().difference(_lastScrollAt) < _busyWindow;

  @visibleForTesting
  static void reset() {
    _activeScrollContexts.clear();
    _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
