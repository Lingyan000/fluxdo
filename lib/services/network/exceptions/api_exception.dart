import '../../../l10n/s.dart';
import '../../../models/pending_post.dart';

/// 429 Rate Limit 异常（重试耗尽后抛出）
class RateLimitException implements Exception {
  final int? retryAfterSeconds;
  final String? message;

  RateLimitException([this.retryAfterSeconds, this.message]);

  @override
  String toString() => message ?? S.current.error_rateLimitedRetryLater;
}

/// 服务器错误异常（502/503/504 重试耗尽后抛出）
class ServerException implements Exception {
  final int statusCode;
  ServerException(this.statusCode);

  @override
  String toString() => '${S.current.error_serviceUnavailableRetry} ($statusCode)';
}

/// 帖子进入审核队列异常
class PostEnqueuedException implements Exception {
  final int pendingCount;

  /// enqueued 响应里的 `pending_post`(reviewable 摘要),
  /// 用于即时把待审内容挂进主题页底部待审块;极老版本服务端可能缺失
  final PendingPost? pendingPost;

  PostEnqueuedException({this.pendingCount = 0, this.pendingPost});

  @override
  String toString() => S.current.network_postPendingReview;
}

/// Cloudflare 验证异常
class CfChallengeException implements Exception {
  final bool userCancelled;
  final bool inCooldown;
  /// 用户在设置里关闭了"自动 CF 验证"，拦截器命中 CF 盾时静默 reject
  final bool autoVerifyDisabled;
  /// CF 验证进行中，业务请求被 RequestScheduler 主动 reject
  /// （上层应静默处理，不要再叠加 toast，避免和 CF 验证弹窗冲突）
  final bool silentBlockedDuringChallenge;
  /// 原始错误（用于调试，保留验证/重试失败的实际原因）
  final Object? cause;
  CfChallengeException({
    this.userCancelled = false,
    this.inCooldown = false,
    this.autoVerifyDisabled = false,
    this.silentBlockedDuringChallenge = false,
    this.cause,
  });

  @override
  String toString() {
    if (silentBlockedDuringChallenge) return S.current.cf_operationBlockedByChallenge;
    if (inCooldown) return S.current.cf_cooldown;
    if (userCancelled) return S.current.cf_userCancelled;
    if (autoVerifyDisabled) return S.current.cf_autoVerifyDisabled;
    if (cause != null) return S.current.cf_failedWithCause('$cause');
    return S.current.cf_failedRetry;
  }
}
