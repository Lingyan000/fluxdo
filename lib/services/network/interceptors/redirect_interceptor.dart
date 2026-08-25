import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../flux_request_spec.dart';

/// 重定向拦截器
/// 手动处理 301/302/307/308 重定向，确保重定向时使用正确的 cookie
class RedirectInterceptor extends Interceptor {
  RedirectInterceptor(this._dio);

  final Dio _dio;
  static const String _redirectCountKey = '_redirectCount';
  static const int _maxRedirects = 10;

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    // 检查是否跳过重定向处理
    if (response.requestOptions.spec.skipRedirect) {
      return handler.next(response);
    }

    final statusCode = response.statusCode;
    if (statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 307 ||
        statusCode == 308) {
      final location = response.headers.value('location');
      if (location != null) {
        debugPrint('[Dio] Redirect $statusCode -> $location');

        final redirectCount =
            response.requestOptions.extra[_redirectCountKey] as int? ?? 0;
        if (redirectCount >= _maxRedirects) {
          return handler.reject(
            DioException(
              requestOptions: response.requestOptions,
              response: response,
              type: DioExceptionType.badResponse,
              error: '重定向次数超过上限 $_maxRedirects',
            ),
          );
        }

        // 解析重定向 URL
        final redirectUri = Uri.parse(location);
        final absoluteUrl = redirectUri.isAbsolute
            ? location
            : response.requestOptions.uri.resolve(location).toString();

        // 创建新请求，不保留原始 cookie header
        // CookieManager 会为新 URL 重新获取正确的 cookie
        final redirectExtra =
            Map<String, dynamic>.from(response.requestOptions.extra)
              // 当前原请求仍占用调度槽位。内部重定向必须绕过调度器，否则并发槽
              // 和速率窗口会被重定向链自己耗尽，外层响应也无法完成释放。
              ..['skipScheduler'] = true
              ..[_redirectCountKey] = redirectCount + 1;
        final newOptions = Options(
          method: response.requestOptions.method,
          headers: Map<String, dynamic>.from(response.requestOptions.headers)
            ..remove('cookie')
            ..remove('Cookie'),
          extra: redirectExtra,
          responseType: response.requestOptions.responseType,
          validateStatus: response.requestOptions.validateStatus,
        );

        try {
          final redirectResponse = await _dio.request(
            absoluteUrl,
            options: newOptions,
          );
          return handler.resolve(redirectResponse);
        } catch (e) {
          if (e is DioException) {
            return handler.reject(e);
          }
          rethrow;
        }
      }
    }
    handler.next(response);
  }
}
