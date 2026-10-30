import 'package:dio/dio.dart';

import '../../../l10n/s.dart';

import '../../cf_challenge_service.dart';
import 'api_exception.dart';

/// OAuth 登录态过期异常，只表示业务服务确认的未登录状态。
class OAuthExpiredException implements Exception {
  final String serviceName;
  final int? statusCode;

  const OAuthExpiredException({required this.serviceName, this.statusCode});

  @override
  String toString() => '$serviceName ${S.current.common_authExpired}';
}

/// CF 挑战优先于 HTTP 状态码；普通 403 可能是权限或风控限制。
class OAuthErrorPolicy {
  OAuthErrorPolicy._();

  static bool isCfChallenge(Object? error) =>
      error is CfChallengeException ||
      (error is DioException &&
          (error.error is CfChallengeException ||
              CfChallengeService.isCfChallengeResponse(error.response)));

  static Object classify(DioException error, {required String serviceName}) {
    if (isCfChallenge(error)) {
      return error.error is CfChallengeException
          ? error
          : error.copyWith(error: CfChallengeException());
    }
    if (error.response?.statusCode == 401) {
      return OAuthExpiredException(serviceName: serviceName, statusCode: 401);
    }
    return error;
  }
}
