import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as wv;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/exceptions/oauth_exception.dart';
import 'package:fluxdo/services/oauth_session_client.dart';

import '../support/cf_test_platform.dart';

class _BusinessCookies extends CfTestCookieManager {
  @override
  Future<bool> setCookie({
    required wv.WebUri url,
    required String name,
    required String value,
    String path = '/',
    String? domain,
    int? expiresDate,
    int? maxAge,
    bool? isSecure,
    bool? isHttpOnly,
    wv.HTTPCookieSameSitePolicy? sameSite,
    wv.PlatformInAppWebViewController? iosBelow11WebViewController,
    wv.PlatformInAppWebViewController? webViewController,
  }) async {
    values.removeWhere((cookie) => cookie.name == name);
    values.add(
      wv.Cookie(
        name: name,
        value: value,
        path: path,
        domain: domain,
        expiresDate:
            expiresDate ??
            (maxAge == null
                ? null
                : DateTime.now()
                      .add(Duration(seconds: maxAge))
                      .millisecondsSinceEpoch),
        isSecure: isSecure,
        isHttpOnly: isHttpOnly,
      ),
    );
    return true;
  }
}

class _BusinessPlatform extends CfTestPlatform {
  final _businessCookies = _BusinessCookies();
  @override
  _BusinessCookies get cookies => _businessCookies;
}

class _SessionAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  Object body = {
    'data': {'username': 'alice'},
  };
  final headers = <String, List<String>>{};
  Completer<void>? gate;
  Completer<void>? entered;

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    entered?.complete();
    await gate?.future;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _BusinessPlatform();
  late io.Directory directory;
  late EnhancedPersistCookieJar jar;
  setUpAll(() async {
    directory = await io.Directory.systemTemp.createTemp('balance-session-');
    await platform.initialize(cookieDirectory: directory.path);
    jar = CookieJarService().cookieJar as EnhancedPersistCookieJar;
  });
  setUp(platform.reset);
  tearDown(platform.reset);
  tearDownAll(() => directory.delete(recursive: true));

  for (final (name, origin, cookieName) in [
    ('LDC', 'https://credit.linux.do', 'linux_do_credit_session_id'),
    ('CDK', 'https://cdk.linux.do', 'linux_do_cdk_session_id'),
  ]) {
    group(name, () {
      late _SessionAdapter adapter;
      late OAuthSessionClient client;
      final uri = Uri.parse('$origin/api/v1/oauth/user-info');

      setUp(() {
        adapter = _SessionAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        dio.interceptors.add(AppCookieManager(jar));
        client = OAuthSessionClient(
          dio: dio,
          baseUrl: origin,
          serviceName: name,
          state: OAuthSessionState(),
        );
      });
      tearDown(() => client.cancel());

      Future<CanonicalCookie> cookie() async =>
          (await jar.loadCanonicalForRequest(uri))
              .singleWhere((c) => c.name == cookieName);
      Future<void> seed() => jar.saveFromSetCookieHeaders(uri, [
        '$cookieName=existing; Path=/; Max-Age=120; Secure; HttpOnly',
      ], trusted: true);
      void onlyUserInfoRequests() {
        expect(adapter.requests, isNotEmpty);
        expect(
          adapter.requests.every((r) => r.uri == uri && r.method == 'GET'),
          isTrue,
        );
      }

      test('正常读取只请求业务接口', () async {
        expect(
          (await client.getUserInfo(expectedUsername: 'alice'))['username'],
          'alice',
        );
        expect(adapter.requests, hasLength(1));
        onlyUserInfoRequests();
      });

      test('Cookie 即将到期也不触发后台 OAuth 授权', () async {
        await seed();
        await client.getUserInfo();
        expect(
          adapter.requests.single.headers[io.HttpHeaders.cookieHeader],
          '$cookieName=existing',
        );
        onlyUserInfoRequests();
      });

      test('服务端轮换 Cookie 后持久化新值并用于下一次请求', () async {
        await seed();
        adapter.headers[io.HttpHeaders.setCookieHeader] = [
          '$cookieName=rotated; Path=/; Max-Age=604800; Secure; HttpOnly',
        ];
        await client.getUserInfo();
        expect((await cookie()).value, 'rotated');
        adapter.headers.clear();
        await client.getUserInfo();
        expect(
          adapter.requests.last.headers[io.HttpHeaders.cookieHeader],
          '$cookieName=rotated',
        );
        final persisted = EnhancedPersistCookieJar(
          store: FileCookieStore('${directory.path}/.cookies'),
        );
        expect(
          (await persisted.loadCanonicalForRequest(uri))
              .singleWhere((c) => c.name == cookieName)
              .value,
          'rotated',
        );
        expect(
          platform.cookies.values
              .singleWhere((c) => c.name == cookieName)
              .value,
          'rotated',
        );
        onlyUserInfoRequests();
      });

      test('Cookie 值未改变时仍接受服务端更新的有效期', () async {
        await seed();
        final before = await cookie();
        adapter.headers[io.HttpHeaders.setCookieHeader] = [
          '$cookieName=existing; Path=/; Max-Age=604800; Secure; HttpOnly',
        ];
        await client.getUserInfo();
        final after = await cookie();
        expect(after.value, before.value);
        expect(after.maxAge, 604800);
        expect(
          after.creationTime
              .add(Duration(seconds: after.maxAge!))
              .isAfter(
                before.creationTime.add(Duration(seconds: before.maxAge!)),
              ),
          isTrue,
        );
        expect(
          platform.cookies.values
              .singleWhere((c) => c.name == cookieName)
              .expiresDate,
          greaterThan(
            DateTime.now().add(const Duration(days: 6)).millisecondsSinceEpoch,
          ),
        );
      });

      test('响应未签发 Cookie 时不会在本地延长有效期', () async {
        await seed();
        final before = await cookie();
        await client.getUserInfo();
        await client.getUserInfo();
        final after = await cookie();
        expect(after.creationTime, before.creationTime);
        expect(after.expiresAt, before.expiresAt);
        expect(after.maxAge, before.maxAge);
        onlyUserInfoRequests();
      });

      test('业务 401 直接报告过期，不发起自动重新授权', () async {
        adapter.status = 401;
        await expectLater(
          client.getUserInfo(),
          throwsA(isA<OAuthExpiredException>()),
        );
        expect(adapter.requests, hasLength(1));
        onlyUserInfoRequests();
      });

      for (final status in [401, 403, 429]) {
        test('CF 挑战 $status 不误报为授权过期', () async {
          adapter.status = status;
          adapter.headers['cf-mitigated'] = ['challenge'];
          await expectLater(
            client.getUserInfo(),
            throwsA(predicate<Object>(OAuthErrorPolicy.isCfChallenge)),
          );
          onlyUserInfoRequests();
        });
      }

      test('普通 403 保留权限错误，不误报为授权过期', () async {
        adapter.status = 403;
        await expectLater(
          client.getUserInfo(),
          throwsA(
            isA<DioException>()
                .having((e) => e.response?.statusCode, 'status', 403)
                .having(OAuthErrorPolicy.isCfChallenge, 'CF', isFalse),
          ),
        );
        onlyUserInfoRequests();
      });

      test('服务端错误不触发重新授权', () async {
        adapter.status = 500;
        await expectLater(client.getUserInfo(), throwsA(isA<DioException>()));
        onlyUserInfoRequests();
      });

      test('重定向不被当作成功用户信息或自动跳转授权页', () async {
        adapter.status = 302;
        adapter.headers['location'] = [
          'https://connect.linux.do/oauth2/authorize',
        ];
        await expectLater(client.getUserInfo(), throwsA(isA<DioException>()));
        onlyUserInfoRequests();
      });

      test('无效响应不被当作登录过期', () async {
        adapter.body = {'data': null};
        await expectLater(
          client.getUserInfo(),
          throwsA(isA<FormatException>()),
        );
      });

      test('其他账号的业务会话不能覆盖当前账号', () async {
        await expectLater(
          client.getUserInfo(expectedUsername: 'bob'),
          throwsA(isA<OAuthExpiredException>()),
        );
        onlyUserInfoRequests();
      });

      test('取消后旧请求失效，新的用户信息请求仍可正常执行', () async {
        adapter.gate = Completer<void>();
        adapter.entered = Completer<void>();
        final old = client.getUserInfo();
        final rejected = expectLater(
          old,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await adapter.entered!.future;
        client.cancel();
        adapter.gate!.complete();
        await rejected;
        adapter.gate = null;
        adapter.entered = null;
        expect((await client.getUserInfo())['username'], 'alice');
      });

      test('主站切换账号后丢弃旧账号的业务响应', () async {
        adapter.gate = Completer<void>();
        adapter.entered = Completer<void>();
        final old = client.getUserInfo();
        final rejected = expectLater(
          old,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await adapter.entered!.future;
        AuthSession().advance();
        adapter.gate!.complete();
        await rejected;
      });

      test('通过 CF 后立即重试读取，不受后台授权冷却限制', () async {
        adapter.status = 403;
        adapter.headers['cf-mitigated'] = ['challenge'];
        await expectLater(
          client.getUserInfo(),
          throwsA(predicate<Object>(OAuthErrorPolicy.isCfChallenge)),
        );
        adapter.status = 200;
        adapter.headers.clear();
        expect((await client.getUserInfo())['username'], 'alice');
        onlyUserInfoRequests();
      });
    });
  }
}
