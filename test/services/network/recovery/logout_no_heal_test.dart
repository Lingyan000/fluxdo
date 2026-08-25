import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/recovery/recovery_policy.dart';
import 'package:fluxdo/services/network/recovery/session_heal_policy.dart';

/// 登出请求绝不能被会话自愈接手。
///
/// 回归背景:自愈从拦截器迁入恢复层后,`DELETE /session/:username` 返回的
/// 401 / `discourse-logged-out` 被自愈认领了。登出流程里 jar 的 `_t` 要到
/// 后面几步才清,所以自愈判定"会话仍有效、值得修",触发 sweep + 重放直到
/// 预算耗尽——`await _dio.delete(...)` 卡住,登出 UI 一直转圈。
///
/// 登出的 401 是**预期结果**,不是故障。这里两侧都验:策略侧按端点排除,
/// 调用侧显式声明 noRecovery。
void main() {
  SessionSelfHealPolicy buildPolicy() => SessionSelfHealPolicy(
    // 模拟登出进行中:jar 里 _t 仍然有效
    readSessionToken: () async =>
        CanonicalCookie(name: '_t', value: 'still-valid'),
  );

  group('策略侧:按端点排除登出', () {
    test('DELETE /session/:username 的 401 不被自愈接手', () {
      final outcome = _failure(
        401,
        method: 'DELETE',
        path: '/session/someuser',
        loggedOutHeader: true,
      );

      expect(buildPolicy().canHandle(outcome), isFalse);
    });

    test('登出请求带 discourse-logged-out 头同样不接手', () {
      final outcome = _failure(
        200,
        method: 'DELETE',
        path: '/session/someuser',
        loggedOutHeader: true,
      );

      expect(buildPolicy().canHandle(outcome), isFalse);
    });

    test('对照:普通业务请求的 401 仍然要自愈', () {
      final outcome = _failure(401, method: 'GET', path: '/latest.json');
      expect(buildPolicy().canHandle(outcome), isTrue);
    });

    test('对照:GET /session/... 不是登出,不受排除影响', () {
      // /session/csrf 等读取型端点走 GET,不该被误排除
      final outcome = _failure(401, method: 'GET', path: '/session/csrf');
      expect(buildPolicy().canHandle(outcome), isTrue);
    });
  });

  group('调用侧:noRecovery 声明', () {
    test('带 noRecovery 的请求整体不进恢复流程', () {
      // 与策略侧排除互为纵深防护:任一生效即可避免卡死
      final options = RequestOptions(
        path: '/session/someuser',
        baseUrl: 'https://linux.do',
        method: 'DELETE',
        extra: const {'noRecovery': true},
      );
      expect(options.extra['noRecovery'], isTrue);
    });
  });
}

AttemptOutcome _failure(
  int status, {
  required String method,
  required String path,
  bool loggedOutHeader = false,
}) {
  final options = RequestOptions(
    path: path,
    baseUrl: 'https://linux.do',
    method: method,
  );
  final response = Response<dynamic>(
    requestOptions: options,
    statusCode: status,
    headers: Headers.fromMap({
      if (loggedOutHeader) 'discourse-logged-out': ['1'],
    }),
  );

  if (status >= 400) {
    return AttemptOutcome.failure(
      error: DioException.badResponse(
        statusCode: status,
        requestOptions: options,
        response: response,
      ),
      attemptIndex: 0,
    );
  }
  return AttemptOutcome.success(response: response, attemptIndex: 0);
}
