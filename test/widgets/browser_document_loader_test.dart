import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/cookie_store_observer.dart';
import 'package:fluxdo/widgets/browser/browser_document_loader.dart';

import '../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  const target = 'https://connect.linux.do/';
  setUpAll(platform.initialize);
  setUp(platform.reset);
  tearDown(() {
    CookieStoreObserver.instance.resetForTest();
  });

  Future<void> mount(
    WidgetTester tester,
    List<String> documents,
    List<Object> errors,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserDocumentLoader(
            url: target,
            onDocument: documents.add,
            onError: (error, _) => errors.add(error),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20 && platform.webView == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(platform.webView, isNotNull);
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
    expect(platform.webView!.params.initialUrlRequest!.url.toString(), target);
  }

  Future<void> finish(WidgetTester tester, String url, String html) async {
    platform.controller.documentUrl = url;
    platform.controller.documentHtml = html;
    final callbacks = platform.webView!.params;
    callbacks.onLoadStart!(platform.controller.wrapped, WebUri(url));
    callbacks.onLoadStop!(platform.controller.wrapped, WebUri(url));
    await tester.pump();
    CookieStoreObserver.instance.resetForTest();
  }

  testWidgets('SSO 中间页与 CF 页面留在浏览器，只返回目标源站文档一次', (tester) async {
    final documents = <String>[];
    final errors = <Object>[];
    await mount(tester, documents, errors);
    final browser = platform.webView;
    await finish(tester, 'about:blank', '<html></html>');
    await finish(
      tester,
      'https://linux.do/session/sso_provider',
      '<html>sign in</html>',
    );
    await finish(tester, target, '<html>cf_chl_opt</html>');
    expect(documents, isEmpty);
    expect(errors, isEmpty);
    expect(platform.webView, same(browser));

    const html = '<html><div class="card">requirements</div></html>';
    await finish(tester, target, html);
    await finish(tester, target, html);
    expect(documents, [html]);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('页面退出后迟到的 HTML 读取不再回调', (tester) async {
    final documents = <String>[];
    final errors = <Object>[];
    await mount(tester, documents, errors);
    final pending = Completer<String>();
    platform.controller.documentRead = pending.future;
    await finish(tester, target, '');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(
      jsonEncode({'url': target, 'html': '<div class="card"></div>'}),
    );
    await tester.pump();
    expect(documents, isEmpty);
    expect(errors, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
