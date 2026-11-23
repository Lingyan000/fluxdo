import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:common_ui/common_ui.dart' show AppSvgAsset;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/network_settings_page/widgets/cf_verify_card.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/widgets/common/cf_startup_verification.dart';
import 'package:fluxdo/widgets/common/cf_verification_dialog.dart';
import 'package:fluxdo/widgets/common/cloudflare_mark.dart';
import 'package:fluxdo/widgets/draggable_floating_pill.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  const verifyUrl = 'https://linux.do/challenge';
  const originHtml = '<html><body class="page-not-found">404</body></html>';
  const challengeHtml =
      '<html><body><div id="challenge-stage"></div></body></html>';

  setUpAll(platform.initialize);
  setUp(platform.reset);
  tearDown(platform.reset);

  Future<void> mount(
    WidgetTester tester,
    List<bool> results, {
    Set<String>? oldWebViewValues,
    ValueListenable<CfVerifyPresentation?>? presentation,
    VoidCallback? onPromote,
    ValueChanged<CfVerificationState>? onStateChanged,
    ValueChanged<CfVerificationState>? onPageResult,
    CfStartupVerificationHost? startupHost,
    bool reduceMotion = false,
    bool accessibleNavigation = false,
    double textScale = 1,
    ThemeData? darkTheme,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    if (startupHost != null) {
      CfChallengeService().registerStatusHost(startupHost);
      addTearDown(() => CfChallengeService().unregisterStatusHost(startupHost));
    }
    await tester.pumpWidget(
      // 前台验证面板读取模糊偏好，需要 ProviderScope
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            darkTheme: darkTheme,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: reduceMotion,
                accessibleNavigation: accessibleNavigation,
                textScaler: TextScaler.linear(textScale),
              ),
              child: startupHost == null
                  ? child!
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          top: 262,
                          bottom: 68,
                          left: 12,
                          right: 12,
                          child: LayoutBuilder(
                            builder: (_, constraints) {
                              startupHost.layoutViewport(constraints.biggest);
                              return CompositedTransformTarget(
                                link: startupHost.viewportLink,
                                child: const SizedBox.expand(),
                              );
                            },
                          ),
                        ),
                        child!,
                      ],
                    ),
            ),
            home: CfChallengePage(
              verifyUrl: verifyUrl,
              oldCfClearanceValue: 'old',
              oldCfClearanceValues: oldWebViewValues,
              presentation:
                  presentation ?? ValueNotifier(CfVerifyPresentation.pill),
              onStateChanged: onStateChanged,
              onResult: results.add,
              onPageResult: onPageResult,
              onPromoteRequest: onPromote,
            ),
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
      final reports = <CfVerificationState>[];
      await mount(tester, results, onPageResult: reports.add);

      source404();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(results, [true]);
      expect(reports.single.stage, CfVerificationStage.noChallengeObserved);
      expect(reports.single.originEvidence, CfOriginEvidence.response);
      expect(reports.single.evidence, isEmpty);
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

  testWidgets('单值读取命中旧副本时，完整快照仍选本轮新值而非更晚过期的旧值', (tester) async {
    final results = <bool>[];
    await mount(tester, results, oldWebViewValues: {'old'});
    platform.cookies.singleValue = 'old';
    platform.cookies.values = [
      Cookie(
        name: 'cf_clearance',
        value: 'old',
        domain: '.linux.do',
        path: '/',
        isSecure: true,
        isHttpOnly: true,
        expiresDate: DateTime.now()
            .add(const Duration(days: 30))
            .millisecondsSinceEpoch,
      ),
      cfTestCookie('fresh'),
    ];

    source404();
    await tester.pump();
    await CfChallengeService().waitForCompletionCookieSync();

    expect(results, [true]);
    expect(await jar.getCfClearance(), 'fresh');
    await unmount(tester);
  });

  testWidgets('多个本轮新值不按过期时间猜测，仍允许源站无盾页面结束', (tester) async {
    final results = <bool>[];
    await mount(tester, results);
    platform.cookies.values = [
      cfTestCookie('fresh-a'),
      cfTestCookie('fresh-b'),
    ];
    platform.cookies.singleValue = 'old';

    source404();
    await tester.pump();
    await CfChallengeService().waitForCompletionCookieSync();

    expect(results, [true]);
    expect(await jar.getCfClearance(), isNull);
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
    final pendingProbe = platform.controller.handlers['onChallengeNavigation']!(
      const [],
    ) as Future<void>;
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
            headers: {'content-type': 'text/html'},
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
    platform.controller.documentHtml = originHtml;
    final probe = platform.controller.handlers['onChallengeNavigation']!(
      const [],
    ) as Future<void>;
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
        final probe = platform.controller.handlers['onChallengeNavigation']!(
          const [],
        ) as Future<void>;
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
        ]) as Future<void>;
    await tester.pump();
    await challengeCallback;
    expect(results, isEmpty);

    final probe = platform.controller.handlers['onChallengeNavigation']!(
      const [],
    ) as Future<void>;
    await tester.pump();
    expect(results, isEmpty, reason: 'Cookie 续期不证明当前页面已经无盾');

    platform.controller.documentHtml = originHtml;
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

  for (final viaNavigation in [true, false]) {
    testWidgets('主文档先收到挑战头再回 404，尚未显示控件也记为见过挑战（导航=$viaNavigation）', (
      tester,
    ) async {
      final states = <CfVerificationState>[];
      final results = <bool>[];
      await mount(tester, results, onStateChanged: states.add);
      final callbacks = platform.webView!.params;
      final controller = platform.controller.wrapped;
      final url = WebUri(verifyUrl);
      const headers = {'CF-MitIGated': ' Challenge '};
      if (viaNavigation) {
        await callbacks.onNavigationResponse!(
          controller,
          NavigationResponse(
            isForMainFrame: true,
            canShowMIMEType: true,
            response: URLResponse(
              url: url,
              statusCode: 403,
              expectedContentLength: 0,
              headers: headers,
            ),
          ),
        );
      } else {
        callbacks.onReceivedHttpError!(
          controller,
          WebResourceRequest(url: url, isForMainFrame: true),
          WebResourceResponse(statusCode: 429, headers: headers),
        );
      }
      expect(states.last.stage, CfVerificationStage.checking);
      expect(results, isEmpty);
      source404();
      expect(states.last.stage, CfVerificationStage.challengeCleared);
      expect(states.last.evidence, {CfChallengeEvidence.responseHeader});
      expect(states.last.interactionRequested, isFalse);
      expect(states.last.lastHttpStatus, 404);
      expect(results, [true]);
      await unmount(tester);
    });
  }

  testWidgets('子框架、其他入口和相似响应头不算本轮挑战', (tester) async {
    final results = <bool>[];
    final states = <CfVerificationState>[];
    await mount(tester, results, onStateChanged: states.add);
    for (final (url, main, value) in [
      (verifyUrl, false, 'challenge'),
      (verifyUrl, null, 'challenge'),
      ('https://linux.do/assets/site.js', true, 'challenge'),
      ('https://linux.do:8443/challenge', true, 'challenge'),
      (verifyUrl, true, 'not-a-challenge'),
    ]) {
      platform.webView!.params.onReceivedHttpError!(
        platform.controller.wrapped,
        WebResourceRequest(url: WebUri(url), isForMainFrame: main),
        WebResourceResponse(statusCode: 403, headers: {'cf-mitigated': value}),
      );
    }
    expect(states.single.stage, CfVerificationStage.unconfirmed);
    expect(states.single.challengeObserved, isFalse);
    source404();
    expect(results, [true]);
    expect(states.last.stage, CfVerificationStage.noChallengeObserved);
    await unmount(tester);
  });

  testWidgets('交互出现后回到源站，分别保留页面和请求操作的证据', (tester) async {
    final states = <CfVerificationState>[];
    await mount(tester, [], onStateChanged: states.add);
    final controller = platform.controller;
    controller.documentHtml = challengeHtml;
    platform.webView!.params.onPageCommitVisible!(
      controller.wrapped,
      WebUri(verifyUrl),
    );
    await tester.pump();
    expect(states.last.stage, CfVerificationStage.checking);
    await controller.widgetEvent('interactiveBegin');
    expect(states.last.stage, CfVerificationStage.interactionRequired);
    await controller.widgetEvent('interactiveTimeout');
    expect(states.last.stage, CfVerificationStage.interactionExpired);
    source404();
    expect(states.last.stage, CfVerificationStage.challengeCleared);
    expect(states.last.evidence, {
      CfChallengeEvidence.pageContent,
      CfChallengeEvidence.interactionSignal,
    });
    await unmount(tester);
  });

  testWidgets('未确认的错误文档、过期快照和子资源成功都不能当作入口放行', (tester) async {
    final states = <CfVerificationState>[];
    final results = <bool>[];
    await mount(tester, results, onStateChanged: states.add);
    final controller = platform.controller;
    final callbacks = platform.webView!.params;
    final url = WebUri(verifyUrl);
    final stale = Completer<String>();
    controller.documentRead = stale.future;
    final oldRead =
        controller.handlers['onChallengeComplete']!(const []) as Future<void>;
    callbacks.onLoadStart!(controller.wrapped, url);
    stale.complete(
      jsonEncode({'url': verifyUrl, 'ready': true, 'html': originHtml}),
    );
    await oldRead;
    controller.documentRead = null;
    controller.documentUrl = 'https://elsewhere.test/challenge';
    controller.documentHtml = originHtml;
    await controller.handlers['onChallengeComplete']!(const []);
    controller.documentUrl = verifyUrl;
    controller.documentHtml = '<html><body>Gateway error: the page you requested is unavailable.</body></html>';
    await controller.handlers['onChallengeComplete']!(const []);
    expect(results, isEmpty);
    callbacks.onReceivedHttpError!(
      controller.wrapped,
      WebResourceRequest(url: url, isForMainFrame: true),
      WebResourceResponse(statusCode: 503),
    );
    expect(states.last.stage, CfVerificationStage.loadFailed);
    expect(states.last.label(S.current), S.current.cf_loadFailed('HTTP 503'));
    controller.documentHtml = originHtml;
    await controller.handlers['onChallengeComplete']!(const []);
    expect(results, isEmpty);
    source404();
    expect(states.last.stage, CfVerificationStage.noChallengeObserved);
    await unmount(tester);
  });

  testWidgets('普通源站文档中的独立控件不算本次挑战', (tester) async {
    final reports = <CfVerificationState>[];
    await mount(tester, [], onPageResult: reports.add);
    platform.controller.documentHtml = '<html><body class="page-not-found"><div class="cf-turnstile"></div></body></html>';
    await platform.controller.handlers['onChallengeComplete']!(const []);
    expect(reports.single.stage, CfVerificationStage.noChallengeObserved);
    expect(reports.single.originEvidence, CfOriginEvidence.document);
    await unmount(tester);
  });

  testWidgets('控件错误显示公开错误码，随后验证仍可正常完成', (tester) async {
    final states = <CfVerificationState>[];
    final results = <bool>[];
    await mount(
      tester,
      results,
      presentation: ValueNotifier(CfVerifyPresentation.foreground),
      onStateChanged: states.add,
    );
    final controller = platform.controller;
    await controller.widgetEvent('fail', code: 200500, isMainFrame: false);
    await controller.widgetEvent(
      'fail',
      code: 200500,
      frameUrl: 'https://linux.do/',
    );
    expect(states, isEmpty);

    await controller.widgetEvent('fail', code: 200500);
    await tester.pump();
    expect(states.last.stage, CfVerificationStage.widgetError);
    expect(states.last.evidence, {CfChallengeEvidence.widgetError});
    expect(states.last.interactionRequested, isFalse);
    expect(
      find.text(S.current.cf_widgetErrorWithCode('200500')),
      findsOneWidget,
    );
    expect(results, isEmpty);

    await controller.widgetEvent('interactiveBegin');
    expect(states.last.stage, CfVerificationStage.interactionRequired);
    source404();
    expect(results, [true]);
    expect(states.last.stage, CfVerificationStage.challengeCleared);
    expect(states.last.lastWidgetErrorCode, '200500');
    expect(states.last.label(S.current), S.current.cfVerify_success);
    await controller.widgetEvent('fail', code: '300010');
    expect(states.last.lastWidgetErrorCode, '200500');
    await unmount(tester);
  });

  testWidgets('缺码或格式无效的错误只给通用提示，重新加载清除本次错误', (tester) async {
    final states = <CfVerificationState>[];
    await mount(
      tester,
      [],
      presentation: ValueNotifier(CfVerifyPresentation.foreground),
      onStateChanged: states.add,
    );
    for (final code in [null, 0, '1234567', 'some text 200500']) {
      await platform.controller.widgetEvent('fail', code: '200500');
      expect(states.last.lastWidgetErrorCode, '200500');
      await platform.controller.widgetEvent('fail', code: code);
      expect(states.last.lastWidgetErrorCode, isNull);
      expect(states.last.label(S.current), S.current.cf_widgetError);
    }
    await platform.controller.widgetEvent('fail', code: '200500');
    await tester.pump();
    await tester.tap(find.byTooltip(S.current.common_refresh));
    await tester.pump();
    expect(states.last.attempt, 2);
    expect(states.last.lastWidgetErrorCode, isNull);
    expect(states.last.evidence, isEmpty);
    await unmount(tester);
  });

  testWidgets('缺失响应头的 200 等待同一文档的证据，普通 CF 资源不算挑战', (tester) async {
    final results = <bool>[];
    final states = <CfVerificationState>[];
    await mount(tester, results, onStateChanged: states.add);
    final controller = platform.controller;
    for (final headers in <Map<String, String>?>[null, {}]) {
      final action = await platform.webView!.params.onNavigationResponse!(
        controller.wrapped,
        NavigationResponse(
          isForMainFrame: true,
          canShowMIMEType: true,
          response: URLResponse(
            url: WebUri(verifyUrl),
            statusCode: 200,
            expectedContentLength: 0,
            headers: headers,
          ),
        ),
      );
      expect(action, NavigationResponseAction.ALLOW);
    }
    controller.documentHtml = '<html><script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>cloudflare</html>';
    await controller.handlers['onChallengeComplete']!(const []);
    expect(states.last.challengeObserved, isFalse);
    controller.documentHtml = challengeHtml;
    await controller.handlers['onChallengeComplete']!(const []);
    expect(states.last.stage, CfVerificationStage.checking);
    expect(results, isEmpty);
    source404();
    expect(states.last.stage, CfVerificationStage.challengeCleared);
    await unmount(tester);
  });

  testWidgets('用户重新加载验证页独立记一次，前一次的交互不计到这次', (tester) async {
    final states = <CfVerificationState>[];
    await mount(
      tester,
      [],
      presentation: ValueNotifier(CfVerifyPresentation.foreground),
      onStateChanged: states.add,
    );
    await platform.controller.widgetEvent('interactiveBegin');
    await tester.pump();
    expect(states.last.interactionRequested, isTrue);
    await tester.tap(find.byTooltip(S.current.common_refresh));
    await tester.pump();
    expect(states.last.attempt, 2);
    expect(states.last.stage, CfVerificationStage.opening);
    source404();
    expect(states.last.stage, CfVerificationStage.noChallengeObserved);
    expect(states.last.evidence, isEmpty);
    await unmount(tester);
  });

  testWidgets('人工退出保留本轮挑战与交互证据', (tester) async {
    final results = <bool>[];
    final reports = <CfVerificationState>[];
    await mount(
      tester,
      results,
      presentation: ValueNotifier(CfVerifyPresentation.foreground),
      onPageResult: reports.add,
    );
    await platform.controller.widgetEvent('interactiveBegin');
    await tester.pump();
    await tester.tap(find.byTooltip(S.current.common_exit));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, S.current.common_exit));
    await tester.pump();
    expect(reports.single.stage, CfVerificationStage.cancelled);
    expect(reports.single.interactionRequested, isTrue);
    expect(reports.single.reachedOrigin, isFalse);
    expect(results, [false]);
    await unmount(tester);
  });

  testWidgets('主框架无法连接时收场，子资源错误和迟到的交互不改结果', (tester) async {
    final reports = <CfVerificationState>[];
    final results = <bool>[];
    await mount(tester, results, onPageResult: reports.add);
    final controller = platform.controller;
    final error = WebResourceError(
      type: WebResourceErrorType.HOST_LOOKUP,
      description: 'lookup failed',
    );
    for (final main in [false, true]) {
      platform.webView!.params.onReceivedError!(
        controller.wrapped,
        WebResourceRequest(url: WebUri(verifyUrl), isForMainFrame: main),
        error,
      );
      if (!main) expect(results, isEmpty);
    }
    await controller.widgetEvent('interactiveBegin');
    source404();
    expect(reports.single.stage, CfVerificationStage.loadFailed);
    expect(
      reports.single.label(S.current),
      S.current.cf_loadFailed('lookup failed'),
    );
    expect(reports.single.evidence, isEmpty);
    expect(results, [false]);
    await unmount(tester);
  });

  Future<void> startChallenge(WidgetTester tester) async {
    platform.controller.documentHtml = challengeHtml;
    platform.webView!.params.onPageCommitVisible!(
      platform.controller.wrapped,
      WebUri(verifyUrl),
    );
    await tester.pump();
  }

  Future<void> elapse(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  group('后台验证按展示等级升级', () {
    testWidgets('后台控件已上报错误时等待超时仍保留错误原因', (tester) async {
      final reports = <CfVerificationState>[];
      final results = <bool>[];
      await mount(
        tester,
        results,
        presentation: ValueNotifier(CfVerifyPresentation.hidden),
        onPageResult: reports.add,
      );
      await startChallenge(tester);
      await platform.controller.widgetEvent('fail', code: '200500');
      expect(results, isEmpty);
      await elapse(tester, 10);
      expect(results, [false]);
      expect(reports.single.stage, CfVerificationStage.widgetError);
      expect(reports.single.lastWidgetErrorCode, '200500');
      expect(reports.single.interactionRequested, isFalse);
      await unmount(tester);
    });

    testWidgets('等候超时后才出现的人工交互优先显示操作提示', (tester) async {
      final states = <CfVerificationState>[];
      await mount(
        tester,
        [],
        presentation: ValueNotifier(CfVerifyPresentation.foreground),
        onStateChanged: states.add,
      );
      await startChallenge(tester);
      await elapse(tester, 61);
      expect(states.last.stage, CfVerificationStage.timedOut);
      expect(states.last.interactionRequested, isFalse);
      expect(find.text(S.current.cf_verifyTimedOutTitle), findsOneWidget);
      await platform.controller.widgetEvent('interactiveBegin');
      await elapse(tester, 5);
      expect(states.last.stage, CfVerificationStage.interactionRequired);
      expect(find.text(S.current.cf_manualVerifyBannerTitle), findsOneWidget);
      source404();
      expect(states.last.stage, CfVerificationStage.challengeCleared);
      await unmount(tester);
    });

    testWidgets('hidden 超时静默放弃，全程不显示胶囊', (tester) async {
      final results = <bool>[];
      final reports = <CfVerificationState>[];
      var promoted = 0;
      await mount(
        tester,
        results,
        presentation: ValueNotifier(CfVerifyPresentation.hidden),
        onPromote: () => promoted++,
        onPageResult: reports.add,
      );
      await startChallenge(tester);
      await elapse(tester, 4);
      expect(find.byType(DraggableFloatingPill), findsNothing);

      await elapse(tester, 6);
      expect(results, [false]);
      expect(reports.single.stage, CfVerificationStage.timedOut);
      expect(reports.single.interactionRequested, isFalse);
      expect(promoted, 0);
      expect(find.byType(DraggableFloatingPill), findsNothing);
      await unmount(tester);
    });

    testWidgets('pill 超时只切胶囊，blocking 加入后才弹面板', (tester) async {
      final results = <bool>[];
      var promoted = 0;
      final presentation = ValueNotifier<CfVerifyPresentation?>(
        CfVerifyPresentation.pill,
      );
      await mount(
        tester,
        results,
        presentation: presentation,
        onPromote: () => promoted++,
      );
      await startChallenge(tester);
      expect(find.byType(DraggableFloatingPill), findsNothing);
      await elapse(tester, 3);
      expect(find.byType(DraggableFloatingPill), findsOneWidget);

      await elapse(tester, 7);
      expect(results, isEmpty);
      expect(promoted, 0);
      expect(find.text(S.current.cf_verifyTimedOutTitle), findsOneWidget);

      presentation.value = CfVerifyPresentation.blocking;
      await tester.pump();
      expect(promoted, 1);
      expect(find.byType(DraggableFloatingPill), findsNothing);
      await unmount(tester);
    });

    testWidgets('blocking 收到 Turnstile 交互态立即弹面板', (tester) async {
      final results = <bool>[];
      var promoted = 0;
      await mount(
        tester,
        results,
        presentation: ValueNotifier(CfVerifyPresentation.blocking),
        onPromote: () => promoted++,
      );
      await startChallenge(tester);
      final pill = find.byType(DraggableFloatingPill);
      final pillRect = tester.getRect(pill);
      final screen = tester.getRect(find.byType(CfChallengePage));

      await platform.controller.widgetEvent('interactiveBegin');
      await tester.pump();
      expect(promoted, 1);
      final reveal = tester.widget<CfVerificationPanelReveal>(
        find.byType(CfVerificationPanelReveal),
      );
      expect(reveal.from, pillRect.intersect(screen));
      expect(results, isEmpty);
      await unmount(tester);
    });
  });

  group('通用验证弹框', () {
    final browser = find.byType(InAppWebView).hitTestable();
    final mountedBrowser = find.byType(InAppWebView, skipOffstage: false);
    final mark = find.byType(CloudflareMark);
    final surface = find
        .ancestor(
          of: mark,
          matching: find.byWidgetPredicate(
            (widget) => widget is Material && widget.shape != null,
          ),
        )
        .first;

    for (final narrow in [false, true]) {
      testWidgets('${narrow ? '窄屏' : '宽屏'}收到交互信号立即显示完整原页，弹框高度固定', (
        tester,
      ) async {
        final size = narrow ? const Size(360, 720) : const Size(900, 700);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final results = <bool>[];
        await mount(
          tester,
          results,
          presentation: ValueNotifier(CfVerifyPresentation.foreground),
          reduceMotion: narrow,
          accessibleNavigation: narrow,
        );
        final original = tester.state(mountedBrowser);
        final card = tester.getRect(surface);
        expect(card.center, size.center(Offset.zero));
        expect(mark, findsOneWidget);
        expect(browser, findsNothing);
        await startChallenge(tester);
        await tester.pump();
        final checkingTitle = find.text(S.current.cf_challengeDetectedTitle);
        final hint = find.text(S.current.cf_panelCheckingHint);
        expect(tester.getCenter(checkingTitle).dx, closeTo(card.center.dx, 1));
        expect(tester.getCenter(hint).dx, closeTo(card.center.dx, 1));
        expect(
          tester.getTopLeft(hint).dy,
          greaterThan(tester.getBottomLeft(checkingTitle).dy),
        );
        expect(browser, findsNothing);
        await tester.tapAt(tester.getCenter(mountedBrowser));
        expect(platform.controller.pointers, isEmpty);

        await platform.controller.widgetEvent('interactiveBegin');
        await tester.pump();
        final page = tester.getRect(browser);
        expect(hint, findsNothing);
        expect(tester.getRect(surface), card);
        expect(tester.widget<Material>(surface).borderOnForeground, isFalse);
        expect(page.height, greaterThan(card.height / 2));
        expect(
          page.top,
          greaterThan(
            tester
                .getBottomLeft(find.text(S.current.cf_manualVerifyBannerTitle))
                .dy,
          ),
        );
        expect(
          page.bottom,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byTooltip(S.current.common_help)).dy,
          ),
        );
        expect(tester.state(browser), same(original));
        await tester.tapAt(page.topLeft + const Offset(24, 28));
        expect(platform.controller.pointers, [const Offset(24, 28)]);

        await platform.controller.widgetEvent('interactiveEnd');
        await tester.pump();
        expect(find.text(S.current.cf_panelCheckingResult), findsOneWidget);
        expect(tester.getRect(browser), page);
        await platform.controller.widgetEvent('interactiveBegin');
        await tester.pump();
        expect(tester.state(browser), same(original));
        expect(tester.getRect(surface), card);
        source404();
        await tester.pump();
        expect(results, [true]);
        expect(browser, findsNothing);
        await unmount(tester);
      });
    }

    testWidgets('后台转到前台后沿用同一个 WebView，验证页底色跟随弹框主题', (tester) async {
      final darkTheme = ThemeData.dark();
      const customSurface = Color(0xff162f36);
      await mount(
        tester,
        [],
        accessibleNavigation: true,
        darkTheme: darkTheme.copyWith(
          colorScheme: darkTheme.colorScheme.copyWith(surface: customSurface),
        ),
      );
      final page = platform.webView!.params;
      final initialPalette = page.initialUserScripts!.singleWhere(
        (script) => script.source.contains('window.__fluxdoSetCfPagePalette('),
      );
      expect(
        initialPalette.injectionTime,
        UserScriptInjectionTime.AT_DOCUMENT_START,
      );
      expect(initialPalette.forMainFrameOnly, isTrue);
      expect(page.initialSettings!.transparentBackground, isTrue);
      await startChallenge(tester);
      expect(
        platform.controller.pagePaletteScripts.single,
        initialPalette.source,
      );
      await elapse(tester, 3);
      await tester.tap(mark);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(browser, findsNothing);
      expect(find.text(S.current.cf_challengeDetectedTitle), findsOneWidget);
      final original = tester.state(mountedBrowser);
      await platform.controller.widgetEvent('interactiveBegin');
      await tester.pump();
      expect(browser, findsOneWidget);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.widget<Material>(surface).color, customSurface);
      expect(platform.controller.pagePaletteScripts.last, contains('#162f36'));
      expect(tester.state(browser), same(original));
      await tester.tap(find.byTooltip(S.current.common_help));
      await tester.pump();
      expect(browser, findsNothing);
      await tester.tap(find.text(S.current.common_gotIt));
      await tester.pump();
      expect(browser, findsOneWidget);
      expect(tester.state(browser), same(original));
      await tester.tap(find.text(S.current.cf_retryVerify));
      await tester.pump();
      expect(find.text(S.current.cf_verifyOpeningTitle), findsOneWidget);
      expect(browser, findsNothing);
      expect(tester.state(mountedBrowser), same(original));
      await unmount(tester);
    });

    testWidgets('验证页跳回源站时立即让出输入，迟到的回调不能再次显示原页', (tester) async {
      final results = <bool>[];
      await mount(
        tester,
        results,
        presentation: ValueNotifier(CfVerifyPresentation.foreground),
      );
      await startChallenge(tester);
      final controller = platform.controller;
      await controller.widgetEvent('interactiveBegin');
      await tester.pump();
      expect(browser, findsOneWidget);
      final pending = Completer<String>();
      controller.documentRead = pending.future;
      platform.webView!.params.onLoadStart!(
        controller.wrapped,
        WebUri(verifyUrl),
      );
      await tester.pump();
      expect(browser, findsNothing);
      source404();
      pending.complete(
        jsonEncode({'url': verifyUrl, 'ready': true, 'html': challengeHtml}),
      );
      await controller.widgetEvent('interactiveBegin');
      await tester.pump();
      expect(browser, findsNothing);
      expect(results, [true]);
      await unmount(tester);
    });

    testWidgets('过期和可恢复错误在同一页提示，重新加载回到自动检查', (tester) async {
      final results = <bool>[];
      await mount(
        tester,
        results,
        presentation: ValueNotifier(CfVerifyPresentation.foreground),
      );
      await startChallenge(tester);
      final original = tester.state(mountedBrowser);
      await platform.controller.widgetEvent('interactiveTimeout');
      await tester.pump();
      expect(find.text(S.current.cf_interactionExpiredTitle), findsOneWidget);
      expect(tester.state(browser), same(original));
      await platform.controller.widgetEvent('fail', code: '200500');
      await tester.pump();
      expect(
        find.text(S.current.cf_widgetErrorWithCode('200500')),
        findsOneWidget,
      );
      expect(tester.state(browser), same(original));
      await tester.tap(find.text(S.current.cf_retryVerify));
      await tester.pump();
      expect(browser, findsNothing);
      expect(tester.state(mountedBrowser), same(original));
      expect(results, isEmpty);
      source404();
      await unmount(tester);
    });

    testWidgets('超时可以查看已加载但未识别的原页，仍按观测证据判断是否遇到挑战', (tester) async {
      final results = <CfVerificationState>[];
      await mount(
        tester,
        [],
        presentation: ValueNotifier(CfVerifyPresentation.foreground),
        onPageResult: results.add,
      );
      final controller = platform.controller;
      controller.documentHtml = '<html><body>Site verification</body></html>';
      platform.webView!.params.onPageCommitVisible!(
        controller.wrapped,
        WebUri(verifyUrl),
      );
      await elapse(tester, 5);
      expect(browser, findsNothing);
      await elapse(tester, 57);
      await tester.pump();
      expect(browser, findsOneWidget);
      expect(find.text(S.current.cf_verifyTimedOutTitle), findsOneWidget);
      expect(results, isEmpty);
      source404();
      await tester.pump();
      expect(results.single.stage, CfVerificationStage.noChallengeObserved);
      expect(results.single.challengeObserved, isFalse);
      expect(browser, findsNothing);
      await unmount(tester);
    });

    testWidgets('窄屏大字加载失败可就地重试，打开帮助后能返回同一张卡片', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final results = <bool>[];
      await mount(
        tester,
        results,
        presentation: ValueNotifier(CfVerifyPresentation.foreground),
        textScale: 2,
      );
      final original = tester.state(mountedBrowser);
      platform.webView!.params.onReceivedError!(
        platform.controller.wrapped,
        WebResourceRequest(url: WebUri(verifyUrl), isForMainFrame: true),
        WebResourceError(
          type: WebResourceErrorType.HOST_LOOKUP,
          description: 'lookup failed',
        ),
      );
      await tester.pump();
      expect(
        find.text(S.current.cf_loadFailed('lookup failed')),
        findsOneWidget,
      );
      expect(find.text(S.current.cf_panelRetryHint), findsOneWidget);
      expect(browser, findsNothing);
      await tester.tap(find.byTooltip(S.current.common_help));
      await tester.pump();
      expect(find.text(S.current.cf_helpTitle), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text(S.current.common_gotIt));
      await tester.pump();
      await tester.tap(find.text(S.current.cf_retryVerify));
      await tester.pump();
      expect(find.text(S.current.cf_verifyOpeningTitle), findsOneWidget);
      expect(tester.state(mountedBrowser), same(original));
      source404();
      await tester.pump();
      expect(find.byType(CfVerificationDialog), findsNothing);
      expect(results, [true]);
      await unmount(tester);
    });

    testWidgets('后台入口一次点击即可查看，等待和需要操作都保留 Cloudflare 标志', (tester) async {
      for (final needsInput in [false, true]) {
        var promoted = 0;
        await mount(tester, [], onPromote: () => promoted++);
        final original = tester.state(mountedBrowser);
        if (needsInput) {
          await platform.controller.widgetEvent('interactiveBegin');
        }
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(find.byType(CfVerificationDialog), findsNothing);
        expect(mark, findsOneWidget);
        expect(promoted, 0);
        await tester.tap(mark);
        await tester.pump();
        expect(promoted, 1);
        expect(mark, findsOneWidget);
        expect(find.byType(CfVerificationDialog), findsOneWidget);
        expect(tester.state(mountedBrowser), same(original));
        await unmount(tester);
      }
    });

    testWidgets('从网络设置进入同一弹框，系统返回逐层关闭帮助和退出确认', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: AppLocaleUtils.supportedLocales,
              home: const Scaffold(body: CfVerifyCard()),
            ),
          ),
        ),
      );
      final settingIcon = find.descendant(
        of: find.byType(CloudflareMark),
        matching: find.byType(AppSvgAsset),
      );
      expect(
        tester.widget<AppSvgAsset>(settingIcon).tint,
        IconTheme.of(tester.element(settingIcon)).color,
      );
      expect(tester.widget<AppSvgAsset>(settingIcon).tint, isNotNull);
      await tester.tap(find.byType(CloudflareMark));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      final dialog = find.byType(CfVerificationDialog);
      expect(dialog, findsOneWidget);
      final brand = find.descendant(
        of: dialog,
        matching: find.byType(AppSvgAsset),
      );
      expect(tester.widget<AppSvgAsset>(brand).tint, isNull);
      await tester.tap(find.byTooltip(S.current.common_help));
      await tester.pump();
      expect(find.text(S.current.cf_helpTitle), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text(S.current.cf_helpTitle), findsNothing);
      expect(find.text(S.current.cf_abandonVerifyTitle), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text(S.current.cf_abandonVerifyTitle), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text(S.current.cf_abandonVerifyTitle), findsNothing);
      expect(dialog, findsOneWidget);
      await tester.tap(find.byTooltip(S.current.common_exit));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, S.current.common_exit));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(dialog, findsNothing);
      expect(find.byType(CfVerifyCard), findsOneWidget);
      expect(CfChallengeService().inProgressNotifier.value, isFalse);
      await unmount(tester);
      await tester.pump(const Duration(seconds: 5));
      CfChallengeService().resetCooldown();
    });
  });

  group('启动页内嵌验证页', () {
    for (final initial in [
      CfVerifyPresentation.hidden,
      CfVerifyPresentation.foreground,
    ]) {
      testWidgets('${initial.name} 请求在启动屏直接交给原页，完成后让出输入', (tester) async {
        final host = CfStartupVerificationHost();
        final presentation = ValueNotifier<CfVerifyPresentation?>(initial);
        final results = <bool>[];
        var promoted = 0;
        await mount(
          tester,
          results,
          startupHost: host,
          presentation: presentation,
          onPromote: () => promoted++,
        );
        final mountedBrowser = find.byType(InAppWebView, skipOffstage: false);
        final original = tester.state(mountedBrowser);
        if (initial == CfVerifyPresentation.hidden) {
          expect(host.cancelVerification, isNull);
          presentation.value = CfVerifyPresentation.foreground;
          await tester.pump();
        }
        await startChallenge(tester);
        expect(host.pageVisible, isFalse);
        await platform.controller.widgetEvent('interactiveBegin');
        await tester.pump();
        await tester.pump();
        final browser = find.byType(InAppWebView).hitTestable();
        expect(host.pageVisible, isTrue);
        expect(tester.state(browser), same(original));
        expect(find.byType(CfVerificationDialog), findsNothing);
        expect(promoted, 0);
        final page = tester.getRect(browser);
        expect(page.top, 262);
        expect(page.height, greaterThan(200));
        await tester.tapAt(page.topLeft + const Offset(24, 36));
        expect(platform.controller.pointers, [const Offset(24, 36)]);
        source404();
        await tester.pump();
        expect(host.pageVisible, isFalse);
        expect(browser, findsNothing);
        expect(results, [true]);
        await platform.controller.widgetEvent('interactiveBegin');
        expect(host.pageVisible, isFalse);
        await unmount(tester);
      });
    }

    testWidgets('已确认的挑战久候没有交互信号时显示原页，不误记人工操作', (tester) async {
      final host = CfStartupVerificationHost();
      final reports = <CfVerificationState>[];
      await mount(
        tester,
        [],
        startupHost: host,
        presentation: ValueNotifier(CfVerifyPresentation.blocking),
        onPageResult: reports.add,
      );
      await startChallenge(tester);
      await elapse(tester, 3);
      expect(host.pageVisible, isFalse);
      await elapse(tester, 6);
      expect(host.pageVisible, isTrue);
      expect(host.reloadPage, isNotNull);
      source404();
      expect(reports.single.interactionRequested, isFalse);
      expect(reports.single.stage, CfVerificationStage.challengeCleared);
      await unmount(tester);
    });

    testWidgets('自动检查回到源站时直接完成，不显示人工验证页', (tester) async {
      final host = CfStartupVerificationHost();
      final reports = <CfVerificationState>[];
      await mount(
        tester,
        [],
        startupHost: host,
        presentation: ValueNotifier(CfVerifyPresentation.blocking),
        onPageResult: reports.add,
      );
      await startChallenge(tester);
      source404();
      await tester.pump();
      expect(host.pageVisible, isFalse);
      expect(host.reloadPage, isNull);
      expect(reports.single.stage, CfVerificationStage.challengeCleared);
      expect(reports.single.interactionRequested, isFalse);
      await unmount(tester);
    });
  });
}
