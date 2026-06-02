import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../cookie/cookie_jar_service.dart';
import '../cookie/cookie_logger.dart';
import '../cookie/session_cookie_sentinel.dart';

/// Dio 拦截器：401 / discourse-logged-out 透明自愈。
///
/// 设计依据：`docs/cookie-sync-design-v0.4.0.md` §5.3
///
/// 自愈触发条件（全部满足）：
/// 1. `statusCode ∈ {401, 419}` 或响应头含 `discourse-logged-out`
/// 2. 响应体不是 `error_type: 'not_logged_in'`（真登出不自愈）
/// 3. jar 中 `_t` 存在且未过期
/// 4. 本次请求未被自愈过（防递归，[selfHealedExtraKey] 标记）
///
/// 自愈流程：
/// 1. 标记 `_selfHealed = true`
/// 2. await `Sentinel.sweepAll(uri.origin)`
/// 3. await 100ms（给 WV 网络栈一点时间观察新 cookie）
/// 4. 重试原请求，最多 2 次
/// 5. 全失败 → Nuclear Reset → 重试 1 次
/// 6. 仍失败 → 透传原 401 响应（不吞）
///
/// 关键不变量（设计文档 §7 不变量 6）：
/// - 对上层 Dio 透明：上层拿到的要么是真成功要么是真失效
/// - 永远不会"无声把 401 变成 200"（只有 retry 真拿到 200 才返回 200）
/// - 永远不循环自愈（[selfHealedExtraKey] 标记保护）
class SelfHealingInterceptor extends Interceptor {
  SelfHealingInterceptor({required this.dio});

  /// 用于重试的 Dio 实例。
  ///
  /// 通常传入本身所在的 Dio。retry 时通过 [selfHealedExtraKey] 标记防递归，
  /// 重试请求经过本拦截器时会被 [_shouldHeal] 跳过。
  final Dio dio;

  /// 防递归标记 key（写入到 `RequestOptions.extra` 中）。
  static const String selfHealedExtraKey = '_selfHealed';

  // ---------------------------------------------------------------------------
  // 可注入依赖（测试用）
  // ---------------------------------------------------------------------------

  CookieJarService _jar = CookieJarService();
  SessionCookieSentinel _sentinel = SessionCookieSentinel.instance;

  @visibleForTesting
  void replaceDependenciesForTest({
    CookieJarService? jar,
    SessionCookieSentinel? sentinel,
  }) {
    if (jar != null) _jar = jar;
    if (sentinel != null) _sentinel = sentinel;
  }

  // ---------------------------------------------------------------------------
  // 公开 API
  // ---------------------------------------------------------------------------

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    if (!_shouldHealResponse(response)) {
      handler.next(response);
      return;
    }
    final newResponse = await _heal(response);
    if (newResponse != null) {
      handler.resolve(newResponse);
    } else {
      handler.next(response);
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    if (response == null || !_shouldHealResponse(response)) {
      handler.next(err);
      return;
    }
    final newResponse = await _heal(response);
    if (newResponse != null) {
      handler.resolve(newResponse);
    } else {
      handler.next(err);
    }
  }

  /// 取消所有挂起的自愈重试。
  ///
  /// 当前实现：no-op。
  /// 项目内调用方应在登出时调用 `AuthSession().advance()`，其内部
  /// 通过 `CancelToken.cancel()` 取消所有挂起请求（包括自愈 retry）。
  Future<void> cancelAllRetries() async {
    // 依赖 AuthSession.advance() 的 CancelToken 机制
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /// 判定该 response 是否应触发自愈。
  ///
  /// 不在此处检查 jar 状态（避免拦截器同步路径上调用异步方法）；
  /// jar 状态在 [_heal] 入口检查。
  bool _shouldHealResponse(Response<dynamic> response) {
    // 防递归
    if (response.requestOptions.extra[selfHealedExtraKey] == true) {
      return false;
    }

    final status = response.statusCode ?? 0;
    final hasLoggedOutHeader =
        response.headers.value('discourse-logged-out')?.isNotEmpty == true;

    if (status != 401 && status != 419 && !hasLoggedOutHeader) {
      return false;
    }

    // 真登出标识（Discourse: error_type='not_logged_in'）→ 不自愈
    final body = response.data;
    if (body is Map && body['error_type'] == 'not_logged_in') {
      return false;
    }

    return true;
  }

  /// 执行自愈：sweep → wait → retry; 失败 → Nuclear Reset → retry。
  ///
  /// 返回 retry 成功的 Response；全部失败返回 null（调用方透传原 response）。
  Future<Response<dynamic>?> _heal(Response<dynamic> response) async {
    final options = response.requestOptions;
    final uri = options.uri;

    // 检查 jar 中 _t 是否有效（jar 无 _t = 真登出）
    final jarT = await _jar.getCanonicalCookie('_t');
    final jarValid = jarT != null &&
        jarT.value.isNotEmpty &&
        (jarT.expiresAt == null || jarT.expiresAt!.isAfter(DateTime.now()));

    final origin = '${uri.scheme}://${uri.host}';

    if (!jarValid) {
      debugPrint(
        '[SelfHealing] skip: jar has no valid _t (uri=$uri)',
      );
      CookieLogger.selfHealing(
        event: 'triggered',
        url: origin,
        status: response.statusCode,
        jarHasValidToken: false,
      );
      return null;
    }

    debugPrint(
      '[SelfHealing] triggered: status=${response.statusCode}, uri=$uri',
    );
    CookieLogger.selfHealing(
      event: 'triggered',
      url: origin,
      status: response.statusCode,
      jarHasValidToken: true,
    );

    // Phase 1: 常规 sweep + retry (最多 2 次)
    try {
      await _sentinel.sweepAll(origin);
    } catch (e) {
      debugPrint('[SelfHealing] sweepAll failed (continuing): $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    for (var attempt = 1; attempt <= 2; attempt++) {
      CookieLogger.selfHealing(
        event: 'retry',
        url: origin,
        attempt: attempt,
      );
      final result = await _attemptRetry(options, attempt);
      if (result != null) {
        debugPrint(
          '[SelfHealing] success on attempt $attempt (uri=$uri)',
        );
        CookieLogger.selfHealing(
          event: 'success',
          url: origin,
          attemptsUsed: attempt,
        );
        return result;
      }
    }

    // Phase 2: Nuclear Reset + retry (1 次)
    debugPrint('[SelfHealing] sweep retries failed, trying nuclear reset');
    try {
      await _sentinel.nuclearReset(origin);
    } catch (e) {
      debugPrint('[SelfHealing] nuclearReset failed: $e');
      CookieLogger.selfHealing(
        event: 'failed',
        url: origin,
        attemptsUsed: 2,
        finalAction: 'nuclear_reset_threw: $e',
      );
      return null;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    CookieLogger.selfHealing(
      event: 'retry',
      url: origin,
      attempt: 3,
    );
    final finalResult = await _attemptRetry(options, 3);
    if (finalResult != null) {
      debugPrint(
        '[SelfHealing] success on nuclear-reset retry (uri=$uri)',
      );
      CookieLogger.selfHealing(
        event: 'success',
        url: origin,
        attemptsUsed: 3,
      );
      return finalResult;
    }

    debugPrint(
      '[SelfHealing] all retries failed (uri=$uri) → 透传原 401',
    );
    CookieLogger.selfHealing(
      event: 'failed',
      url: origin,
      attemptsUsed: 3,
      finalAction: 'pass_through_401',
    );
    return null;
  }

  /// 单次重试。打上 selfHealed 标记防递归。
  Future<Response<dynamic>?> _attemptRetry(
    RequestOptions options,
    int attempt,
  ) async {
    try {
      // 复制 options 避免污染原 options 的 extra
      final retryOptions = _cloneOptions(options);
      retryOptions.extra[selfHealedExtraKey] = true;

      final retryResp = await dio.fetch<dynamic>(retryOptions);
      final status = retryResp.statusCode ?? 0;
      if (status < 400) {
        return retryResp;
      }
      debugPrint(
        '[SelfHealing] retry $attempt got status $status (uri=${options.uri})',
      );
      return null;
    } catch (e) {
      debugPrint(
        '[SelfHealing] retry $attempt error: $e (uri=${options.uri})',
      );
      return null;
    }
  }

  /// 复制 RequestOptions 用于 retry。
  ///
  /// 关键字段必须复制，extra 用新 Map 隔离防止 selfHealed 标记污染原 options。
  RequestOptions _cloneOptions(RequestOptions src) {
    return RequestOptions(
      path: src.path,
      method: src.method,
      data: src.data,
      queryParameters: Map<String, dynamic>.from(src.queryParameters),
      headers: Map<String, dynamic>.from(src.headers),
      extra: Map<String, dynamic>.from(src.extra),
      baseUrl: src.baseUrl,
      connectTimeout: src.connectTimeout,
      sendTimeout: src.sendTimeout,
      receiveTimeout: src.receiveTimeout,
      contentType: src.contentType,
      responseType: src.responseType,
      validateStatus: src.validateStatus,
      receiveDataWhenStatusError: src.receiveDataWhenStatusError,
      followRedirects: src.followRedirects,
      maxRedirects: src.maxRedirects,
      persistentConnection: src.persistentConnection,
      requestEncoder: src.requestEncoder,
      responseDecoder: src.responseDecoder,
      listFormat: src.listFormat,
      cancelToken: src.cancelToken,
      onReceiveProgress: src.onReceiveProgress,
      onSendProgress: src.onSendProgress,
    );
  }
}
