import 'package:flutter/foundation.dart';

import '../adapters/cronet_fallback_service.dart';
import 'recovery_action.dart';
import 'recovery_policy.dart';

/// 引擎降级动作:标记 Cronet 不可用。
///
/// 降级是进程级的一次性状态变更——_DynamicAdapter 会在下次请求时读到
/// `hasFallenBack` 并切换适配器,所以本动作只需触发状态、不需自己换引擎。
class EngineFallbackAction extends RecoveryAction {
  EngineFallbackAction(this.reason);

  final String reason;

  @override
  String get name => 'engine-fallback';

  @override
  Future<bool> perform() async {
    final service = CronetFallbackService.instance;
    if (service.hasFallenBack) {
      // 已经降级过:无需重复触发,但仍允许重放(新引擎可能就能通)
      return true;
    }
    await service.triggerFallback(reason);
    debugPrint('[Recovery] 引擎已降级,下次请求切换适配器');
    return true;
  }
}

/// 引擎级错误的降级策略。
///
/// 迁移自 CronetFallbackInterceptor。判定沿用
/// [CronetFallbackService.isCronetError](它已排除"关闭时序"类瞬态错误,
/// 避免把 adapter 切换过程中的正常报错误判成引擎故障)。
///
/// 降级只做一次:已降级后不再认领,让错误交给后面的策略或调用方——否则
/// Cronet 坏掉时每个请求都要走一遍降级流程。
class EngineFallbackPolicy implements RecoveryPolicy {
  const EngineFallbackPolicy();

  @override
  String get name => 'engine-fallback';

  @override
  bool canHandle(AttemptOutcome outcome) {
    if (outcome.isSuccess) return false;
    if (CronetFallbackService.instance.hasFallenBack) return false;
    return CronetFallbackService.isCronetError(outcome.error!.error);
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    return RecoveryDecision.recoverThenRetry(
      EngineFallbackAction(outcome.error!.error.toString()),
    );
  }
}
