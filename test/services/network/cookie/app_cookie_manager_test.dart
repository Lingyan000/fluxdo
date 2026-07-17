import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

void main() {
  group('AppCookieManager.loadCookies', () {
    test('忽略 RequestOptions 上残留的旧 Cookie 头，始终使用 CookieJar 最新值', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [Cookie('_t', 'new-token')..path = '/']);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
        headers: {HttpHeaders.cookieHeader: '_t=old-token; other=legacy'},
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, '_t=new-token');
      expect(cookieHeader, isNot(contains('old-token')));
      expect(cookieHeader, isNot(contains('other=legacy')));
    });

    test('同名同 path 冲突时优先使用 host-only 会话 Cookie', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [
        Cookie('_t', 'host-token')..path = '/',
        Cookie('_t', 'domain-token')
          ..domain = '.linux.do'
          ..path = '/',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, '_t=host-token');
      expect(cookieHeader, isNot(contains('domain-token')));
    });

    test('会话 Cookie 即使 path 不同也只发送主站根路径 winner', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [
        Cookie('_t', 'root-token')..path = '/',
        Cookie('_t', 'scoped-token')..path = '/session',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, '_t=root-token');
      expect(cookieHeader, isNot(contains('scoped-token')));
    });

    test('会话 Cookie 的 domain 污染副本不会发送到子域名', () async {
      final jar = CookieJar();
      await jar.saveFromResponse(Uri.parse('https://linux.do'), [
        Cookie('_t', 'polluted-token')
          ..domain = '.linux.do'
          ..path = '/',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/api/v1/oauth/user-info',
        baseUrl: 'https://cdk.linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, isEmpty);
    });

    test('非会话同名不同 path Cookie 仍按 RFC 同时发送', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [
        Cookie('theme', 'root')..path = '/',
        Cookie('theme', 'scoped')..path = '/session',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, contains('theme=scoped'));
      expect(cookieHeader, contains('theme=root'));
    });

    test('cf_clearance 双变体按过期时间选最新,与顺序无关', () {
      final now = DateTime.now();
      final stale = Cookie('cf_clearance', 'stale-value-000000000000')
        ..domain = '.linux.do'
        ..path = '/'
        ..secure = true
        ..httpOnly = true
        ..expires = now.add(const Duration(hours: 1));
      final fresh = Cookie('cf_clearance', 'fresh-value-111111111111')
        ..domain = '.linux.do'
        ..path = '/'
        ..secure = true
        ..httpOnly = true
        ..expires = now.add(const Duration(days: 1));

      // 两种顺序都必须选中 expires 更晚那枚(绕过 CookieJar 落库去重,
      // 直接验证发请求选优逻辑)。
      for (final cookies in [
        [stale, fresh],
        [fresh, stale],
      ]) {
        final selected = AppCookieManager.selectCookiesForTest(
          cookies,
          Uri.parse('https://linux.do/topics/timings'),
        );
        final clearance = selected.where((c) => c.name == 'cf_clearance');
        expect(clearance, hasLength(1));
        expect(clearance.first.value, 'fresh-value-111111111111');
      }
    });
  });

  group('CookieJarService.buildCookieHeaderForRequest', () {
    test('CDK retry header 保留业务 domain cookie 且不带主站登录 cookie', () {
      final header = CookieJarService.buildCookieHeaderForRequest([
        Cookie('cf_clearance', 'cf-token')
          ..domain = '.linux.do'
          ..path = '/',
        Cookie('linux_do_cdk_session_id', 'cdk-token')
          ..domain = '.linux.do'
          ..path = '/',
        Cookie('_t', 'polluted-token')
          ..domain = '.linux.do'
          ..path = '/',
      ], Uri.parse('https://cdk.linux.do/api/v1/oauth/user-info'));

      expect(header, contains('cf_clearance=cf-token'));
      expect(header, contains('linux_do_cdk_session_id=cdk-token'));
      expect(header, isNot(contains('_t=')));
    });

    test('cf_clearance 双变体按过期时间选最新,与顺序无关', () {
      final now = DateTime.now();
      final stale = Cookie('cf_clearance', 'stale-value-000000000000')
        ..domain = '.linux.do'
        ..path = '/'
        ..expires = now.add(const Duration(hours: 1));
      final fresh = Cookie('cf_clearance', 'fresh-value-111111111111')
        ..domain = '.linux.do'
        ..path = '/'
        ..expires = now.add(const Duration(days: 1));

      for (final cookies in [
        [stale, fresh],
        [fresh, stale],
      ]) {
        final header = CookieJarService.buildCookieHeaderForRequest(
          cookies,
          Uri.parse('https://linux.do/topics/timings'),
        );

        expect(header, contains('fresh-value-111111111111'));
        expect(header, isNot(contains('stale-value-000000000000')));
      }
    });
  });
}
