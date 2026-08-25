import 'dart:async';

/// 全局恢复动作。
///
/// CF 验证、会话 sweep、引擎降级这类动作有个共同点:**它们修复的是全局
/// 环境,不是某个请求**。N 个并发失败请求应当共享一次动作执行,而不是各自
/// 触发一遍(否则会出现三个请求同时弹三个 CF 验证窗口)。
///
/// 此前项目里有三套手写的单飞实现(CfChallengeInterceptor._syncCookiesOnce、
/// CsrfTokenService._activeCsrfRequest、CfChallengeService.
/// _activeSessionCompatPrompt),各自维护 active future 与清理逻辑。本基类
/// 把单飞语义收敛为一处。
abstract class RecoveryAction {
  /// 进行中的执行;并发调用合流到它。
  Future<bool>? _active;

  /// 诊断名。
  String get name;

  /// 执行一次恢复。返回是否成功(失败时调用方应放弃重放)。
  Future<bool> run() {
    final active = _active;
    if (active != null) return active;

    final future = perform().whenComplete(() {
      _active = null;
    });
    _active = future;
    return future;
  }

  /// 是否正在执行(诊断用)。
  bool get isRunning => _active != null;

  /// 子类实现真正的恢复逻辑。不需要自己处理并发合流。
  Future<bool> perform();
}
