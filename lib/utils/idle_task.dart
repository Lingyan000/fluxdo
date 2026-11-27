import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

import 'scroll_busy_signal.dart';

bool _pointerRouteInstalled = false;
final Set<int> _activePointers = {};
final Set<int> _activePanZooms = {};

void _ensurePointerRouteInstalled() {
  if (_pointerRouteInstalled) return;
  _pointerRouteInstalled = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointer);
}

void _handleGlobalPointer(PointerEvent event) {
  if (event is PointerDownEvent) {
    _activePointers.add(event.pointer);
  } else if (event is PointerUpEvent || event is PointerCancelEvent) {
    _activePointers.remove(event.pointer);
  } else if (event is PointerPanZoomStartEvent) {
    _activePanZooms.add(event.pointer);
  } else if (event is PointerPanZoomEndEvent) {
    _activePanZooms.remove(event.pointer);
  }
}

/// 当前是否处于手指按下拖动、触控板手势或活跃滚动状态。
bool get isIdleTaskUserInteracting =>
    _activePointers.isNotEmpty ||
    _activePanZooms.isNotEmpty ||
    ScrollBusySignal.isScrolling;

@visibleForTesting
void resetIdleTaskInteractionState() {
  _activePointers.clear();
  _activePanZooms.clear();
  // ignore: invalid_use_of_visible_for_testing_member
  ScrollBusySignal.reset();
}

/// 空闲任务调度:替代 `SchedulerBinding.scheduleTask(..., Priority.idle)`。
///
/// Flutter 3.44 的 `handleEventLoopCallback` 在队首任务因优先级不足被拒绝
/// 执行时仍返回 true,`_runTasks` 便用零延时 Timer 无限重排自己——只要
/// 队列里躺着一个 idle 任务且页面存在持续动画(transientCallbackCount>0,
/// 如着色器背景/加载动画),事件循环就退化为全速忙等,UI 线程被活锁
/// (实测每秒 9~18 万条空消息)。这里用 8ms 定时器链自实现"空闲礼让",
/// 完全不进框架任务队列。
///
/// 语义:
/// - 手指按住拖动、触控板缩放/滚动或列表活跃滚动期间始终让路，不计入
///   [maxDeferral]（避免长拖动中强制抢跑重预热）；
/// - 仅存在动画回调（transientCallbackCount>0）时每 8ms 探测一次，停止后
///   执行；连续动画礼让超过 [maxDeferral] 后强制执行，避免常驻动画把任务
///   饿死。
IdleTaskHandle scheduleIdleTask(
  void Function() task, {
  bool Function()? isCanceled,
  Duration maxDeferral = const Duration(seconds: 2),
}) {
  _ensurePointerRouteInstalled();
  final handle = IdleTaskHandle();
  final maxDeferralMs = maxDeferral.inMilliseconds;
  var animationDeferredMs = 0;

  void attempt() {
    handle._timer = Timer(const Duration(milliseconds: 8), () {
      handle._timer = null;
      if (handle._canceled || (isCanceled?.call() ?? false)) return;
      if (isIdleTaskUserInteracting) {
        attempt();
        return;
      }
      if (SchedulerBinding.instance.transientCallbackCount > 0 &&
          animationDeferredMs < maxDeferralMs) {
        animationDeferredMs += 8;
        attempt();
        return;
      }
      task();
    });
  }

  attempt();
  return handle;
}

/// 取消尚未执行的探测计时器；重复取消安全，不影响其他任务。
class IdleTaskHandle {
  Timer? _timer;
  bool _canceled = false;

  void cancel() {
    _canceled = true;
    _timer?.cancel();
    _timer = null;
  }
}
