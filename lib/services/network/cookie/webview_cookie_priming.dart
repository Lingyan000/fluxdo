import 'dart:async';

/// WV 启动重灌服务。
///
/// 取代 v0.3.0 的 `RawSetCookieQueue` 持久化队列。
/// 在 WV 即将被使用前，从 jar 重灌所有 critical cookies。
///
/// 设计依据：`docs/cookie-sync-design-v0.4.0.md` §5.2
///
/// 关键不变量：
/// - 任何 WV 使用者在使用 WV 前必须 await [prime]
/// - prime 是幂等的（[isPrimed] 为 true 时立即返回）
/// - 同一 url 并发调用 [prime] 会去重（共享同一个 Future）
///
/// 调用方约束：
/// - `WebViewPage` — 用户进入 WV 页前
/// - `WebViewLoginPage` — 登录页打开前
/// - `WebViewHttpAdapter` — 每次 `fetch` 前
/// - `CfChallengeService` — CF 验证页打开前
class WebViewCookiePriming {
  WebViewCookiePriming._();
  static final WebViewCookiePriming instance = WebViewCookiePriming._();

  /// 确保 WV 中的 critical cookies 与 jar 同步。
  ///
  /// 前置：`CookieJarService.isInitialized == true`
  ///       （内部会 `await jar.initialize()` 兜底）
  ///
  /// 后置：WV 中存在 jar 内所有未过期 critical cookies，
  ///       且每个 name 变体数 == 1。
  ///
  /// 性能：已就绪 < 1ms；首次重灌 ~100-300ms。
  ///
  /// 失败：抛 [WebViewPrimingException]，调用方应阻止 WV 启动。
  Future<void> prime(String url) {
    throw UnimplementedError('Phase 3 实现');
  }

  /// 标记 WV 状态为"未就绪"。
  ///
  /// 调用时机：登出 / 清 cookie / Nuclear Reset 之后。
  /// [isPrimed] 立即变为 false，下次 [prime] 会重新走全量重灌。
  void invalidate() {
    throw UnimplementedError('Phase 3 实现');
  }

  /// 当前 WV 是否已就绪。
  bool get isPrimed => throw UnimplementedError('Phase 3 实现');

  /// 等待当前正在进行的 priming 完成（如有）。
  Future<void> awaitReady() {
    throw UnimplementedError('Phase 3 实现');
  }
}

/// WV priming 失败时抛出。
class WebViewPrimingException implements Exception {
  WebViewPrimingException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'WebViewPrimingException: $message'
      '${cause != null ? ' (caused by $cause)' : ''}';
}
