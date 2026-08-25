import 'package:dio/dio.dart';

import '../../../constants.dart';
import '../../log/log_writer.dart';
import '../../user_presence_service.dart';
import '../cookie/csrf_token_service.dart';
import '../flux_request_spec.dart';
import '../health/network_health_controller.dart';

/// 请求头拦截器
/// 负责设置 User-Agent 和 CSRF Token
/// CSRF 策略对齐 Discourse 官方前端：POST 前 token 为空则先从 /session/csrf 获取
class RequestHeaderInterceptor extends Interceptor {
  RequestHeaderInterceptor(this._cookieSync);

  final CsrfTokenService _cookieSync;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // 1. 设置 User-Agent
    options.headers['User-Agent'] = await AppConstants.getUserAgent();

    // 2. 注入 Client Hints 请求头（Sec-CH-UA 系列，仅移动端可用）
    final hints = AppConstants.clientHints;
    if (hints != null) {
      options.headers.addAll(hints);
    }

    // 3. 设置 CSRF Token（未登录时无法获取，跳过）
    final skipCsrf = options.spec.skipCsrf;
    if (!skipCsrf) {
      // 非 GET 请求且 token 为空时，先从 /session/csrf 获取
      // 对齐 Discourse 前端: if (type !== "GET" && !csrfToken) { updateCsrfToken() }
      final method = options.method.toUpperCase();
      if (method != 'GET' &&
          (_cookieSync.csrfToken == null || _cookieSync.csrfToken!.isEmpty)) {
        await _cookieSync.updateCsrfToken();
      }

      final csrf = _cookieSync.csrfToken;
      if (method != 'GET' && (csrf == null || csrf.isEmpty)) {
        options.headers.remove('X-CSRF-Token');
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'request',
          'event': 'csrf_unavailable_before_request',
          'message': 'POST 前无法取得 CSRF token，已取消请求以避免 BAD CSRF',
          'method': options.method,
          'url': options.uri.toString(),
          'isSilent': options.spec.isSilent,
        });
        // 取不到 CSRF 就取消写请求,是用户可感知的失败(发帖/点赞失效)。
        // 记录此刻通道健康,便于区分"CF 盾挡住了刷新"与"纯粹未登录"。
        NetworkHealthController.instance.dumpToLog('csrf_unavailable');
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            error:
                'CSRF token unavailable before ${options.method} ${options.uri.path}',
          ),
          true,
        );
        return;
      }
      if (csrf != null && csrf.isNotEmpty) {
        options.headers['X-CSRF-Token'] = csrf;
      } else {
        options.headers.remove('X-CSRF-Token');
      }
    }

    // 4. API 请求（XHR）设置 Origin、Referer 和 Sec-Fetch-* 头
    if (options.headers['X-Requested-With'] == 'XMLHttpRequest') {
      options.headers['Origin'] = AppConstants.baseUrl;
      options.headers['Referer'] = '${AppConstants.baseUrl}/';
      // Sec-Fetch-* 系列头：Chrome 从 2019 年起每个请求都自动添加，
      // 缺失会被 Cloudflare Bot Management 识别为非浏览器客户端
      options.headers['Sec-Fetch-Dest'] = 'empty';
      options.headers['Sec-Fetch-Mode'] = 'cors';
      options.headers['Sec-Fetch-Site'] = 'same-origin';
      // 告知 Discourse 用户当前在线，使后端更新 last_seen_at
      // 对齐 Discourse 前端: if (userPresent()) { headers["Discourse-Present"] = "true"; }
      if (UserPresenceService().isPresent) {
        options.headers['Discourse-Present'] = 'true';
      } else {
        options.headers.remove('Discourse-Present');
      }
    }

    handler.next(options);
  }
}
