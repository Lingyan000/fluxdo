import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_connect_login.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

class _OAuthAdapter implements HttpClientAdapter {
  _OAuthAdapter({
    this.site = 'https://ldcstore.com',
    this.authHost = 'api.ldspro.qzz.io',
  });
  final String site, authHost;
  final requests = <RequestOptions>[];
  String challenge = '';
  String handoffEncoding = 'url';
  bool queryHandoff = false;
  int callbackStatus = 302;
  String callbackBody = '';
  String callbackType = 'text/html';
  String Function()? callbackDocument;
  String get callbackUrl =>
      '$site/auth/callback${queryHandoff ? '?' : '#'}ldsp_oauth=$handoff';
  String get handoff {
    final json = jsonEncode({
      'c': 'a' * 43,
      's': wrongState ? 'other' : 'bound-state',
      'exp': 1,
      'label': '>>>',
    });
    final standard = base64.encode(utf8.encode(json));
    return switch (handoffEncoding) {
      'standard' => standard,
      'escaped' => Uri.encodeComponent(standard),
      'percentJson' => base64.encode(utf8.encode(Uri.encodeComponent(json))),
      _ => base64Url.encode(utf8.encode(json)).replaceAll('=', ''),
    };
  }

  final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  bool wrongState = false,
      wrongIdentity = false,
      verifyFailed = false,
      exchangeTimeout = false;
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  String get token =>
      '${encode({'alg': 'HS256'})}.${encode({'sub': '42', 'site': 'linux.do', 'exp': expiry})}.signature';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final uri = options.uri;
    Map<String, Object?> payload;
    switch (uri.path) {
      case '/api/auth/init':
        challenge = uri.queryParameters['code_challenge']!;
        expect(uri.queryParameters['return_url'], '$site/auth/callback');
        payload = {
          'auth_url': Uri.https('connect.linux.do', '/oauth2/authorize', {
            'redirect_uri': 'https://$authHost/api/auth/callback',
            'state': 'bound-state',
          }).toString(),
          'state': 'bound-state',
        };
      case '/oauth2/authorize':
        return ResponseBody.fromString(
          '<a href="/oauth2/approve/test">同意</a>',
          200,
        );
      case '/oauth2/approve/test':
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [
              'https://$authHost/api/auth/callback?code=provider-code&state=bound-state',
            ],
          },
        );
      case '/api/auth/callback':
        expect(options.headers['Accept'], contains('text/html'));
        expect(options.headers['User-Agent'], isNotEmpty);
        expect(options.headers.containsKey('Cookie'), isFalse);
        expect(options.headers.containsKey('Authorization'), isFalse);
        return ResponseBody.fromString(
          callbackDocument?.call() ?? callbackBody,
          callbackStatus,
          headers: {
            'content-type': [callbackType],
            'x-request-id': ['request-fixture-42'],
            if (callbackStatus == 302) 'location': [callbackUrl],
          },
        );
      case '/api/shop/auth/exchange':
        final request = jsonDecode(options.data as String);
        expect(
          base64Url
              .encode(sha256.convert(utf8.encode(request['verifier'])).bytes)
              .replaceAll('=', ''),
          challenge,
        );
        expect(request['state'], 'bound-state');
        expect(request['origin'], site);
        if (exchangeTimeout) {
          throw DioException.receiveTimeout(
            timeout: const Duration(seconds: 1),
            requestOptions: options,
          );
        }
        payload = {
          'token': token,
          'user': {'id': 42},
        };
      case '/api/shop/auth/verify':
        expect(options.headers['Authorization'], 'Bearer $token');
        payload = {
          'authenticated': !verifyFailed,
          'user': {
            'id': wrongIdentity ? 43 : 42,
            'username': 'tester',
            'site': 'linux.do',
          },
        };
      default:
        throw StateError('未预期请求 ${uri.path}');
    }
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'data': payload}),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void loginTest(String description, Future<void> Function() body) {
  testWidgets(description, (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      ),
    );
    await tester.runAsync(body);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manifest = MetaversePluginManifest.parse(
    jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
  );
  late _OAuthAdapter api;
  late MetaversePluginNetwork network;
  late MetaverseConnectLogin login;
  setUp(() {
    api = _OAuthAdapter();
    network = MetaversePluginNetwork(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = api,
      lookup: (_) async => [InternetAddress('198.18.0.6')],
    );
    login = MetaverseConnectLogin(
      network,
      connectClient: Dio()..httpClientAdapter = api,
    );
  });
  tearDown(() {
    login.dispose();
    network.dispose();
  });
  loginTest('原生 Connect、PKCE 交换、服务身份校验返回可用于报价和建单的会话', () async {
    final session = await login.authorize(
      manifest,
      accountId: 42,
      active: () => true,
    );
    expect(session.accountId, 42);
    expect(api.requests.any((r) => r.uri.host == 'api.ldspro.qzz.io'), isTrue);
    expect(session.queryUrls, contains(manifest.auth.queries['orderQuote']));
    expect(session.checkout?.endpoints, manifest.auth.checkout);
    expect(session.checkout?.subject, 'linux.do:42');
    expect(session.checkout?.displayName, 'tester');
    expect(
      api.requests.where((r) => r.uri.path.endsWith('/exchange')),
      hasLength(1),
    );
    expect(
      api.requests
          .where((r) => r.uri.host == 'connect.linux.do')
          .every((r) => !r.headers.containsKey('Authorization')),
      isTrue,
    );
  });
  for (final encoding in ['standard', 'escaped', 'percentJson', 'url']) {
    for (final query in [true, false]) {
      loginTest('授权交接兼容 $encoding 编码，query=$query', () async {
        api.handoffEncoding = encoding;
        api.queryHandoff = query;
        if (encoding == 'standard') expect(api.handoff, contains('+'));
        final session = await login.authorize(
          manifest,
          accountId: 42,
          active: () => true,
        );
        expect(session.accountId, 42);
      });
    }
  }
  for (final status in [200, 400, 403, 502]) {
    loginTest('回调 HTTP $status 没有跳转时保留诊断，不误报同意按钮或重放授权码', () async {
      api.callbackStatus = status;
      api.callbackBody = status == 400
          ? jsonEncode({
              'success': false,
              'error': {
                'code': 'OAUTH_REAUTHORIZE_REQUIRED',
                'message': '不应输出的服务端正文和 provider-code',
              },
            })
          : '<html>不应输出的验证页和 bound-state</html>';
      api.callbackType = status == 400 ? 'application/json' : 'text/html';
      await expectLater(
        login.authorize(manifest, accountId: 42, active: () => true),
        throwsA(
          isA<MetaverseLoginException>()
              .having((e) => e.reason, '准确阶段原因', 'oauth_callback_response')
              .having((e) => e.status, 'HTTP 状态', status)
              .having(
                (e) => e.serviceCode,
                '协议错误码',
                status == 400 ? 'OAUTH_REAUTHORIZE_REQUIRED' : null,
              )
              .having(
                (e) => e.responseType,
                '响应类型',
                status == 400 ? 'json' : 'html',
              )
              .having((e) => e.requestId, '服务追踪编号', 'request-fixture-42')
              .having(
                (e) => e.message,
                '用户提示',
                status == 400
                    ? S.current.metaverse_loginRestartRequired
                    : S.current.metaverse_loginResponseFailed(
                        S.current.metaverse_loginCallback,
                        '$status',
                      ),
              ),
        ),
      );
      expect(
        api.requests.where((r) => r.uri.path == '/api/auth/callback'),
        hasLength(1),
      );
      expect(
        api.requests.where((r) => r.uri.path.endsWith('/exchange')),
        isEmpty,
      );
    });
  }
  final htmlCallbacks = <String, String Function(String)>{
    'meta refresh': (url) =>
        '<meta http-equiv="Refresh" content="0; URL=$url">',
    '带引号的 meta refresh': (url) =>
        '<meta http-equiv="refresh" content="0;url=\'$url\'">',
    'HTML 实体链接': (url) => '<a href="${url.replaceAll('&', '&amp;')}">继续</a>',
    '脚本直接赋值': (url) =>
        '<script>window.location.href = ${jsonEncode(url)};</script>',
    '脚本变量与延时跳转': (url) =>
        '''
        <script>
          // 回调页面的说明中可以有 '单引号和 "双引号
          const target = ${jsonEncode(url)};
          setTimeout(() => window.location.replace(target), 100);
        </script>''',
    '脚本单引号': (url) => "<script>location.replace('$url');</script>",
    '脚本静态模板': (url) => '<script>location.href = `$url`;</script>',
    '脚本 JSON 转义': (url) =>
        '<script>location.assign('
        '${jsonEncode(url).replaceAll('/', r'\/').replaceAll('&', r'\u0026')}'
        ');</script>',
    '重复的脚本和链接': (url) =>
        '<script>location.replace(${jsonEncode(url)});</script>'
        '<a href="${url.replaceAll('&', '&amp;')}">继续</a>',
  };
  for (final entry in htmlCallbacks.entries) {
    loginTest('HTTP 200 HTML ${entry.key} 继续 PKCE 交换和账号校验', () async {
      api.callbackStatus = 200;
      api.queryHandoff = true;
      api.handoffEncoding = 'standard';
      api.callbackDocument = () =>
          entry.value('${api.callbackUrl}&redirect=%2F');
      final session = await login.authorize(
        manifest,
        accountId: 42,
        active: () => true,
      );
      expect(session.accountId, 42);
      expect(session.checkout?.subject, 'linux.do:42');
      expect(
        api.requests.where((r) => r.uri.path == '/api/auth/callback'),
        hasLength(1),
      );
      expect(
        api.requests.where((r) => r.uri.path.endsWith('/exchange')),
        hasLength(1),
      );
      expect(api.requests.any((r) => r.uri.host == 'ldcstore.com'), isFalse);
    });
  }
  loginTest('士多返回按钮与延时脚本交接同一地址时完成授权', () async {
    // 公开接入实现记录的线上页面结构。交接内容使用测试生成的 PKCE 授权码。
    // https://github.com/1molchuan/CFluxDo/blob/ab08774886de7be2665976a10c00bdf91326a0de/test/services/ld_store/ld_store_service_test.dart#L150
    api.callbackStatus = 200;
    api.handoffEncoding = 'percentJson';
    api.callbackDocument = () {
      final url = Uri.parse(api.callbackUrl)
          .replace(queryParameters: {'redirect': '/'})
          .toString();
      return '''<!DOCTYPE html><html><body>
        <a class="action-btn hidden" id="returnBtn" href="$url">返回</a>
        <script>(function() {
          const success = true;
          const redirectUrl = ${jsonEncode(url)};
          setTimeout(() => { window.location.replace(redirectUrl); }, 500);
        })();</script>
        </body></html>''';
    };
    final session = await login.authorize(
      manifest,
      accountId: 42,
      active: () => true,
    );
    expect(session.accountId, 42);
    expect(session.checkout?.subject, 'linux.do:42');
    expect(
      api.requests.where((r) => r.uri.path == '/api/auth/callback'),
      hasLength(1),
    );
    expect(
      api.requests.where((r) => r.uri.path.endsWith('/exchange')),
      hasLength(1),
    );
  });
  for (final issue in [
    'host',
    'path',
    'http',
    'userinfo',
    'ambiguous',
    'comment',
    'externalScript',
    'json',
    'errorStatus',
    'state',
    'identity',
  ]) {
    loginTest('HTML 交接拒绝无效 $issue，保留授权边界', () async {
      api.callbackStatus = issue == 'errorStatus' ? 403 : 200;
      api.callbackType = issue == 'json' ? 'application/json' : 'text/html';
      api.wrongState = issue == 'state';
      api.wrongIdentity = issue == 'identity';
      api.callbackDocument = () {
        var url = api.callbackUrl;
        url = switch (issue) {
          'host' => url.replaceFirst('ldcstore.com', 'untrusted.example.org'),
          'path' => url.replaceFirst('/auth/callback', '/other'),
          'http' => url.replaceFirst('https:', 'http:'),
          'userinfo' => url.replaceFirst('https://', 'https://injected@'),
          _ => url,
        };
        final literal = jsonEncode(url);
        return switch (issue) {
          'ambiguous' =>
            '<a href="$url">继续</a>'
                '<a href="${url.replaceFirst('ldsp_oauth=', 'ldsp_oauth=other')}">继续</a>',
          'comment' => '<script>/* location.href=$literal */</script>',
          'externalScript' =>
            '<script src="https://untrusted.example.org/code.js">'
                'location.href=$literal;</script>',
          _ => '<script>location.replace($literal);</script>',
        };
      };
      await expectLater(
        login.authorize(manifest, accountId: 42, active: () => true),
        throwsA(
          isA<MetaverseLoginException>().having(
            (error) => error.reason,
            '失败原因',
            switch (issue) {
              'state' => 'oauth_state_mismatch',
              'identity' => 'oauth_identity_mismatch',
              _ => 'oauth_callback_response',
            },
          ),
        ),
      );
      expect(
        api.requests.where((r) => r.uri.path.endsWith('/exchange')),
        hasLength(issue == 'identity' ? 1 : 0),
      );
      expect(
        api.requests.any((r) => r.uri.host == 'untrusted.example.org'),
        isFalse,
      );
    });
  }
  loginTest('旧清单漏声明线上回调域名时提示更新，不放宽网络权限', () async {
    final json = jsonDecode(
      File('plugins/ld-store/plugin.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    (json['permissions']['network'] as List).remove('api.ldspro.qzz.io');
    await expectLater(
      login.authorize(
        MetaversePluginManifest.parse(json),
        accountId: 42,
        active: () => true,
      ),
      throwsA(
        isA<MetaverseLoginException>().having(
          (e) => e.message,
          '更新提示',
          S.current.metaverse_loginCallbackNotDeclared,
        ),
      ),
    );
    expect(api.requests, hasLength(1));
  });
  for (final issue in ['state', 'identity', 'verify', 'exchange']) {
    loginTest('拒绝无效 $issue 并且不重放授权码', () async {
      api.wrongState = issue == 'state';
      api.wrongIdentity = issue == 'identity';
      api.verifyFailed = issue == 'verify';
      api.exchangeTimeout = issue == 'exchange';
      await expectLater(
        login.authorize(manifest, accountId: 42, active: () => true),
        throwsA(
          isA<MetaverseLoginException>().having(
            (e) => e.message,
            '失败阶段',
            S.current.metaverse_loginStageFailed(switch (issue) {
              'state' => S.current.metaverse_loginCallback,
              'exchange' => S.current.metaverse_loginExchange,
              _ => S.current.metaverse_loginVerification,
            }),
          ),
        ),
      );
      expect(
        api.requests.where((r) => r.uri.path.endsWith('/exchange')).length,
        lessThanOrEqualTo(1),
      );
    });
  }
  loginTest('同交接协议的新服务通过清单配置原生登录，全部业务域名可替换', () async {
    final other = MetaversePluginManifest.parse(
      jsonDecode(
        File('plugins/ld-store/plugin.json')
            .readAsStringSync()
            .replaceAll('ldcstore.com', 'other.example.org')
            .replaceAll('api1.ldspro.qzz.io', 'auth.example.org')
            .replaceAll('api.ldspro.qzz.io', 'callback.example.org')
            .replaceAll('api2.ldspro.qzz.io', 'api.example.org'),
      ),
    );
    final adapter = _OAuthAdapter(
      site: 'https://other.example.org',
      authHost: 'auth.example.org',
    );
    final otherNetwork = MetaversePluginNetwork(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('198.18.0.6')],
    );
    final otherLogin = MetaverseConnectLogin(
      otherNetwork,
      connectClient: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(otherNetwork.dispose);
    addTearDown(otherLogin.dispose);
    final session = await otherLogin.authorize(
      other,
      accountId: 42,
      active: () => true,
    );
    expect(session.accountId, 42);
    expect(
      session.checkout!.endpoints.create,
      startsWith('https://api.example.org/'),
    );
    expect(
      adapter.requests.every(
        (r) =>
            !r.uri.host.contains('ldspro') && !r.uri.host.contains('ldcstore'),
      ),
      isTrue,
    );
  });
  loginTest('账号退出后停止授权导航', () async {
    await expectLater(
      login.authorize(manifest, accountId: 42, active: () => false),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(api.requests, hasLength(1));
  });
}
