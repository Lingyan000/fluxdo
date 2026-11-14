import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/webview_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/browser_tabs.dart';
import 'package:fluxdo/services/navigation/browser_dock_observer.dart';
import 'package:fluxdo/widgets/browser/browser_dock_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/browser_test_platform.dart';

void main() {
  testWidgets('真实浏览器路由收起与恢复共用 token、不重载，并在显式关闭后释放', (tester) async {
    const safeAreaChannel = MethodChannel('com.fluxdo/browser_safe_area');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      safeAreaChannel,
      (_) async => true,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        safeAreaChannel,
        null,
      );
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final platform = BrowserTestPlatform();
    final previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = platform;
    if (previous != null) {
      addTearDown(() => InAppWebViewPlatform.instance = previous);
    }
    final tabs = BrowserTabsController();
    final observer = BrowserDockObserver();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          browserTabsProvider.overrideWithValue(tabs),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [observer],
            builder: (context, child) => BrowserDockHost(
              controller: tabs,
              observer: observer,
              onRestore: (session) =>
                  WebViewPage.restore(navigator.currentState!, session),
              child: child!,
            ),
            home: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => WebViewPage.open(context, ''),
                    child: const Text('打开网页'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开网页'));
    await tester.pumpAndSettle();
    expect(navigator.currentState!.canPop(), isTrue);
    final firstParams = platform.view!.params;
    final token = firstParams.keepAlive;
    firstParams.onWebViewCreated!(platform.controller.wrapped);
    await tester.pumpAndSettle();
    firstParams.onTitleChanged!(platform.controller.wrapped, '原页面');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起到底部'));
    // 在退出动画尚未完成时尝试恢复，不能再次挂载原生页面。
    await tester.pump();
    expect(tabs.tabs.length, 1);
    var taken = false;
    final pending = tabs.take(tabs.tabs.single).then((session) {
      taken = true;
      return session;
    });
    expect(taken, isFalse);
    // 截图先覆盖一帧，下一帧才启动路由退场。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final shrinking = tester.getRect(
      find.byKey(const ValueKey('browser-route-surface')),
    );
    expect(shrinking.top, greaterThan(0));
    expect(shrinking.height, inExclusiveRange(56, 844));
    await tester.pumpAndSettle();
    final session = (await pending)!;
    expect(platform.controller.released, isEmpty);
    WebViewPage.restore(navigator.currentState!, session);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final expanding = tester.getRect(
      find.byKey(const ValueKey('browser-route-surface')),
    );
    // 没有截图时保持原生网页全尺寸向上展开，方向不因截图失败改变。
    expect(expanding.top, greaterThan(0));
    expect(expanding.left, 0);
    expect(expanding.height, closeTo(844, .001));
    await tester.pumpAndSettle();
    final secondParams = platform.view!.params;
    expect(secondParams.keepAlive, same(token));
    secondParams.onWebViewCreated!(platform.controller.wrapped);
    await tester.pumpAndSettle();
    expect(platform.controller.loads, 0);
    expect(find.text('恢复后的标题'), findsOneWidget);
    // 后台页面可在收起期间改变标题和历史；恢复后应重新读取这些状态。
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('后退'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('browser-leading')));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('browser-route-surface'))),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();
    expect(platform.controller.released, [token]);
    expect(platform.controller.defaultDisposals, 0);
    // 已卸载的旧回调不会 setState after dispose。
    firstParams.onTitleChanged!(platform.controller.wrapped, '迟到的标题');
    firstParams.onProgressChanged!(platform.controller.wrapped, 90);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tabs.dispose();
  });
}
