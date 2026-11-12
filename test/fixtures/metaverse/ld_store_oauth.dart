import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class LdStoreOAuthAdapter implements HttpClientAdapter {
  LdStoreOAuthAdapter({
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
