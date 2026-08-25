import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../flux_request_spec.dart';
import 'recovery_policy.dart';

/// 恢复层的**唯一重放引擎**。
///
/// 此前项目里有六个各自 `dio.fetch()` 重灌全链的重放入口(自愈、Cronet
/// 降级、限流重试、重定向、CF 验证 ×2),每个都要自己操心清 Cookie 头、
/// 打防环标记、绕过调度器——漏一个就是死循环。这里把重放收敛成一处:
///
/// - 策略只产出 [RecoveryDecision],不执行重放;
/// - 重放前置工作(清 Cookie 头、递增尝试计数)统一在 [_nextAttempt];
/// - 任何策略都绕不过 [AttemptBudget],防环由结构保证。
///
/// 以 Dio 拦截器形式接入:它必须是**错误链上最后一个**恢复者,前面的
/// 拦截器(CF 验证、自愈)迁入策略后即可逐个撤下(设计文档 M4/M5)。
class RecoveryCoordinator extends Interceptor {
  RecoveryCoordinator({
    required this.dio,
    required List<RecoveryPolicy> policies,
    AttemptBudget Function()? budgetFactory,
  }) : _policies = policies,
       _budgetFactory = budgetFactory ?? AttemptBudget.new;

  /// 用于重放的 Dio(通常是本拦截器所在的实例)。
  final Dio dio;

  final List<RecoveryPolicy> _policies;
  final AttemptBudget Function() _budgetFactory;

  /// 标记请求已由本协调器接管,防止重放请求再次进入恢复流程
  /// (重放走 dio.fetch 会重跑整条拦截器链)。
  static const String _managedKey = '_recoveryManaged';

  /// 请求体是否可以重放。
  ///
  /// dio 的 [FormData] 是**一次性**的:`finalize()` 把字段与文件提交成流,
  /// 二次使用直接抛 `StateError('The FormData has already been finalized')`。
  /// 上传就是这个形态 —— 若恢复层去重放它,一个本可恢复的 429 会变成硬失败。
  ///
  /// 这类请求的重试必须由调用方做(每轮重建 FormData),`_uploads.dart` 的
  /// 重试循环正是为此存在,不是历史遗留。
  ///
  /// 流式请求体同理:Stream 消费过就没法再读。
  static bool _canReplayBody(RequestOptions options) {
    final data = options.data;
    if (data is FormData) return false;
    if (data is Stream) return false;
    return true;
  }

  /// 成功响应也可能需要恢复。
  ///
  /// 典型场景:服务端返回 2xx 但带 `discourse-logged-out` 头(会话已失效的
  /// 弱信号)。这类结果不进错误链,若只挂 onError 就会漏掉。
  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    if (response.requestOptions.extra[_managedKey] == true ||
        response.requestOptions.spec.recoveryDisabled ||
        !_canReplayBody(response.requestOptions)) {
      handler.next(response);
      return;
    }

    final outcome = AttemptOutcome.success(
      response: response,
      attemptIndex: 0,
    );
    if (_firstMatch(outcome) == null) {
      handler.next(response);
      return;
    }

    final result = await _runLoop(outcome);
    if (result.isSuccess) {
      handler.resolve(result.response!);
    } else {
      handler.reject(result.error!);
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // 已在恢复循环中的请求:直接透传,由外层循环处理
    if (err.requestOptions.extra[_managedKey] == true) {
      handler.next(err);
      return;
    }

    // 调用方声明不需要恢复(长轮询/后台 isolate/页面数据自己降级)
    if (err.requestOptions.spec.recoveryDisabled) {
      handler.next(err);
      return;
    }

    // 请求体不可重放(FormData/Stream):重放会抛 StateError,把可恢复的
    // 失败变成硬失败。这类请求的重试归调用方(每轮重建请求体)。
    if (!_canReplayBody(err.requestOptions)) {
      handler.next(err);
      return;
    }

    final result = await _runLoop(
      AttemptOutcome.failure(error: err, attemptIndex: 0),
    );
    if (result.isSuccess) {
      handler.resolve(result.response!);
    } else {
      handler.next(result.error!);
    }
  }

  /// 恢复主循环:策略决策 → 记账 → 重放,直到成功或放弃。
  ///
  /// 全项目唯一的重放点。返回最终结果(成功响应或最后一次失败)。
  Future<AttemptOutcome> _runLoop(AttemptOutcome initial) async {
    var outcome = initial;
    final budget = _budgetFactory();

    while (true) {
      final policy = _firstMatch(outcome);
      if (policy == null) return outcome;

      final decision = await policy.decide(outcome);
      final uri = _uriOf(outcome);

      switch (decision) {
        case RecoveryComplete():
          return outcome;

        case RecoveryFail(:final error):
          return AttemptOutcome.failure(
            error: error,
            attemptIndex: outcome.attemptIndex,
          );

        case RecoveryRetry() || RecoveryRecoverThenRetry():
          if (!budget.tryConsume(policy.name)) {
            debugPrint(
              '[Recovery] 预算耗尽 policy=${policy.name} '
              'attempts=${budget.attemptsUsed}/${budget.maxAttempts} $uri',
            );
            return outcome;
          }

          if (decision is RecoveryRecoverThenRetry) {
            final ok = await decision.action.run();
            if (!ok) {
              debugPrint(
                '[Recovery] 恢复动作失败 action=${decision.action.name} '
                'policy=${policy.name} $uri',
              );
              return outcome;
            }
          }

          final delay = switch (decision) {
            RecoveryRetry(:final delay) => delay,
            RecoveryRecoverThenRetry(:final delay) => delay,
            _ => Duration.zero,
          };
          if (delay > Duration.zero) {
            await Future<void>.delayed(delay);
          }

          debugPrint(
            '[Recovery] 重放 policy=${policy.name} '
            'attempt=${budget.attemptsUsed}/${budget.maxAttempts} $uri',
          );
          outcome = await _replay(outcome, budget.attemptsUsed - 1);
          if (outcome.isSuccess) return outcome;
      }
    }
  }

  static Uri _uriOf(AttemptOutcome outcome) =>
      (outcome.error?.requestOptions ?? outcome.response!.requestOptions).uri;

  RecoveryPolicy? _firstMatch(AttemptOutcome outcome) {
    for (final policy in _policies) {
      if (policy.canHandle(outcome)) return policy;
    }
    return null;
  }

  /// 执行一次重放。所有重放前置工作集中在此,不由策略各自操心。
  Future<AttemptOutcome> _replay(
    AttemptOutcome previous,
    int attemptIndex,
  ) async {
    final previousOptions =
        previous.error?.requestOptions ?? previous.response!.requestOptions;
    final options = _nextAttempt(previousOptions);
    try {
      final response = await dio.fetch<dynamic>(options);
      return AttemptOutcome.success(
        response: response,
        attemptIndex: attemptIndex,
      );
    } on DioException catch (e) {
      return AttemptOutcome.failure(error: e, attemptIndex: attemptIndex);
    }
  }

  /// 为下一次尝试重建请求选项。
  ///
  /// 关键点:清掉残留的 Cookie 头。重放走 dio.fetch 会重跑 AppCookieManager,
  /// 但若旧头还在,某些路径下会继续发送过期值(自愈/CF 重放都曾各自处理
  /// 这件事,现在只此一处)。
  RequestOptions _nextAttempt(RequestOptions previous) {
    final extra = Map<String, dynamic>.from(previous.extra)
      ..[_managedKey] = true;
    final headers = Map<String, dynamic>.from(previous.headers)
      ..remove('cookie')
      ..remove('Cookie');

    return previous.copyWith(headers: headers, extra: extra);
  }
}
