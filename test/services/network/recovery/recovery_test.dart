import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/recovery/policies.dart';
import 'package:fluxdo/services/network/recovery/recovery_coordinator.dart';
import 'package:fluxdo/services/network/recovery/recovery_policy.dart';

/// 恢复层的行为契约。
///
/// 策略是纯决策函数,Coordinator 是唯一重放引擎 —— 这个结构的价值就在于
/// 可以用脚本化的失败序列穷举验证,而此前长在拦截器里的重试逻辑几乎不可测。
void main() {
  group('AttemptBudget', () {
    test('总尝试数不超过上限,无论哪个策略消耗', () {
      final budget = AttemptBudget(maxAttempts: 3);
      // 首次尝试已计入
      expect(budget.tryConsume('a'), isTrue); // 第 2 次
      expect(budget.tryConsume('b'), isTrue); // 第 3 次
      expect(budget.tryConsume('a'), isFalse); // 超限
      expect(budget.attemptsUsed, 3);
    });

    test('单策略上限独立生效', () {
      final budget = AttemptBudget(
        maxAttempts: 10,
        perPolicyCap: {'cf': 1},
      );
      expect(budget.tryConsume('cf'), isTrue);
      expect(budget.tryConsume('cf'), isFalse, reason: 'cf 已达单策略上限');
      expect(budget.tryConsume('other'), isTrue, reason: '其他策略不受影响');
    });
  });

  group('RateLimitPolicy', () {
    test('Retry-After 在可接受范围内 → 延迟重放', () async {
      const policy = RateLimitPolicy(maxWaitSeconds: 30);
      final outcome = _failure(429, headers: {'retry-after': ['5']});

      expect(policy.canHandle(outcome), isTrue);
      final decision = await policy.decide(outcome);
      expect(decision, isA<RecoveryRetry>());
      expect((decision as RecoveryRetry).delay, const Duration(seconds: 5));
    });

    test('等待过长 → 不重放,包装成 RateLimitException 且保留 response', () async {
      const policy = RateLimitPolicy(maxWaitSeconds: 30);
      final outcome = _failure(
        429,
        headers: {'retry-after': ['600']},
        body: {'errors': ['太快了']},
      );

      final decision = await policy.decide(outcome);
      expect(decision, isA<RecoveryFail>());
      final error = (decision as RecoveryFail).error;
      expect(error.error, isA<RateLimitException>());
      final rateLimit = error.error as RateLimitException;
      expect(rateLimit.retryAfterSeconds, 600);
      // 结果保真:业务层要能读服务端文案
      expect(error.response?.statusCode, 429);
      expect(rateLimit.response?.statusCode, 429);
    });

    test('中文限流文案里的秒数同样被识别', () async {
      const policy = RateLimitPolicy(maxWaitSeconds: 30);
      final outcome = _failure(429, body: {'errors': ['请等待 8 秒后再试']});

      final decision = await policy.decide(outcome);
      expect((decision as RecoveryRetry).delay, const Duration(seconds: 8));
    });

    test('挑战型 429 不归本策略(交给 CF 盾处理)', () {
      final policy = RateLimitPolicy(isChallengeResponse: (_) => true);
      expect(policy.canHandle(_failure(429)), isFalse);
    });

    test('非 429 不处理', () {
      const policy = RateLimitPolicy();
      expect(policy.canHandle(_failure(503)), isFalse);
      expect(policy.canHandle(_failure(404)), isFalse);
    });
  });

  group('TransientRetryPolicy', () {
    test('幂等方法的 5xx → 指数退避重放', () async {
      const policy = TransientRetryPolicy();
      final outcome = _failure(503, method: 'GET');

      expect(policy.canHandle(outcome), isTrue);
      final decision = await policy.decide(outcome);
      expect((decision as RecoveryRetry).delay, const Duration(seconds: 1));
    });

    test('退避时长随尝试序号递增', () async {
      const policy = TransientRetryPolicy();
      for (final (index, expected) in [
        (0, 1),
        (1, 2),
        (2, 4),
        (5, 4), // 超出列表后钳制在最后一档
      ]) {
        final decision = await policy.decide(
          AttemptOutcome.failure(
            error: _dioError(503, method: 'GET'),
            attemptIndex: index,
          ),
        );
        expect(
          (decision as RecoveryRetry).delay,
          Duration(seconds: expected),
          reason: 'attemptIndex=$index',
        );
      }
    });

    test('非幂等方法的 5xx 不重放(避免重复发帖)', () {
      const policy = TransientRetryPolicy();
      expect(policy.canHandle(_failure(503, method: 'POST')), isFalse);
      expect(policy.canHandle(_failure(502, method: 'PUT')), isFalse);
      expect(policy.canHandle(_failure(504, method: 'DELETE')), isFalse);
    });

    test('连接类错误按瞬态处理,cancel/证书错误不重放', () {
      const policy = TransientRetryPolicy();
      for (final type in [
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ]) {
        expect(
          policy.canHandle(_networkFailure(type)),
          isTrue,
          reason: '$type 应视为瞬态',
        );
      }
      expect(policy.canHandle(_networkFailure(DioExceptionType.cancel)), isFalse);
      expect(
        policy.canHandle(_networkFailure(DioExceptionType.badCertificate)),
        isFalse,
      );
    });

    test('4xx 不重放', () {
      const policy = TransientRetryPolicy();
      expect(policy.canHandle(_failure(404, method: 'GET')), isFalse);
      expect(policy.canHandle(_failure(403, method: 'GET')), isFalse);
    });
  });

  group('RecoveryCoordinator 端到端', () {
    test('503 后恢复成功:调用方只看到最终的 200', () async {
      final adapter = _ScriptedAdapter([
        _Reply(503, '{"error":"unavailable"}'),
        _Reply(200, '{"ok":true}'),
      ]);
      final dio = _buildDio(adapter, [
        const TransientRetryPolicy(delays: [Duration.zero]),
      ]);

      final response = await dio.get<dynamic>('/latest.json');

      expect(response.statusCode, 200);
      expect(adapter.callCount, 2);
    });

    test('持续失败:预算耗尽后抛出原始错误', () async {
      final adapter = _ScriptedAdapter([_Reply(503, '{"error":"unavailable"}')]);
      final dio = _buildDio(
        adapter,
        [const TransientRetryPolicy(delays: [Duration.zero])],
        budget: () => AttemptBudget(maxAttempts: 3),
      );

      DioException? caught;
      try {
        await dio.get<dynamic>('/latest.json');
      } on DioException catch (e) {
        caught = e;
      }

      // 共 3 次尝试(1 原始 + 2 恢复),之后放弃
      expect(adapter.callCount, 3);
      expect(caught!.response?.statusCode, 503);
    });

    test('无策略认领的失败原样透传,不产生额外请求', () async {
      final adapter = _ScriptedAdapter([_Reply(404, '{"error":"not found"}')]);
      final dio = _buildDio(adapter, [const TransientRetryPolicy()]);

      DioException? caught;
      try {
        await dio.get<dynamic>('/missing.json');
      } on DioException catch (e) {
        caught = e;
      }

      expect(adapter.callCount, 1);
      expect(caught!.response?.statusCode, 404);
    });

    test('noRecovery 的请求完全不进恢复流程', () async {
      final adapter = _ScriptedAdapter([_Reply(503, '{"error":"unavailable"}')]);
      final dio = _buildDio(adapter, [
        const TransientRetryPolicy(delays: [Duration.zero]),
      ]);

      try {
        await dio.get<dynamic>(
          '/latest.json',
          options: Options(extra: const {'noRecovery': true}),
        );
      } on DioException catch (_) {}

      expect(adapter.callCount, 1);
    });

    test('静默请求默认不进恢复流程(长轮询要拿原始错误自行退避)', () async {
      final adapter = _ScriptedAdapter([_Reply(429, '{"errors":["rate limited"]}')]);
      final dio = _buildDio(adapter, [const RateLimitPolicy()]);

      try {
        await dio.post<dynamic>(
          '/message-bus/abc/poll',
          options: Options(extra: const {'isSilent': true}),
        );
      } on DioException catch (_) {}

      expect(adapter.callCount, 1);
    });

    test('策略顺序即归属:前面的策略放行后才轮到后面的', () async {
      final adapter = _ScriptedAdapter([
        _Reply(429, '{}', {'retry-after': ['0']}),
        _Reply(200, '{"ok":true}'),
      ]);
      // 挑战判定恒真 → RateLimitPolicy 放行;TransientRetry 不管 429
      final dio = _buildDio(adapter, [
        RateLimitPolicy(isChallengeResponse: (_) => true),
        const TransientRetryPolicy(delays: [Duration.zero]),
      ]);

      try {
        await dio.get<dynamic>('/latest.json');
      } on DioException catch (_) {}

      // 两个策略都没接手 → 不重放
      expect(adapter.callCount, 1);
    });
  });
}

// --- 测试脚手架 ---

AttemptOutcome _failure(
  int status, {
  String method = 'GET',
  Map<String, List<String>>? headers,
  Object? body,
}) => AttemptOutcome.failure(
  error: _dioError(status, method: method, headers: headers, body: body),
  attemptIndex: 0,
);

DioException _dioError(
  int status, {
  String method = 'GET',
  Map<String, List<String>>? headers,
  Object? body,
}) {
  final options = RequestOptions(path: '/x', method: method);
  return DioException.badResponse(
    statusCode: status,
    requestOptions: options,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      headers: Headers.fromMap(headers ?? const {}),
      data: body,
    ),
  );
}

AttemptOutcome _networkFailure(DioExceptionType type) => AttemptOutcome.failure(
  error: DioException(
    requestOptions: RequestOptions(path: '/x', method: 'GET'),
    type: type,
  ),
  attemptIndex: 0,
);

Dio _buildDio(
  _ScriptedAdapter adapter,
  List<RecoveryPolicy> policies, {
  AttemptBudget Function()? budget,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      validateStatus: (status) => status != null && status < 400,
    ),
  )..httpClientAdapter = adapter;
  dio.interceptors.add(
    RecoveryCoordinator(dio: dio, policies: policies, budgetFactory: budget),
  );
  return dio;
}

class _Reply {
  _Reply(this.statusCode, this.body, [this.headers = const {}]);

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._replies);

  final List<_Reply> _replies;
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final reply = _replies[callCount.clamp(0, _replies.length - 1)];
    callCount++;
    return ResponseBody.fromString(
      reply.body,
      reply.statusCode,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
        ...reply.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
