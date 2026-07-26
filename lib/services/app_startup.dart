/// 启动阶段协调:网络栈初始化(迁移/代理/rhttp/DoH/WebView2 环境等)
/// 从「runApp 之前串行 await」改为 runApp 之后异步跑,splash 首帧不再
/// 等它 —— 弱机/慢代理场景首帧提前数百毫秒到数秒。
///
/// 时序契约:任何**发网络请求**的启动路径必须先 `await networkReady`,
/// 否则请求会在代理/DoH 未落定时发出(出口不一致,cf_clearance 失效,
/// 见 CF 验证循环的历史教训)。目前唯一的早期请求入口是 PreheatGate
/// 的 ensurePreloaded,已加 await;后续新增早期请求入口时同样要加。
class AppStartup {
  AppStartup._();

  /// 网络栈就绪信号。main() 在 runApp 前赋值,永不置 null。
  static Future<void> networkReady = Future.value();
}
