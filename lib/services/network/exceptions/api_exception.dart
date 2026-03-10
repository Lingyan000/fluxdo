/// 429 Rate Limit 异常（重试耗尽后抛出）
class RateLimitException implements Exception {
  final int? retryAfterSeconds;
  final String? message;

  RateLimitException([this.retryAfterSeconds, this.message]);

  @override
  String toString() => message ?? '请求过于频繁，请稍后再试';
}

/// 服务器错误异常（502/503/504 重试耗尽后抛出）
class ServerException implements Exception {
  final int statusCode;
  ServerException(this.statusCode);

  @override
  String toString() => '服务器暂时不可用 ($statusCode)';
}

/// 帖子进入审核队列异常
class PostEnqueuedException implements Exception {
  final int pendingCount;
  PostEnqueuedException({this.pendingCount = 0});

  @override
  String toString() => '你的帖子已提交，正在等待审核';
}

/// Cloudflare 验证异常
class CfChallengeException implements Exception {
  final bool userCancelled;
  final bool inCooldown;
  /// 原始错误（用于调试，保留验证/重试失败的实际原因）
  final Object? cause;
  CfChallengeException({this.userCancelled = false, this.inCooldown = false, this.cause});

  @override
  String toString() {
    if (inCooldown) return '请稍后再试';
    if (userCancelled) return '验证已取消';
    if (cause != null) return '安全验证失败: $cause';
    return '安全验证失败，请重试';
  }
}
