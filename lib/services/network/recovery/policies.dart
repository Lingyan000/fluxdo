import 'dart:io';

import 'package:dio/dio.dart';

import '../exceptions/api_exception.dart';
import 'recovery_policy.dart';
import 'retry_after.dart';

/// 限流(429)恢复策略。
///
/// CF 的速率限制规则配 managed_challenge 时会返回
/// `429 + cf-mitigated: challenge` —— 那是挑战不是限流。能走到本策略的 429
/// 才是真正的服务端限流。
///
/// 分界靠 [isChallengeResponse] 钩子:命中即放行,交给 CfChallengeInterceptor。
/// 那条链**刻意留在恢复层之外**(它的重试后处置要换传输方式再放、失败还要
/// 回滚副作用,超出 [RecoveryDecision] 的表达力),详见该类的文档注释。
///
/// 决策:
/// - 服务端给出了可接受的等待时长 → 延迟后重放;
/// - 等待过长(超过 [maxWaitSeconds])或没给时长 → 不重放,包装成
///   [RateLimitException] 让业务层决定(它可能想提示用户而不是干等)。
class RateLimitPolicy implements RecoveryPolicy {
  const RateLimitPolicy({
    this.maxWaitSeconds = 30,
    this.isChallengeResponse,
  });

  /// 愿意自动等待的上限。超过则交回业务层。
  final int maxWaitSeconds;

  /// 判定"这个 429 其实是 CF 挑战"的钩子。
  ///
  /// 注入而非直接依赖 CfChallengeService,是为了让策略可单测,
  /// 同时避免恢复层反向依赖 CF 那一大坨 UI 代码。
  final bool Function(Response<dynamic>? response)? isChallengeResponse;

  @override
  String get name => 'rate-limit';

  @override
  bool canHandle(AttemptOutcome outcome) {
    if (outcome.isSuccess) return false;
    if (outcome.statusCode != 429) return false;
    // 挑战型 429 不归本策略
    if (isChallengeResponse?.call(outcome.error!.response) == true) {
      return false;
    }
    return true;
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    final err = outcome.error!;
    final waitSeconds = extractRetryAfterSeconds(err.response);

    if (waitSeconds != null &&
        waitSeconds > 0 &&
        waitSeconds <= maxWaitSeconds) {
      return RecoveryDecision.retry(delay: Duration(seconds: waitSeconds));
    }

    // 不自动等待:交回业务层,但保留 response(业务层要读服务端文案)
    return RecoveryDecision.fail(
      err.copyWith(
        error: RateLimitException(
          waitSeconds,
          _errorMessageOf(err.response),
          err.response,
        ),
      ),
    );
  }

  static String? _errorMessageOf(Response<dynamic>? response) {
    final data = response?.data;
    if (data is Map<String, dynamic>) {
      return data['error'] as String? ??
          (data['errors'] as List?)?.firstOrNull?.toString();
    }
    return null;
  }
}

/// 瞬态故障恢复策略:5xx 与连接类错误。
///
/// 只对幂等方法生效——POST 重放可能造成重复发帖/重复点赞,宁可失败也不
/// 冒这个风险(这也是为什么它不能简单等价于 dio_smart_retry 的默认行为:
/// 后者对所有方法一视同仁)。
class TransientRetryPolicy implements RecoveryPolicy {
  const TransientRetryPolicy({
    this.delays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  });

  /// 第 N 次重放前的等待时长(指数退避)。
  final List<Duration> delays;

  static const _idempotentMethods = {'GET', 'HEAD', 'OPTIONS'};
  static const _retryableStatuses = {502, 503, 504};

  @override
  String get name => 'transient-retry';

  @override
  bool canHandle(AttemptOutcome outcome) {
    if (outcome.isSuccess) return false;
    final err = outcome.error!;
    if (!_idempotentMethods.contains(err.requestOptions.method.toUpperCase())) {
      return false;
    }
    final status = outcome.statusCode;
    if (status != null) return _retryableStatuses.contains(status);
    return _isTransientNetworkError(err);
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    final index = outcome.attemptIndex.clamp(0, delays.length - 1);
    return RecoveryDecision.retry(delay: delays[index]);
  }

  static bool _isTransientNetworkError(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return true;
      case DioExceptionType.badCertificate:
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
        return false;
      case DioExceptionType.unknown:
        return err.error is SocketException;
      default:
        return false;
    }
  }
}
