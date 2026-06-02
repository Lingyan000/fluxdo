import 'package:dio/dio.dart';

/// Dio 拦截器：401 / discourse-logged-out 透明自愈。
///
/// 设计依据：`docs/cookie-sync-design-v0.4.0.md` §5.3
///
/// 自愈触发条件（全部满足）：
/// 1. `statusCode ∈ {401, 419}` 或响应头含 `discourse-logged-out`
/// 2. jar 中 `_t` 存在且未过期
/// 3. 本次请求未被自愈过（防递归）
///
/// 自愈流程：
/// 1. 标记 `_selfHealed=true`
/// 2. await `Sentinel.sweepAll(uri.origin)`
/// 3. await 100ms（给 WV 网络栈一点时间观察新 cookie）
/// 4. 重试原请求，最多 2 次
/// 5. 全失败 → Nuclear Reset → 重试 1 次
/// 6. 仍失败 → 透传原 401 响应（不吞）
///
/// 关键不变量：
/// - 对上层 Dio 透明：上层拿到的要么是真成功要么是真失效
/// - 永远不会"无声把 401 变成 200"（只有 retry 真拿到 200 才返回 200）
/// - 永远不循环自愈（`_selfHealed` 标记保护）
class SelfHealingInterceptor extends Interceptor {
  SelfHealingInterceptor({required this.retryDio});

  /// 用于重试的 Dio 实例。
  ///
  /// 应与原 Dio 同源但**不包含本拦截器**，否则会无限递归。
  final Dio retryDio;

  /// 防递归标记 key（写入到 `RequestOptions.extra` 中）。
  static const String selfHealedExtraKey = '_selfHealed';

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    throw UnimplementedError('Phase 4 实现');
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    throw UnimplementedError('Phase 4 实现');
  }

  /// 取消所有挂起的自愈重试。
  ///
  /// 调用时机：用户登出。
  Future<void> cancelAllRetries() {
    throw UnimplementedError('Phase 4 实现');
  }
}
