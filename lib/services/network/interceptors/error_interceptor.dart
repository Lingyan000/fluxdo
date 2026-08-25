import 'package:dio/dio.dart';

import '../../../l10n/s.dart';
import '../../cf_challenge_service.dart';
import '../../toast_service.dart';
import '../exceptions/api_exception.dart';
import '../flux_request_spec.dart';
import '../recovery/retry_after.dart';

/// 错误拦截器
/// 处理 429/502/503/504 错误，转换为自定义异常
/// 操作性请求（POST/PUT/DELETE/PATCH）默认显示错误提示
/// 可通过 FluxRequestKeys.showErrorToast 或 isSilent 手动控制
class ErrorInterceptor extends Interceptor {
  /// 操作性请求方法，默认显示错误提示
  static const _mutationMethods = {'POST', 'PUT', 'DELETE', 'PATCH'};

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final statusCode = err.response?.statusCode;
    final method = err.requestOptions.method.toUpperCase();
    final spec = err.requestOptions.spec;

    // CF 盾 403/429 由 CfChallengeInterceptor 统一决定展示形态:
    // 页面数据走错误态按钮,操作请求走明确提示,静默请求不打扰。
    // CF 速率限制规则配 managed_challenge 时返回 429 + 挑战页,不是真正的速率限制,
    // 不能落入下方 429 分支弹"请等待 N 秒"toast、抛 RateLimitException。
    if ((statusCode == 403 || statusCode == 429) &&
        CfChallengeService.isCfChallengeResponse(err.response)) {
      handler.next(err);
      return;
    }

    // CF 恢复协调产生的本地取消应保持原始语义，不显示通用请求失败提示。
    if (err.error is CfChallengeException) {
      handler.next(err);
      return;
    }

    // 静默模式：不显示任何错误提示
    if (spec.isSilent) {
      handler.next(err);
      return;
    }

    // 判断是否显示错误提示：
    // 1. 如果 extra 中明确指定了 showErrorToast，使用指定的值
    // 2. 否则，操作性请求默认显示
    final showErrorToast = spec.hasExplicitErrorToast
        ? spec.showErrorToast
        : _mutationMethods.contains(method);

    // 提取错误信息
    String? errorMessage;
    final data = err.response?.data;
    if (data is Map<String, dynamic>) {
      // Discourse API 错误格式
      errorMessage =
          data['error'] as String? ??
          (data['errors'] as List?)?.firstOrNull?.toString();
    }

    // 转成类型化异常供 UI 层处理。
    //
    // 必须用 handler.next 携带原 err(含 response)而不是 throw:
    // 拦截器 onError 里 throw 会让 DioException 被整体替换,response 丢失,
    // 下游拦截器(CF 验证/网络日志)与调用方只能看到 statusCode=null——
    // 网络日志里 429/5xx 恒记 null、业务层拿不到服务端报错文案都源于此。
    // 用 next 而非 reject:保持与原 throw 一致的"继续走完错误链"语义,
    // 让 NetworkLog 仍能记录这次失败。
    if (statusCode == 429) {
      final retryAfter = extractRetryAfterSeconds(err.response);
      if (showErrorToast) {
        final toastMessage = retryAfter != null && retryAfter > 0
            ? S.current.network_rateLimitedWait(_formatWaitDuration(retryAfter))
            : (errorMessage ?? S.current.network_rateLimited);
        ToastService.showError(toastMessage);
      }
      handler.next(
        err.copyWith(
          error: RateLimitException(retryAfter, errorMessage, err.response),
        ),
      );
      return;
    }
    if (statusCode == 502 || statusCode == 503 || statusCode == 504) {
      if (showErrorToast) {
        ToastService.showError(
          errorMessage ?? S.current.network_serverUnavailableRetry,
        );
      }
      handler.next(
        err.copyWith(error: ServerException(statusCode!, err.response)),
      );
      return;
    }

    // 其他错误
    if (showErrorToast) {
      if (errorMessage != null) {
        ToastService.showError(errorMessage);
      } else {
        // 通用错误提示
        final message = switch (statusCode) {
          400 => S.current.network_badRequest,
          401 => S.current.network_unauthorized,
          403 => S.current.network_forbidden,
          404 => S.current.network_notFound,
          422 => S.current.network_unprocessable,
          500 => S.current.network_internalError,
          _ => S.current.error_requestFailed,
        };
        ToastService.showError(message);
      }
    }

    handler.next(err);
  }

  String _formatWaitDuration(int seconds) {
    if (seconds >= 86400) {
      return S.current.time_days((seconds / 86400).ceil());
    }
    if (seconds >= 3600) {
      return S.current.time_hours((seconds / 3600).ceil());
    }
    if (seconds >= 60) {
      return S.current.time_minutes((seconds / 60).ceil());
    }
    return S.current.time_seconds(seconds);
  }
}
