import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../app_logger.dart';
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

  /// 取 CSRF 用的 Dio。
  ///
  /// 由 DiscourseService 在构造时注入它自己的主 dio —— 那条链带完整拦截器
  /// (CfChallengeInterceptor 能在 cf_clearance 失效时兜底弹验证、
  /// AppCookieManager 保证 cookie 一致、恢复层处理瞬态失败)。
  ///
  /// 历史上这里自建了一个只装 3 个拦截器的独立 Dio,结果在后台/会话失效
  /// 窗口撞 CF 时静默失败(UserApiKeyService 的注释记录了这次事故),
  /// 而它的存在理由(UA 要与 WebView 一致)在主链上由
  /// RequestHeaderInterceptor 同样满足。
  Dio? _dio;

  /// 注册取 CSRF 用的主 dio。只应由 DiscourseService 调用一次。
  void attachDio(Dio dio) {
    _dio ??= dio;
  }

  /// 正在进行的 CSRF 刷新请求（防止并发重复请求，与 Discourse 前端的 activeCsrfRequest 对齐）
  Future<void>? _activeCsrfRequest;

  /// 上次刷新失败的时刻。冷却窗口内不再重复打 /session/csrf:
  /// 被 CF 速率限制盯上时(429 挑战页),每次用户重试都再撞一次盾只会
  /// 越刷越差,必须掐断重试风暴。
  DateTime? _lastFailureAt;
  static const _failureCooldown = Duration(seconds: 30);

  String? get csrfToken => _csrfToken;

  /// 是否处于刷新失败冷却窗口内(诊断用)。
  bool get isInFailureCooldown {
    final lastFailureAt = _lastFailureAt;
    if (lastFailureAt == null) return false;
    return DateTime.now().difference(lastFailureAt) < _failureCooldown;
  }

  /// 上次刷新失败时刻(诊断用)。
  DateTime? get lastFailureAt => _lastFailureAt;

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
    // 持久化是尽力而为:内存里的 token 已经可用,落盘只为跨进程复用。
    // keychain 不可用(权限/插件缺失/系统异常)不该让本次刷新算失败,
    // 更不该冒泡成未处理的异步错误。
    unawaited(
      _storage.write(key: _csrfTokenKey, value: token).catchError((Object e) {
        debugPrint('[CsrfTokenService] CSRF token 持久化失败(忽略): $e');
      }),
    );
  }

  /// 清空 CSRF token（BAD CSRF 时调用，下次 POST 前会自动刷新）
  void clearCsrfToken() {
    _csrfToken = null;
    // BAD CSRF 说明业务请求已到达服务端(非 CF 拦截),放行下一次刷新
    _lastFailureAt = null;
    unawaited(
      _storage.delete(key: _csrfTokenKey).catchError((Object e) {
        debugPrint('[CsrfTokenService] CSRF token 清除失败(忽略): $e');
      }),
    );
  }

  /// 从主站 /session/csrf 获取新的 CSRF token
  /// 带去重：多个并发调用共享同一个请求（对齐 Discourse 前端的 updateCsrfToken）
  /// 带失败冷却：上次失败后 30s 内直接返回，不重复请求
  Future<void> updateCsrfToken() {
    final lastFailureAt = _lastFailureAt;
    if (_activeCsrfRequest == null &&
        lastFailureAt != null &&
        DateTime.now().difference(lastFailureAt) < _failureCooldown) {
      return Future.value();
    }
    _activeCsrfRequest ??= _fetchCsrfToken().whenComplete(() {
      _activeCsrfRequest = null;
    });
    return _activeCsrfRequest!;
  }

  Future<void> _fetchCsrfToken() async {
    final dio = _dio;
    if (dio == null) {
      debugPrint('[CsrfTokenService] 主 dio 未注册,跳过 CSRF 刷新');
      return;
    }
    try {
      const path = '/session/csrf';
      final response = await dio.get(
        path,
        options: Options(
          extra: {
            'skipCsrf': true,
            'skipAuthCheck': true,
            'isSilent': true,
            'skipScheduler': true, // 绕过并发调度，避免与调用方的并发槽位死锁
            // 诊断标注:撞 CF 盾时日志里能一眼看出是 CSRF 刷新链路
            'requestTag': 'csrf-refresh',
          },
        ),
      );
      final csrf = _extractCsrf(response.data);
      if (csrf != null && csrf.isNotEmpty) {
        _lastFailureAt = null;
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
      _lastFailureAt = DateTime.now();
      final statusCode = e.response?.statusCode;
      final uri = e.requestOptions.uri.toString();
      final responseText = e.response?.data?.toString();
      final responsePreview = responseText == null
          ? '<null>'
          : responseText.substring(
              0,
              responseText.length > 200 ? 200 : responseText.length,
            );
      // 诊断 CF 挑战判定:这三个头决定 isCfChallengeResponse 是否命中,
      // 某些传输通道下头部可能缺失/走样,失败日志里必须留痕。
      final headers = e.response?.headers;
      final serverHeader = headers?.value('server');
      final cfMitigated = headers?.value('cf-mitigated');
      final contentType = headers?.value('content-type');
      final message =
          'CSRF token 刷新失败: status=$statusCode, url=$uri, '
          'type=${e.type}, server=$serverHeader, cfMitigated=$cfMitigated, '
          'contentType=$contentType, response=$responsePreview';
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
          'serverHeader': serverHeader,
          'cfMitigated': cfMitigated,
          'contentType': contentType,
        },
      );
    } catch (e, stackTrace) {
      _lastFailureAt = DateTime.now();
      debugPrint('[CsrfTokenService] CSRF token 刷新失败: $e');
      AppLogger.error(
        'CSRF token 刷新异常',
        tag: 'CsrfTokenService',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 从响应体提取 csrf。主链的 BackgroundTransformer 在部分 content-type
  /// 下会交回未解码的 String,两种形态都要认(与
  /// UserApiKeyService._fetchCsrfViaMainDio 同口径)。
  static String? _extractCsrf(dynamic data) {
    if (data is Map) return data['csrf'] as String?;
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return decoded['csrf'] as String?;
      } catch (_) {}
    }
    return null;
  }

  /// 重置（登出时调用）
  Future<void> reset() async {
    _csrfToken = null;
    _lastFailureAt = null;
    // 内存态已清,落盘失败不影响登出正确性
    try {
      await _storage.delete(key: _csrfTokenKey);
    } catch (e) {
      debugPrint('[CsrfTokenService] CSRF token 清除失败(忽略): $e');
    }
  }
}
