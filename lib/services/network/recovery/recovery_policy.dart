import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'recovery_action.dart';

/// 一次传输尝试的结果(成功响应或失败,附本次尝试的元数据)。
@immutable
class AttemptOutcome {
  const AttemptOutcome._({
    required this.attemptIndex,
    this.response,
    this.error,
  });

  factory AttemptOutcome.success({
    required Response<dynamic> response,
    required int attemptIndex,
  }) => AttemptOutcome._(response: response, attemptIndex: attemptIndex);

  factory AttemptOutcome.failure({
    required DioException error,
    required int attemptIndex,
  }) => AttemptOutcome._(error: error, attemptIndex: attemptIndex);

  /// 成功响应;失败时为 null。
  final Response<dynamic>? response;

  /// 失败异常;成功时为 null。
  final DioException? error;

  /// 本次是第几次尝试(0 = 首次)。
  final int attemptIndex;

  bool get isSuccess => error == null;

  /// 失败响应的状态码(网络层错误时为 null)。
  int? get statusCode => error?.response?.statusCode ?? response?.statusCode;
}

/// 恢复策略的**唯一输出形式**。
///
/// 策略只做决策,不执行重放——执行(计预算、延迟、重建请求)统一由
/// [RecoveryCoordinator] 负责。这样"重放"只有一处实现,防环也只有一个机制。
sealed class RecoveryDecision {
  const RecoveryDecision();

  /// 不干预:把原结果交给调用方。
  const factory RecoveryDecision.complete() = RecoveryComplete;

  /// 延迟 [delay] 后重放。
  const factory RecoveryDecision.retry({Duration delay}) = RecoveryRetry;

  /// 先执行全局恢复动作,成功后再重放;动作失败则终止。
  ///
  /// 用于"修复环境再重试"的场景:会话 sweep、引擎降级、CF 验证。
  /// 动作自带单飞语义,并发失败请求共享一次执行。
  const factory RecoveryDecision.recoverThenRetry(
    RecoveryAction action, {
    Duration delay,
  }) = RecoveryRecoverThenRetry;

  /// 用 [error] 替换原错误后终止(如把 429 包装成类型化异常)。
  const factory RecoveryDecision.fail(DioException error) = RecoveryFail;
}

final class RecoveryComplete extends RecoveryDecision {
  const RecoveryComplete();
}

final class RecoveryRetry extends RecoveryDecision {
  const RecoveryRetry({this.delay = Duration.zero});

  final Duration delay;
}

final class RecoveryRecoverThenRetry extends RecoveryDecision {
  const RecoveryRecoverThenRetry(this.action, {this.delay = Duration.zero});

  final RecoveryAction action;
  final Duration delay;
}

final class RecoveryFail extends RecoveryDecision {
  const RecoveryFail(this.error);

  final DioException error;
}

/// 一条恢复策略。
///
/// 策略按注册顺序排列,**首个 [canHandle] 返回 true 的独占决策权**——
/// "一个 429 归谁处理"由此从隐式让路变成显式排序。
abstract interface class RecoveryPolicy {
  /// 诊断名(进日志与预算账本)。
  String get name;

  /// 本策略是否处理这个失败结果。
  bool canHandle(AttemptOutcome outcome);

  /// 产出决策。不得在此执行重放或修改请求。
  Future<RecoveryDecision> decide(AttemptOutcome outcome);
}

/// 单个逻辑请求的尝试预算。
///
/// 替代此前散落的 6 套 `skip*` 防环标记:无论策略如何组合嵌套,一个逻辑
/// 请求的传输尝试总数不会超过 [maxAttempts]——防环从"每个重放点自觉打
/// 标记"变成结构上不可能。
class AttemptBudget {
  AttemptBudget({this.maxAttempts = 4, Map<String, int>? perPolicyCap})
    : perPolicyCap = perPolicyCap ?? const {};

  /// 总尝试数上限(含首次)。默认 4 = 1 次原始 + 3 次恢复。
  final int maxAttempts;

  /// 单策略触发次数上限。未列出的策略不单独限制。
  final Map<String, int> perPolicyCap;

  int _attempts = 1; // 首次尝试已消耗
  final Map<String, int> _policyUse = {};

  int get attemptsUsed => _attempts;

  /// 记账并判断是否允许再来一次。
  bool tryConsume(String policyName) {
    if (_attempts >= maxAttempts) return false;
    final cap = perPolicyCap[policyName];
    final used = _policyUse[policyName] ?? 0;
    if (cap != null && used >= cap) return false;
    _attempts++;
    _policyUse[policyName] = used + 1;
    return true;
  }

  /// 某策略已触发次数(诊断用)。
  int usageOf(String policyName) => _policyUse[policyName] ?? 0;
}
