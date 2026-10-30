import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

import '../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  const verifyUrl = 'https://linux.do/challenge';

  setUpAll(platform.initialize);
  setUp(platform.reset);
  tearDown(platform.reset);

  Future<void> mount(
    WidgetTester tester,
    List<bool> results, {
    Set<String>? oldWebViewValues,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: CfChallengePage(
            verifyUrl: verifyUrl,
            oldCfClearanceValue: 'old',
            oldCfClearanceValues: oldWebViewValues,
            startInBackground: true,
            onResult: results.add,
          ),
        ),
      ),
    );
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
    await tester.pump();
  }

  void source404({String url = verifyUrl}) {
    platform.webView!.params.onReceivedHttpError!(
      platform.controller.wrapped,
      WebResourceRequest(url: WebUri(url), isForMainFrame: true),
      WebResourceResponse(
        statusCode: 404,
        headers: {'content-type': 'text/html'},
      ),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // 让有界探测观察到页面已销毁并退出。
    await tester.pump(const Duration(milliseconds: 500));
  }

  for (final hasResidue in [false, true]) {
    testWidgets('源站 404 ${hasResidue ? 'Cookie 未变化' : '没有 clearance'}也立即结束验证', (
      tester,
    ) async {
      platform.cookies.values = hasResidue ? [cfTestCookie('old')] : [];
      final results = <bool>[];
      await mount(tester, results);

      source404();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(results, [true]);
      expect(await jar.getCfClearance(), hasResidue ? 'old' : isNull);
      await unmount(tester);
    });
  }

  testWidgets('源站无盾即可结束，已有旧副本仍按普通同步规则保护在位值', (tester) async {
    await jar.cookieJar.saveFromResponse(Uri.parse(verifyUrl), [
      io.Cookie('cf_clearance', 'incumbent')
        ..domain = '.linux.do'
        ..path = '/',
    ]);
    platform.cookies.values = [cfTestCookie('webview-residue')];
    final results = <bool>[];
    await mount(tester, results, oldWebViewValues: {'webview-residue'});

    source404();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(results, [true]);
    expect(await jar.getCfClearance(), 'incumbent');
    await unmount(tester);
  });

  testWidgets('源站响应立即结束验证，Cookie 同步在后台完成', (tester) async {
    final results = <bool>[];
    await mount(tester, results);
    final pendingSnapshot = Completer<List<Cookie>>();
    platform.cookies.singleValue = 'fresh';
    platform.cookies.readSnapshot = () => pendingSnapshot.future;
    source404();
    await tester.pump(const Duration(milliseconds: 200));
    expect(results, [true], reason: '页面已到源站，不能被 Cookie 写入阻塞');
    expect(await jar.getCfClearance(), isNull);

    pendingSnapshot.complete([cfTestCookie('fresh')]);
    await tester.pump();
    expect(results, [true]);
    expect(await jar.getCfClearance(), 'fresh');
    await unmount(tester);
  });

  testWidgets('Cookie 同步没有更新 jar，也不改变源站已放行的结果', (tester) async {
    await jar.cookieJar.saveFromResponse(Uri.parse(verifyUrl), [
      io.Cookie('cf_clearance', 'other')
        ..domain = '.linux.do'
        ..path = '/',
    ]);
    platform.cookies.singleValue = 'fresh';
    platform.cookies.values = [cfTestCookie('other')];
    final results = <bool>[];
    await mount(tester, results);

    source404();
    await tester.pump();

    expect(results, [true]);
    expect(await jar.getCfClearance(), 'other');
    await unmount(tester);
  });

  testWidgets('已有 fallback 探测收到源站状态后立即收场', (tester) async {
    final results = <bool>[];
    await mount(tester, results);
    final pendingProbe =
        platform.controller.handlers['onChallengeNavigation']!(const [])
            as Future<void>;
    await tester.pump();
    expect(results, isEmpty);
    source404();
    await tester.pump();
    expect(results, [true]);
    await tester.pump(const Duration(milliseconds: 200));
    await pendingProbe;

    expect(results, [true], reason: '迟到的探测不能重复结束验证');
    await unmount(tester);
  });

  for (final statusCode in [200, 404]) {
    testWidgets('源站 $statusCode 导航立即结束，不依赖 404 或新 Cookie', (tester) async {
      final results = <bool>[];
      await mount(tester, results);
      final action = await platform.webView!.params.onNavigationResponse!(
        platform.controller.wrapped,
        NavigationResponse(
          isForMainFrame: true,
          canShowMIMEType: true,
          response: URLResponse(
            url: WebUri(verifyUrl),
            statusCode: statusCode,
            expectedContentLength: 0,
          ),
        ),
      );
      await tester.pump();

      expect(action, NavigationResponseAction.CANCEL);
      expect(results, [true]);
      await unmount(tester);
    });
  }

  testWidgets('没有状态码回调时，完整无盾文档也能结束且无需 Cookie', (tester) async {
    final results = <bool>[];
    await mount(tester, results);
    platform.controller.documentHtml = '<html><body>Origin page</body></html>';
    final probe =
        platform.controller.handlers['onChallengeNavigation']!(const [])
            as Future<void>;
    await tester.pump();
    await probe;

    expect(results, [true]);
    expect(await jar.getCfClearance(), isNull);
    await unmount(tester);
  });

  for (final html in [
    '',
    '<html><body><div class="cf-turnstile"></div></body></html>',
  ]) {
    testWidgets(
      '空白或仍有 CF 挑战的文档不能提前结束：${html.isEmpty ? 'blank' : 'challenge'}',
      (tester) async {
        final results = <bool>[];
        await mount(tester, results);
        platform.controller.documentHtml = html;
        final probe =
            platform.controller.handlers['onChallengeNavigation']!(const [])
                as Future<void>;
        await tester.pump();
        expect(results, isEmpty);

        await unmount(tester);
        await probe;
      },
    );
  }

  testWidgets('续期 Cookie 变化不能结束仍有挑战的页面', (tester) async {
    final results = <bool>[];
    await mount(tester, results);
    platform.cookies.values = [cfTestCookie('renewed')];
    platform.controller.documentHtml =
        '<html><body><div class="cf-turnstile"></div></body></html>';
    final challengeCallback =
        platform.controller.handlers['onChallengeComplete']!(const [
              '/cdn-cgi/challenge-platform',
              200,
            ])
            as Future<void>;
    await tester.pump();
    await challengeCallback;
    expect(results, isEmpty);

    final probe =
        platform.controller.handlers['onChallengeNavigation']!(const [])
            as Future<void>;
    await tester.pump();
    expect(results, isEmpty, reason: 'Cookie 续期不证明当前页面已经无盾');

    platform.controller.documentHtml = '<html><body>Origin page</body></html>';
    await tester.pump(const Duration(milliseconds: 200));
    await probe;
    expect(results, [true]);
    await unmount(tester);
  });

  testWidgets('cf-mitigated challenge 响应不能当作源站放行', (tester) async {
    final results = <bool>[];
    await mount(tester, results);
    final action = await platform.webView!.params.onNavigationResponse!(
      platform.controller.wrapped,
      NavigationResponse(
        isForMainFrame: true,
        canShowMIMEType: true,
        response: URLResponse(
          url: WebUri(verifyUrl),
          statusCode: 200,
          expectedContentLength: 0,
          headers: {'cf-mitigated': 'challenge'},
        ),
      ),
    );
    await tester.pump();

    expect(action, NavigationResponseAction.ALLOW);
    expect(results, isEmpty);
    await unmount(tester);
  });
}
