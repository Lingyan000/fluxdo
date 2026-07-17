import 'package:flutter/scheduler.dart';

/// 空闲任务调度:替代 `SchedulerBinding.scheduleTask(..., Priority.idle)`。
///
/// Flutter 3.44 的 `handleEventLoopCallback` 在队首任务因优先级不足被拒绝
/// 执行时仍返回 true,`_runTasks` 便用零延时 Timer 无限重排自己——只要
/// 队列里躺着一个 idle 任务且页面存在持续动画(transientCallbackCount>0,
/// 如着色器背景/加载动画),事件循环就退化为全速忙等,UI 线程被活锁
/// (实测每秒 9~18 万条空消息)。这里用 8ms 定时器链自实现"空闲礼让",
/// 完全不进框架任务队列。
///
/// 语义:动画进行中每 8ms 探测一次(代价可忽略),动画停止后执行;
/// 连续礼让超过 [maxDeferral] 后强制执行,避免常驻动画把任务饿死。
void scheduleIdleTask(
  void Function() task, {
  bool Function()? isCanceled,
  Duration maxDeferral = const Duration(seconds: 2),
}) {
  final deadline = DateTime.now().add(maxDeferral);
  void attempt() {
    Future<void>.delayed(const Duration(milliseconds: 8), () {
      if (isCanceled?.call() ?? false) return;
      if (SchedulerBinding.instance.transientCallbackCount > 0 &&
          DateTime.now().isBefore(deadline)) {
        attempt();
        return;
      }
      task();
    });
  }

  attempt();
}
