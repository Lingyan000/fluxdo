import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../services/network/exceptions/api_exception.dart';
import '../l10n/s.dart';

/// 结构化错误信息（图标 + 标题 + 描述）
class ErrorInfo {
  final IconData icon;
  final String title;
  final String message;

  const ErrorInfo({
    required this.icon,
    required this.title,
    required this.message,
  });
}

/// 错误信息工具类
/// 将各种异常转换为用户友好的错误提示
class ErrorUtils {
  /// 获取结构化的错误信息（图标 + 标题 + 描述）
  static ErrorInfo getErrorInfo(Object? error) {
    if (error == null) {
      return ErrorInfo(
        icon: Icons.error_outline_rounded,
        title: S.current.error_loadFailed,
        message: S.current.error_unknown,
      );
    }

    // 自定义异常
    if (error is RateLimitException) {
      return ErrorInfo(
        icon: Icons.speed_rounded,
        title: S.current.error_tooManyRequests,
        message: error.toString(),
      );
    }
    if (error is ServerException) {
      return ErrorInfo(
        icon: Icons.cloud_off_rounded,
        title: S.current.error_serverUnavailable,
        message: error.toString(),
      );
    }
    if (error is CfChallengeException) {
      return ErrorInfo(
        icon: Icons.shield_rounded,
        title: S.current.error_securityChallenge,
        message: _cfChallengeMessage(error),
      );
    }

    // Dio 异常
    if (error is DioException) {
      // 检查内嵌的自定义异常（如 CfChallengeException 通过 handler.reject 包装）
      final innerError = error.error;
      if (innerError is CfChallengeException) {
        return ErrorInfo(
          icon: Icons.shield_rounded,
          title: S.current.error_securityChallenge,
          message: _cfChallengeMessage(innerError),
        );
      }
      if (innerError is RateLimitException) {
        return ErrorInfo(
          icon: Icons.speed_rounded,
          title: S.current.error_tooManyRequests,
          message: innerError.toString(),
        );
      }
      if (innerError is ServerException) {
        return ErrorInfo(
          icon: Icons.cloud_off_rounded,
          title: S.current.error_serverUnavailable,
          message: innerError.toString(),
        );
      }
      return _handleDioException(error);
    }

    // 网络相关异常
    if (error is SocketException) {
      return ErrorInfo(
        icon: Icons.signal_wifi_off_rounded,
        title: S.current.error_networkUnavailable,
        message: S.current.error_networkCheckSettings,
      );
    }
    if (error is TimeoutException) {
      return ErrorInfo(
        icon: Icons.timer_off_rounded,
        title: S.current.error_connectionTimeout,
        message: S.current.error_requestTimeoutRetry,
      );
    }
    if (error is HttpException) {
      return ErrorInfo(
        icon: Icons.public_off_rounded,
        title: S.current.error_requestFailed,
        message: S.current.error_networkRequestFailed,
      );
    }
    if (error is FormatException) {
      return ErrorInfo(
        icon: Icons.data_object_rounded,
        title: S.current.error_dataException,
        message: S.current.error_unrecognizedDataFormat,
      );
    }

    // 通用 Exception
    if (error is Exception) {
      final message = error.toString();
      final cleaned = message.startsWith('Exception: ')
          ? message.substring(11)
          : message;
      return ErrorInfo(
        icon: Icons.error_outline_rounded,
        title: S.current.error_loadFailed,
        message: cleaned,
      );
    }

    return ErrorInfo(
      icon: Icons.error_outline_rounded,
      title: S.current.error_loadFailed,
      message: error.toString(),
    );
  }

  /// 获取用户友好的错误消息
  static String getFriendlyMessage(Object? error) {
    return getErrorInfo(error).message;
  }

  static String _cfChallengeMessage(CfChallengeException error) {
    if (error.inCooldown) return S.current.cf_dataBlockedByChallenge;
    return error.toString();
  }

  /// 获取完整的错误详情（用于调试）
  static String getErrorDetails(Object? error, [StackTrace? stackTrace]) {
    final buffer = StringBuffer();

    buffer.writeln('错误类型: ${error.runtimeType}');
    buffer.writeln('错误信息: $error');

    if (error is DioException) {
      buffer.writeln('');
      buffer.writeln('=== 请求详情 ===');
      buffer.writeln('URL: ${error.requestOptions.uri}');
      buffer.writeln('方法: ${error.requestOptions.method}');
      if (error.response != null) {
        buffer.writeln('状态码: ${error.response?.statusCode}');
        buffer.writeln('响应: ${error.response?.data}');
      }
    }

    if (stackTrace != null) {
      buffer.writeln('');
      buffer.writeln('=== 堆栈跟踪 ===');
      buffer.writeln(stackTrace.toString());
    }

    return buffer.toString();
  }

  static ErrorInfo _handleDioException(DioException error) {
    // 有 HTTP 响应的情况
    if (error.type == DioExceptionType.badResponse) {
      return _handleHttpStatus(error.response?.statusCode, error);
    }

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return ErrorInfo(
          icon: Icons.timer_off_rounded,
          title: S.current.error_connectionTimeout,
          message: S.current.error_cannotConnectCheckNetwork,
        );
      case DioExceptionType.receiveTimeout:
        return ErrorInfo(
          icon: Icons.hourglass_disabled_rounded,
          title: S.current.error_responseTimeout,
          message: S.current.error_serverResponseTooLong,
        );
      case DioExceptionType.connectionError:
        return ErrorInfo(
          icon: Icons.signal_wifi_off_rounded,
          title: S.current.error_networkUnavailable,
          message: S.current.error_networkCheckSettings,
        );
      case DioExceptionType.badCertificate:
        return ErrorInfo(
          icon: Icons.gpp_bad_rounded,
          title: S.current.error_certificateError,
          message: S.current.error_certificateVerifyFailed,
        );
      case DioExceptionType.cancel:
        return ErrorInfo(
          icon: Icons.cancel_outlined,
          title: S.current.error_requestCancelled,
          message: S.current.error_requestCancelledMsg,
        );
      default:
        // unknown 类型，检查内部 error
        if (error.error is SocketException) {
          return ErrorInfo(
            icon: Icons.signal_wifi_off_rounded,
            title: S.current.error_networkUnavailable,
            message: S.current.error_networkCheckSettings,
          );
        }
        // 检查错误信息中的网络错误模式（如 Chromium/Cronet 的 net:: 错误）
        final errorStr = error.error?.toString().toUpperCase() ?? '';
        if (errorStr.contains('TIMED_OUT') || errorStr.contains('TIMEOUT')) {
          return ErrorInfo(
            icon: Icons.timer_off_rounded,
            title: S.current.error_connectionTimeout,
            message: S.current.error_cannotConnectCheckNetwork,
          );
        }
        if (errorStr.contains('CONNECTION_REFUSED') ||
            errorStr.contains('CONNECTION_RESET') ||
            errorStr.contains('CONNECTION_CLOSED') ||
            errorStr.contains('CONNECTION_FAILED') ||
            errorStr.contains('NAME_NOT_RESOLVED') ||
            errorStr.contains('ADDRESS_UNREACHABLE') ||
            errorStr.contains('INTERNET_DISCONNECTED') ||
            errorStr.contains('NETWORK_CHANGED')) {
          return ErrorInfo(
            icon: Icons.signal_wifi_off_rounded,
            title: S.current.error_networkUnavailable,
            message: S.current.error_networkCheckSettings,
          );
        }
        if (errorStr.contains('SSL') ||
            errorStr.contains('CERT') ||
            errorStr.contains('CERTIFICATE')) {
          return ErrorInfo(
            icon: Icons.gpp_bad_rounded,
            title: S.current.error_certificateError,
            message: S.current.error_certificateVerifyFailed,
          );
        }
        // 尝试从响应中提取错误信息
        final data = error.response?.data;
        if (data is Map) {
          final errorMsg = data['error'] ?? data['message'];
          if (errorMsg is String && errorMsg.isNotEmpty) {
            return ErrorInfo(
              icon: Icons.error_outline_rounded,
              title: S.current.error_requestFailed,
              message: errorMsg,
            );
          }
          final errors = data['errors'];
          if (errors is List && errors.isNotEmpty) {
            return ErrorInfo(
              icon: Icons.error_outline_rounded,
              title: S.current.error_requestFailed,
              message: errors.first.toString(),
            );
          }
        }
        return ErrorInfo(
          icon: Icons.public_off_rounded,
          title: S.current.error_requestFailed,
          message: S.current.error_networkRequestFailed,
        );
    }
  }

  static ErrorInfo _handleHttpStatus(int? statusCode, DioException error) {
    // 先尝试从响应体提取服务器返回的具体错误信息
    String? serverMessage;
    final data = error.response?.data;
    if (data is Map) {
      final errorMsg = data['error'] ?? data['message'];
      if (errorMsg is String && errorMsg.isNotEmpty) {
        serverMessage = errorMsg;
      } else {
        final errors = data['errors'];
        if (errors is List && errors.isNotEmpty) {
          serverMessage = errors.first.toString();
        }
      }
    }

    switch (statusCode) {
      case 400:
        return ErrorInfo(
          icon: Icons.error_outline_rounded,
          title: S.current.error_badRequest,
          message: serverMessage ?? S.current.error_badRequestParams,
        );
      case 401:
        return ErrorInfo(
          icon: Icons.lock_outline_rounded,
          title: S.current.error_unauthorized,
          message: serverMessage ?? S.current.error_unauthorizedExpired,
        );
      case 403:
        return ErrorInfo(
          icon: Icons.block_rounded,
          title: S.current.error_forbidden,
          message: serverMessage ?? S.current.error_forbiddenAccess,
        );
      case 404:
        return ErrorInfo(
          icon: Icons.explore_off_rounded,
          title: S.current.error_notFound,
          message: serverMessage ?? S.current.error_notFoundOrDeleted,
        );
      case 410:
        return ErrorInfo(
          icon: Icons.delete_outline_rounded,
          title: S.current.error_gone,
          message: serverMessage ?? S.current.error_contentDeleted,
        );
      case 422:
        return ErrorInfo(
          icon: Icons.warning_amber_rounded,
          title: S.current.error_unprocessable,
          message: serverMessage ?? S.current.error_requestUnprocessable,
        );
      case 429:
        return ErrorInfo(
          icon: Icons.speed_rounded,
          title: S.current.error_rateLimited,
          message: serverMessage ?? S.current.error_rateLimitedRetryLater,
        );
      case 500:
        return ErrorInfo(
          icon: Icons.cloud_off_rounded,
          title: S.current.error_serverError,
          message: serverMessage ?? S.current.error_internalServerError,
        );
      case 502:
      case 503:
      case 504:
        return ErrorInfo(
          icon: Icons.cloud_off_rounded,
          title: S.current.error_serviceUnavailable,
          message: serverMessage ?? S.current.error_serviceUnavailableRetry,
        );
      default:
        return ErrorInfo(
          icon: Icons.error_outline_rounded,
          title: S.current.error_requestFailed,
          message:
              serverMessage ??
              S.current.error_requestFailedWithCode(statusCode ?? 0),
        );
    }
  }
}
