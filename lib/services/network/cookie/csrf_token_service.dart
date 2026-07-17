import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../constants.dart';
import '../../app_logger.dart';
import '../adapters/platform_adapter.dart';
import '../interceptors/cf_challenge_interceptor.dart';
import 'app_cookie_manager.dart';
import 'cookie_jar_service.dart';
import '../../storage/resilient_secure_storage.dart';

/// Cookie 同步服务
/// 管理 CSRF token，支持自动刷新（对齐 Discourse 官方前端策略）
class CsrfTokenService {
  static final CsrfTokenService _instance = CsrfTokenService._internal();
  factory CsrfTokenService() => _instance;
  CsrfTokenService._internal();

  static const String _csrfTokenKey = 'linux_do_csrf_token';

  final ResilientSecureStorage _storage = ResilientSecureStorage();

  String? _csrfToken;
  Dio? _mainSiteDio;

  /// 正在进行的 CSRF 刷新请求（防止并发重复请求，与 Discourse 前端的 activeCsrfRequest 对齐）
  Future<void>? _activeCsrfRequest;

  String? get csrfToken => _csrfToken;

  /// 初始化：从本地存储恢复 CSRF token
  Future<void> init() async {
    final raw = await _storage.read(key: _csrfTokenKey);
    if (raw != null && raw.isNotEmpty) {
      _csrfToken = raw;
    }
  }

  void setCsrfToken(String? token) {
    if (token == null || token.isEmpty) return;
    _csrfToken = token;
    unawaited(_storage.write(key: _csrfTokenKey, value: token));
  }

  /// 清空 CSRF token（BAD CSRF 时调用，下次 POST 前会自动刷新）
  void clearCsrfToken() {
    _csrfToken = null;
    unawaited(_storage.delete(key: _csrfTokenKey));
  }

  /// 从主站 /session/csrf 获取新的 CSRF token
  /// 带去重：多个并发调用共享同一个请求（对齐 Discourse 前端的 updateCsrfToken）
  Future<void> updateCsrfToken() {
    _activeCsrfRequest ??= _fetchCsrfToken().whenComplete(() {
      _activeCsrfRequest = null;
    });
    return _activeCsrfRequest!;
  }

  Future<Dio> _getMainSiteDio() async {
    if (_mainSiteDio != null) return _mainSiteDio!;

    final cookieJarService = CookieJarService();
    if (!cookieJarService.isInitialized) {
      await cookieJarService.initialize();
    }

    final dio = Dio(
      BaseOptions(
        baseUrl: AppConstants.baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
        // 跟 DiscourseService._dio 的 defaultHeaders 一致, 否则 CF 看 fingerprint
        // 不一致 (缺 Accept/X-Requested-With/User-Agent) 直接当 bot 拦, GET
        // /session/csrf 永远 403, CSRF 死循环。
        //
        // User-Agent 单独在下面异步补上（不能放进这个 const map）：
        // AppConstants.getUserAgent() 读的是本机 WebView 引擎真实的
        // navigator.userAgent——cf_clearance 正是这个 UA 拿到手的。这里
        // 之前一直没设，所以这个 Dio 发出去的请求用的是 Dio/HTTP 客户端的
        // 默认 UA，跟签发 cf_clearance 时的 UA 对不上，Cloudflare 直接
        // 判定成非浏览器客户端来源——这才是"主站浏览正常，偏偏 CSRF/
        // User API Key 这几个走独立 Dio 的请求老过不了盾"的真正根因。
        headers: const {
          'Accept': 'application/json, text/javascript, */*; q=0.01',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          'X-Requested-With': 'XMLHttpRequest',
        },
      ),
    );
    dio.options.headers['User-Agent'] = await AppConstants.getUserAgent();

    configurePlatformAdapter(dio);
    dio.interceptors.add(AppCookieManager(cookieJarService.cookieJar));
    // 必须装 CfChallengeInterceptor: jar 没 cf_clearance 时 CSRF 也会被 CF 403,
    // 没这个 interceptor → silent fail → 整条 native 登录链路死锁。
    dio.interceptors.add(
      CfChallengeInterceptor(dio: dio, cookieJarService: cookieJarService),
    );
    _mainSiteDio = dio;
    return dio;
  }

  Future<void> _fetchCsrfToken() async {
    try {
      final dio = await _getMainSiteDio();
      const path = '/session/csrf';
      final response = await dio.get(
        path,
        options: Options(
          extra: {
            'skipCsrf': true,
            'skipAuthCheck': true,
            'isSilent': true,
            'skipScheduler': true, // 绕过并发调度，避免与调用方的并发槽位死锁
          },
        ),
      );
      final csrf = (response.data as Map<String, dynamic>?)?['csrf'] as String?;
      if (csrf != null && csrf.isNotEmpty) {
        setCsrfToken(csrf);
        debugPrint('[CsrfTokenService] CSRF token 已刷新');
        AppLogger.info(
          'CSRF token 已刷新',
          tag: 'CsrfTokenService',
          fields: {
            'type': 'auth',
            'event': 'csrf_token_refreshed',
            'url': response.requestOptions.uri.toString(),
            'csrfLen': csrf.length,
          },
        );
      }
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final uri = e.requestOptions.uri.toString();
      final responseText = e.response?.data?.toString();
      final responsePreview = responseText == null
          ? '<null>'
          : responseText.substring(
              0,
              responseText.length > 200 ? 200 : responseText.length,
            );
      final message =
          'CSRF token 刷新失败: status=$statusCode, url=$uri, '
          'type=${e.type}, response=$responsePreview';
      debugPrint('[CsrfTokenService] $message');
      AppLogger.warning(
        message,
        tag: 'CsrfTokenService',
        fields: {
          'type': 'auth',
          'event': 'csrf_token_refresh_failed',
          'statusCode': statusCode,
          'url': uri,
          'errorType': e.type.toString(),
        },
      );
    } catch (e, stackTrace) {
      debugPrint('[CsrfTokenService] CSRF token 刷新失败: $e');
      AppLogger.error(
        'CSRF token 刷新异常',
        tag: 'CsrfTokenService',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 重置（登出时调用）
  Future<void> reset() async {
    _csrfToken = null;
    await _storage.delete(key: _csrfTokenKey);
  }
}
