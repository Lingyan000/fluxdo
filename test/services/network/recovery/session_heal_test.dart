import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/recovery/recovery_coordinator.dart';
import 'package:fluxdo/services/network/recovery/recovery_policy.dart';
import 'package:fluxdo/services/network/recovery/session_heal_policy.dart';

/// 会话自愈的行为契约(自 SelfHealingInterceptor 迁移至恢复层后重建)。
///
/// 两条历史事故驱动的语义必须保住:
///
/// 1. **子域隔离**:CDK/LDC 等业务子域的 401 是各自 OAuth 授权过期,重试
///    主站 session 修复没有意义,还会把一次过期放大成多次请求。
///
/// 2. **jar 快照时序**(M0 修过的坑):服务端拒绝时常带 `Set-Cookie` 清 `_t`。
///    自愈判定"jar 里还有没有有效 _t"必须发生在这条删除指令**落库之前**,
///    否则会误判"真登出"而跳过自愈——这正是注册顺序错误时发生的事。
void main() {
  group('子域隔离', () {
    test('CDK 子域 401 不触发主站会话自愈', () async {
      final policy = SessionSelfHealPolicy(
        readSessionToken: () async =>
            CanonicalCookie(name: '_t', value: 'valid'),
      );
      final outcome = _failure(
        401,
        url: 'https://cdk.linux.do/api/v1/oauth/user-info',
      );

      expect(policy.canHandle(outcome), isFalse);
    });

    test('主站 401 才认领', () {
      final policy = SessionSelfHealPolicy(
        readSessionToken: () async =>
            CanonicalCookie(name: '_t', value: 'valid'),
      );
      expect(
        policy.canHandle(_failure(401, url: 'https://linux.do/latest.json')),
        isTrue,
      );
    });
  });

  group('自愈的必要条件', () {
    test('真登出标识(not_logged_in)不自愈', () {
      final policy = SessionSelfHealPolicy(
        readSessionToken: () async =>
            CanonicalCookie(name: '_t', value: 'valid'),
      );
      final outcome = _failure(
        401,
        body: {'error_type': 'not_logged_in'},
      );
      expect(policy.canHandle(outcome), isFalse);
    });

    test('jar 中已无有效 _t → 判定为真登出,决策为不干预', () async {
      final policy = SessionSelfHealPolicy(readSessionToken: () async => null);
      final decision = await policy.decide(_failure(401));
      expect(decision, isA<RecoveryComplete>());
    });

    test('_t 已过期同样视为真登出', () async {
      final policy = SessionSelfHealPolicy(
        readSessionToken: () async => CanonicalCookie(
          name: '_t',
          value: 'stale',
          expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );
      final decision = await policy.decide(_failure(401));
      expect(decision, isA<RecoveryComplete>());
    });

    test('jar 有效 → 产出 sweep 恢复动作', () async {
      final policy = SessionSelfHealPolicy(
        readSessionToken: () async =>
            CanonicalCookie(name: '_t', value: 'valid'),
      );
      final decision = await policy.decide(_failure(401));

      expect(decision, isA<RecoveryRecoverThenRetry>());
      expect(
        (decision as RecoveryRecoverThenRetry).action.name,
        'session-sweep',
      );
    });

    test('多次失败后升级为 Nuclear Reset', () async {
      final policy = SessionSelfHealPolicy(
        readSessionToken: () async =>
            CanonicalCookie(name: '_t', value: 'valid'),
      );
      final decision = await policy.decide(
        AttemptOutcome.failure(error: _dioError(401), attemptIndex: 2),
      );

      expect(
        (decision as RecoveryRecoverThenRetry).action.name,
        'session-nuclear-reset',
      );
    });
  });

  group('discourse-logged-out 弱信号(2xx 也要能捕获)', () {
    test('200 带该头时策略仍认领 —— 这类结果不走错误链', () {
      final policy = SessionSelfHealPolicy(
        readSessionToken: () async =>
            CanonicalCookie(name: '_t', value: 'valid'),
      );
      final options = RequestOptions(
        path: '/latest.json',
        baseUrl: 'https://linux.do',
      );
      final outcome = AttemptOutcome.success(
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          headers: Headers.fromMap({'discourse-logged-out': ['1']}),
          data: const {},
        ),
        attemptIndex: 0,
      );

      expect(policy.canHandle(outcome), isTrue);
    });
  });

  group('jar 快照时序(M0 回归护栏)', () {
    test('401 携带清除 _t 的 Set-Cookie 时,自愈仍读到有效快照并重放', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/latest.json');
      await jar.saveFromResponse(uri, [Cookie('_t', 'valid')..path = '/']);

      var tokenReadsWhileValid = 0;
      Future<CanonicalCookie?> readToken() async {
        final cookies = await jar.loadForRequest(uri);
        for (final cookie in cookies) {
          if (cookie.name == '_t' && cookie.value.isNotEmpty) {
            tokenReadsWhileValid++;
            return CanonicalCookie(name: cookie.name, value: cookie.value);
          }
        }
        return null;
      }

      final adapter = _Expiring401ThenOkAdapter();
      final dio = Dio(
        BaseOptions(
          baseUrl: 'https://linux.do',
          validateStatus: (status) => status != null && status < 400,
        ),
      )..httpClientAdapter = adapter;

      // 顺序即语义:恢复层必须先于 AppCookieManager 看到响应,
      // 才能在"清 _t"的 Set-Cookie 落库前读到有效快照。
      dio.interceptors.add(
        RecoveryCoordinator(
          dio: dio,
          policies: [
            SessionSelfHealPolicy(
              readSessionToken: readToken,
              sentinel: null,
            ),
          ],
          budgetFactory: () => AttemptBudget(maxAttempts: 2),
        ),
      );
      dio.interceptors.add(AppCookieManager(jar));

      final response = await dio.get<dynamic>('/latest.json');

      expect(response.statusCode, 200);
      expect(adapter.fetchCount, 2);
      expect(
        tokenReadsWhileValid,
        greaterThan(0),
        reason: '自愈判定必须读到"仍有有效 _t"的快照',
      );
    });
  });
}

// --- 脚手架 ---

AttemptOutcome _failure(
  int status, {
  String url = 'https://linux.do/latest.json',
  Object? body,
}) => AttemptOutcome.failure(
  error: _dioError(status, url: url, body: body),
  attemptIndex: 0,
);

DioException _dioError(
  int status, {
  String url = 'https://linux.do/latest.json',
  Object? body,
}) {
  final uri = Uri.parse(url);
  final options = RequestOptions(
    path: uri.path,
    baseUrl: '${uri.scheme}://${uri.host}',
    method: 'GET',
  );
  return DioException.badResponse(
    statusCode: status,
    requestOptions: options,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      headers: Headers.fromMap(const {}),
      data: body,
    ),
  );
}

/// 首个请求 401 + 清除 _t 的 Set-Cookie;之后 200。
class _Expiring401ThenOkAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    if (fetchCount == 1) {
      return ResponseBody.fromString(
        '{"error":"unauthorized"}',
        401,
        headers: {
          Headers.contentTypeHeader: const ['application/json'],
          HttpHeaders.setCookieHeader: const [
            '_t=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
          ],
        },
      );
    }
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
