import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_store_observer.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';
import 'package:fluxdo/services/network/cookie/session_cookie_sentinel.dart';
import 'package:fluxdo/services/network/cookie/webview_cookie_priming.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/builders/iframe_builder.dart';

import '../support/browser_test_platform.dart';
import '../support/cookie_sync_fakes.dart';

void main() {
  late BrowserTestPlatform platform;
  late MemoryWriter writer;
  final sentinel = SessionCookieSentinel.instance;
  final priming = WebViewCookiePriming.instance;
  setUp(() {
    platform = BrowserTestPlatform();
    final previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = platform;
    if (previous != null) {
      addTearDown(() => InAppWebViewPlatform.instance = previous);
    }
    writer = MemoryWriter();
    final jar = MemoryJar();
    sentinel.resetForTest();
    priming.resetForTest();
    sentinel.replaceDependenciesForTest(jar: jar, writer: writer);
    priming.replaceDependenciesForTest(
      jar: jar,
      writer: writer,
      sentinel: sentinel,
    );
  });
  tearDown(() async {
    await sentinel.drain();
    priming.resetForTest();
    sentinel.resetForTest();
    CookieStoreObserver.instance.resetForTest();
    sentinel.replaceDependenciesForTest(
      jar: CookieJarService(),
      writer: RawCookieWriter.instance,
    );
    priming.replaceDependenciesForTest(
      jar: CookieJarService(),
      writer: RawCookieWriter.instance,
    );
  });

  Future<InAppWebView> mount(WidgetTester tester, String url) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: IframeWidget(attributes: IframeAttributes(src: url)),
          ),
        ),
      ),
    );
    return tester.widget<InAppWebView>(find.byType(InAppWebView));
  }

  testWidgets('本站 iframe 在 Cookie 就绪后才导航', (tester) async {
    final release = writer.holdRead = Completer<void>();
    final view = await mount(tester, '$origin/embedded');
    expect(view.platform.params.initialUrlRequest, isNull);
    view.platform.params.onWebViewCreated!(platform.controller.wrapped);
    await tester.pump();
    expect(platform.controller.loads, 0);
    release.complete();
    await tester.pump();
    expect(platform.controller.loadRequests, ['$origin/embedded']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同步失败显示加载错误并阻止本站 iframe 导航', (tester) async {
    writer.acceptWrites = false;
    final view = await mount(tester, '$origin/embedded');
    view.platform.params.onWebViewCreated!(platform.controller.wrapped);
    await tester.pump();
    expect(platform.controller.loads, 0);
    expect(find.text(S.current.common_loadFailed), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('第三方 iframe 使用自身的初始导航', (tester) async {
    final view = await mount(tester, 'https://example.test/embed');
    expect(
      view.platform.params.initialUrlRequest?.url.toString(),
      'https://example.test/embed',
    );
    view.platform.params.onWebViewCreated!(platform.controller.wrapped);
    await tester.pump();
    expect(writer.reads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
