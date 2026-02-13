import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:flutter/foundation.dart';

import '../../constants.dart';
import 'adapters/platform_adapter.dart';
import 'cookie/app_cookie_manager.dart';
import 'cookie/cookie_jar_service.dart';
import 'cookie/cookie_sync_service.dart';
import 'interceptors/cf_challenge_interceptor.dart';
import 'interceptors/cronet_fallback_interceptor.dart';
import 'interceptors/error_interceptor.dart';
import 'interceptors/redirect_interceptor.dart';
import 'interceptors/request_header_interceptor.dart';

/// 统一封装的 Dio 工厂
class DiscourseDio {
  static Dio create({
    Duration connectTimeout = const Duration(seconds: 30),
    Duration receiveTimeout = const Duration(seconds: 30),
    Map<String, dynamic>? defaultHeaders,
  }) {
    final dio = Dio(BaseOptions(
      baseUrl: AppConstants.baseUrl,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: defaultHeaders,
      // 禁用自动重定向，手动处理以确保重定向时使用正确的 cookie
      followRedirects: false,
      // 包含重定向状态码，让我们手动处理
      validateStatus: (status) => status != null && status >= 200 && status < 400,
    ));

    // 1. 配置平台适配器
    configurePlatformAdapter(dio);

    // 2. Cookie 管理
    final cookieJarService = CookieJarService();
    if (cookieJarService.isInitialized) {
      dio.interceptors.add(AppCookieManager(cookieJarService.cookieJar));
    }

    // 3. Cronet 降级拦截器（在重试拦截器之前）
    dio.interceptors.add(CronetFallbackInterceptor(dio));

    // 4. 重试拦截器 (dio_smart_retry)
    dio.interceptors.add(RetryInterceptor(
      dio: dio,
      logPrint: (msg) => debugPrint('[Dio Retry] $msg'),
      retries: 3,
      retryDelays: const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ],
      retryableExtraStatuses: {429, 502, 503, 504},
    ));

    // 5. 请求头拦截器
    dio.interceptors.add(RequestHeaderInterceptor(CookieSyncService()));

    // 6. 重定向拦截器
    dio.interceptors.add(RedirectInterceptor(dio));

    // 7. 错误拦截器
    dio.interceptors.add(ErrorInterceptor());

    // 8. CF 验证拦截器
    dio.interceptors.add(CfChallengeInterceptor(
      dio: dio,
      cookieJarService: cookieJarService,
    ));

    return dio;
  }
}
