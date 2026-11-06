import '../adapters/core_fallback_service.dart';
import '../../network_logger.dart';
import 'recovery_action.dart';
import 'recovery_policy.dart';

/// 降级动作：标记网络核心不可用。
///
/// 降级是进程级的一次性状态变更——适配器会在下次请求时读到
/// `hasFallenBack` 并切到应急路径，所以本动作只需触发状态、不必自己换引擎。
class EngineFallbackAction extends RecoveryAction {
  EngineFallbackAction(this.reason);

  final String reason;

  @override
  String get name => 'engine-fallback';

  @override
  Future<bool> perform() async {
    final service = CoreFallbackService.instance;
    if (service.hasFallenBack) {
      // 已经降级过：不重复触发，但仍允许重放（换条路可能就通了）
      return true;
    }
    await service.triggerFallback(reason);
    NetworkLogger.log('[Recovery] 网络核心已降级，下次请求切换到应急路径', level: 'warning');
    return true;
  }
}

/// 核心不可用时的降级策略。
///
/// 判定沿用 [CoreFallbackService.isCoreUnavailable]：只认「核心起不来」这类
/// 结构性故障，单次请求的连接错误与超时属于正常网络问题，交给后面的重试策略。
///
/// 降级只做一次：已降级后不再认领，否则核心坏掉时每个请求都要走一遍降级流程。
class EngineFallbackPolicy implements RecoveryPolicy {
  const EngineFallbackPolicy();

  @override
  String get name => 'engine-fallback';

  @override
  bool canHandle(AttemptOutcome outcome) {
    if (outcome.isSuccess) return false;
    if (CoreFallbackService.instance.hasFallenBack) return false;
    return CoreFallbackService.isCoreUnavailable(outcome.error!.error);
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    return RecoveryDecision.recoverThenRetry(
      EngineFallbackAction(outcome.error!.error.toString()),
    );
  }
}
