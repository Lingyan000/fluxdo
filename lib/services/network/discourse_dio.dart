import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:flutter/foundation.dart';

import '../../constants.dart';
import 'adapters/platform_adapter.dart';
import 'cookie/app_cookie_manager.dart';
import 'cookie/cookie_jar_service.dart';
import 'cookie/csrf_token_service.dart';
import 'interceptors/cf_challenge_interceptor.dart';
import 'interceptors/request_scheduler_interceptor.dart';
import 'interceptors/session_guard_interceptor.dart';
import 'interceptors/cronet_fallback_interceptor.dart';
import 'interceptors/error_interceptor.dart';
import 'interceptors/network_log_interceptor.dart';
import 'interceptors/redirect_interceptor.dart';
import 'interceptors/request_header_interceptor.dart';
import 'interceptors/self_healing_interceptor.dart';

/// 统一封装的 Dio 工厂
class DiscourseDio {
  static Dio create({
    Duration connectTimeout = const Duration(seconds: 30),
    Duration receiveTimeout = const Duration(seconds: 30),
    Map<String, dynamic>? defaultHeaders,
    String? baseUrl,
    /// null 表示不限制（用于下载、MessageBus 等），非 null 启用调度器。
    /// 实际并发数和速率从 [RequestSchedulerConfig] 动态读取。
    int? maxConcurrent = 3,
    bool enableRetry = true,
    bool enableCfChallenge = true,
    bool enableCookies = true,
    bool enableNetworkLog = true,
    /// true 时强制使用稳定的 NativeAdapter,绕过 _DynamicAdapter 的 rhttp 切换。
    /// 用于 MessageBus 长轮询等需要长期保持连接、依赖系统级省电的场景。
    bool useStableAdapter = false,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl ?? AppConstants.baseUrl,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        headers: defaultHeaders,
        // 禁用自动重定向，手动处理以确保重定向时使用正确的 cookie
        followRedirects: false,
        // 包含重定向状态码，让我们手动处理
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );

    // 1. 配置平台适配器
    if (useStableAdapter) {
      configureStableNativeAdapter(dio);
    } else {
      configurePlatformAdapter(dio);
    }

    // 2. 会话代守卫（最先执行，确保过期请求不进入后续拦截器）
    dio.interceptors.add(SessionGuardInterceptor());

    // 3. 并发限制 + 滑动窗口速率限制（null 表示不限制）
    // 实际参数从 RequestSchedulerConfig 动态读取
    if (maxConcurrent != null) {
      dio.interceptors.add(RequestSchedulerInterceptor());
    }

    // 4. Cookie 管理
    final cookieJarService = CookieJarService();
    if (enableCookies && cookieJarService.isInitialized) {
      dio.interceptors.add(AppCookieManager(cookieJarService.cookieJar));
      // 4.1 v0.4.0: 401 / discourse-logged-out 透明自愈
      //
      // 注册顺序: AppCookieManager 在前, SelfHealing 在后。
      // Dio 规则: onResponse 按 LIFO 调用 → SelfHealing 先于 AppCookieManager。
      //
      // 这是必要的: 服务器拒绝时常带 Set-Cookie 清 _t。如果 AppCookieManager
      // 先 onResponse, jar 中 _t 被清空, SelfHealing 检查时认为"真登出"跳过自愈。
      // 反之让 SelfHealing 先 onResponse, 看到的是 jar 上一个稳定状态,
      // 能正确判定"jar 仍有效, WV 多变体导致服务器拒绝", 触发自愈。
      dio.interceptors.add(SelfHealingInterceptor(dio: dio));
    }

    // 5. Cronet 降级拦截器（在重试拦截器之前）
    dio.interceptors.add(CronetFallbackInterceptor(dio));

    // 6. 重试拦截器 (dio_smart_retry)
    if (enableRetry) {
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          logPrint: (msg) => debugPrint('[Dio Retry] $msg'),
          retries: 0, // TODO: 调试完成后改回 3
          retryDelays: const [
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 4),
          ],
          retryableExtraStatuses: {429, 502, 503, 504},
        ),
      );
    }

    // 7. 请求头拦截器
    dio.interceptors.add(RequestHeaderInterceptor(CsrfTokenService()));

    // 8. 重定向拦截器
    dio.interceptors.add(RedirectInterceptor(dio));

    // 9. 错误拦截器
    dio.interceptors.add(ErrorInterceptor());

    // 10. CF 验证拦截器
    if (enableCfChallenge) {
      dio.interceptors.add(
        CfChallengeInterceptor(dio: dio, cookieJarService: cookieJarService),
      );
    }

    // 11. 网络日志拦截器（最后一个，记录最终结果）
    // 注意：Gateway URL 改写已移至 HttpClientAdapter 层（_GatewayAdapterWrapper），
    // 所有拦截器始终看到原始 URL，无需额外处理。
    if (enableNetworkLog) {
      dio.interceptors.add(NetworkLogInterceptor());
    }

    return dio;
  }
}
