import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/webview_session_cookie_refresh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('账号切换摘除用户名后仍可用目标用户名校验已恢复的会话', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final cookieJar = CookieJarService();
    await cookieJar.initialize();
    await cookieJar.setCookie(
      '_t',
      'target-session-token',
      httpOnly: true,
      trusted: true,
    );
    WebViewSessionCookieRefreshService.instance.markSynced(
      reason: 'account-switch-auth-test',
      tToken: 'target-session-token',
    );

    final service = DiscourseService();
    final adapter = _SessionCurrentAdapter(username: 'target-user');
    service.dio.httpClientAdapter = adapter;
    final generation = AuthSession().advance();

    // detachSessionLocally 已删掉持久化用户名；恢复事务在服务端校验通过前
    // 不能提前提交它。expectedUsername 就是这段窗口内唯一可信的身份提示。
    expect(await service.getCurrentUsername(), isNull);
    final loggedIn = await service.isLoggedIn(
      requestGeneration: generation,
      logoutOnInvalid: false,
      expectedUsername: 'target-user',
    );

    expect(loggedIn, isTrue);
    expect(adapter.sentCookie, contains('_t=target-session-token'));
    expect(await cookieJar.getTToken(), 'target-session-token');
    // 校验只做预提交验证，用户名仍由 finalizeNativeLoginSuccess 提交。
    expect(await service.getCurrentUsername(), isNull);
  });
}

class _SessionCurrentAdapter implements HttpClientAdapter {
  _SessionCurrentAdapter({required this.username});

  final String username;
  String? sentCookie;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.uri.path, '/session/current.json');
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == 'cookie') {
        sentCookie = entry.value.toString();
        break;
      }
    }
    return ResponseBody.fromString(
      jsonEncode({
        'current_user': {'username': username},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
