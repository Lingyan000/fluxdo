import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/webview_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/browser_navigation.dart';
import 'package:fluxdo/services/browser_safe_area.dart';
import 'package:fluxdo/services/browser_tabs.dart';
import 'package:fluxdo/services/navigation/browser_dock_observer.dart';
import 'package:fluxdo/services/network/cookie/cookie_store_observer.dart';
import 'package:fluxdo/services/network/cookie/webview_cookie_priming.dart';
import 'package:fluxdo/widgets/browser/browser_dock_host.dart';
import 'package:fluxdo/widgets/browser/browser_toolbar.dart';
import 'package:fluxdo/widgets/browser/browser_dock_motion.dart';
import 'package:fluxdo/widgets/browser/browser_web_viewport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/browser_test_platform.dart';
import '../support/cf_test_platform.dart';

const _url = 'https://example.com/current';
final _address = find.byKey(const ValueKey('browser-address-input'));
final _display = find.byKey(const ValueKey('browser-address-display'));

class _Harness {
  final platform = BrowserTestPlatform();
  final tabs = BrowserTabsController();
  final observer = BrowserDockObserver();
  final navigator = GlobalKey<NavigatorState>();
  final boundary = GlobalKey();
  final nativeBoundary = GlobalKey();
  int backgroundLayouts = 0;
  late SharedPreferences preferences;

  PlatformInAppWebViewWidgetCreationParams get callbacks =>
      platform.view!.params;

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool reduceMotion = false,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'web_bookmarks': jsonEncode([
        {
          'url': 'https://flutter.dev/',
          'title': 'Flutter 开发文档',
          'createdAt': '2026-11-08T10:00:00',
        },
      ]),
      'web_history_items': jsonEncode([
        {
          'url': 'https://dart.dev/',
          'title': 'Dart 语言指南',
          'visitedAt': '2026-11-08T09:00:00',
        },
      ]),
    });
    preferences = await SharedPreferences.getInstance();
    InAppWebViewPlatform.instance = platform;
    platform.content = RepaintBoundary(
      key: nativeBoundary,
      child: const _PreviewArticle(),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            browserTabsProvider.overrideWithValue(tabs),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                pageTransitionsTheme: const PageTransitionsTheme(
                  builders: {
                    TargetPlatform.android:
                        PredictiveBackCupertinoPageTransitionsBuilder(),
                  },
                ),
                fontFamily: 'MiSans',
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff326b52),
                  brightness: brightness,
                ),
              ),
              navigatorKey: navigator,
              navigatorObservers: [observer],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                  disableAnimations: reduceMotion,
                ),
                child: BrowserDockHost(
                  controller: tabs,
                  observer: observer,
                  onRestore: (session) =>
                      WebViewPage.restore(navigator.currentState!, session),
                  child: child!,
                ),
              ),
              home: Scaffold(
                key: const ValueKey('browser-test-background'),
                body: LayoutBuilder(
                  builder: (context, constraints) {
                    backgroundLayouts++;
                    return Center(
                      child: Builder(
                        builder: (context) => TextButton(
                          onPressed: () => WebViewPage.open(context, ''),
                          child: const Text('打开网页'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开网页'));
    await tester.pumpAndSettle();
    callbacks.onWebViewCreated!(platform.controller.wrapped);
    await tester.pumpAndSettle();
    start(_url);
    await finish(tester);
  }

  void start(String url) {
    platform.controller.currentUrl = url;
    callbacks.onLoadStart!(platform.controller.wrapped, WebUri(url));
  }

  Future<void> finish(WidgetTester tester) async {
    callbacks.onLoadStop!(
      platform.controller.wrapped,
      WebUri(platform.controller.currentUrl),
    );
    await tester.pump();
    CookieStoreObserver.instance.resetForTest();
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.tap(_display);
    await tester.pumpAndSettle();
    await tester.enterText(_address, query);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
  }

  void fail({String? url, bool mainFrame = true, WebResourceErrorType? type}) {
    callbacks.onReceivedError!(
      platform.controller.wrapped,
      WebResourceRequest(
        url: WebUri(url ?? platform.controller.currentUrl),
        isForMainFrame: mainFrame,
      ),
      WebResourceError(
        type: type ?? WebResourceErrorType.HOST_LOOKUP,
        description: 'test connection failure',
      ),
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    CookieStoreObserver.instance.resetForTest();
    tabs.dispose();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('.artifacts/browser-motion/previews')
        ..createSync(recursive: true);
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> prepareSnapshot(WidgetTester tester) async {
    await tester.runAsync(() async {
      final render =
          nativeBoundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      platform.controller.screenshot = bytes!.buffer.asUint8List();
      image.dispose();
      await precacheImage(
        MemoryImage(platform.controller.screenshot!),
        nativeBoundary.currentContext!,
      );
    });
    // 预览在静止后准备，收起入口不能承担截图和解码工作。
    callbacks.onScrollChanged!(platform.controller.wrapped, 0, 0);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const safeAreaChannel = MethodChannel('com.fluxdo/browser_safe_area');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(safeAreaChannel, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(safeAreaChannel, null);
  });
  setUpAll(() async {
    final directory = await Directory(
      '.artifacts/browser-experience/test-cookies',
    ).create(recursive: true);
    await CfTestPlatform().initialize(cookieDirectory: directory.absolute.path);
    await WebViewCookiePriming.instance.prime(_url);
    CookieStoreObserver.instance.resetForTest();
  });

  testWidgets('地址栏就地展开、全选，取消和系统返回保留原网页', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    final token = h.callbacks.keepAlive;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(_address);
    expect(input.focusNode!.hasFocus, isTrue);
    expect(
      input.controller!.selection,
      TextSelection(baseOffset: 0, extentOffset: _url.length),
    );
    expect(find.text('Flutter 开发文档'), findsOneWidget);
    expect(find.text('Dart 语言指南'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-current-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('browser-navigation-suggestion')),
      findsNothing,
    );
    expect(find.text('恢复后的标题'), findsOneWidget);
    await tester.enterText(_address, '还没有提交');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('browser-navigation-suggestion')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('browser-current-page')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('browser-leading')));
    await tester.pumpAndSettle();
    expect(_address, findsNothing);
    expect(h.platform.controller.loads, 0);
    expect(h.callbacks.keepAlive, same(token));
    await tester.tap(_display);
    await tester.pumpAndSettle();
    await h.navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(_address, findsNothing);
    expect(find.byType(WebViewPage), findsOneWidget);
    await tester.tap(_display);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复后的标题'));
    await tester.pumpAndSettle();
    expect(_address, findsNothing);
    expect(h.platform.controller.loads, 0);
    await h.dispose(tester);
  });

  testWidgets('恢复时先提交的新搜索，在原生控制器连接后加载且不被旧网址覆盖', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    await tester.tap(find.byTooltip('收起到底部'));
    await tester.pumpAndSettle();
    final session = (await h.tabs.take(h.tabs.tabs.single))!;
    WebViewPage.restore(h.navigator.currentState!, session);
    await tester.pumpAndSettle();
    await h.search(tester, '恢复后新搜索');
    expect(h.platform.controller.loads, 0);
    h.callbacks.onWebViewCreated!(h.platform.controller.wrapped);
    await tester.pumpAndSettle();
    final target = Uri.parse(h.platform.controller.loadRequests.single);
    expect(target.host, 'www.google.com');
    expect(target.queryParameters['q'], '恢复后新搜索');
    expect(
      tester.widget<BrowserToolbar>(find.byType(BrowserToolbar)).url,
      target.toString(),
    );
    await h.dispose(tester);
  });

  testWidgets('收起期间网页尺寸和挂载保持稳定；恢复等待原生接回后再淡出截图', (tester) async {
    final h = _Harness();
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
    await h.mount(tester);
    await h.prepareSnapshot(tester);
    final originalSize = tester.getSize(find.byKey(h.nativeBoundary));
    expect(h.platform.mounts, 1);
    await tester.tap(find.byTooltip('收起到底部'));
    await tester.pump();
    await tester.pump();
    final surface = find.byKey(const ValueKey('browser-route-surface'));
    final cover = find.byKey(const ValueKey('browser-snapshot-cover'));
    final movingCard = find.byKey(const ValueKey('browser-moving-dock-card'));
    final background = find.byKey(
      const ValueKey('browser-test-background'),
      skipOffstage: false,
    );
    expect(cover, findsOneWidget);
    var previousTop = 0.0;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getSize(find.byKey(h.nativeBoundary, skipOffstage: false)),
        originalSize,
      );
      expect(h.platform.mounts, 1);
      expect(h.platform.unmounts, 0);
      expect(tester.getRect(background).left, 0);
      expect(tester.getRect(background).right, 390);
      final rect = tester.getRect(surface);
      expect(rect.top, greaterThanOrEqualTo(previousTop));
      expect(rect.center.dx, closeTo(195, .01));
      final cardOpacity = tester.widget<Opacity>(movingCard).opacity;
      final pageOpacity = tester
          .widget<Opacity>(
            find.ancestor(of: surface, matching: find.byType(Opacity)).first,
          )
          .opacity;
      expect(pageOpacity + cardOpacity, closeTo(1, .001));
      previousTop = rect.top;
      final motion = BrowserDockViewport.motionOf(
        tester.element(find.byType(WebViewPage)),
      )!;
      expect(motion.active, isTrue);
    }
    await tester.pump(
      browserDockMinimizeDuration - const Duration(milliseconds: 324),
    );
    final landing = tester.getRect(movingCard);
    expect(tester.widget<Opacity>(movingCard).opacity, greaterThan(.99));
    await tester.pumpAndSettle();
    final settledCard = tester.getRect(
      find.byKey(const ValueKey('browser-dock-card')),
    );
    expect(landing.left, closeTo(settledCard.left, 1));
    expect(landing.top, closeTo(settledCard.top, 1));
    expect(landing.width, closeTo(settledCard.width, 1));
    expect(landing.height, settledCard.height);
    expect(h.platform.unmounts, 1);
    final session = (await h.tabs.take(h.tabs.tabs.single))!;
    WebViewPage.restore(h.navigator.currentState!, session);
    await tester.pump();
    expect(tester.getRect(movingCard), settledCard);
    previousTop = double.infinity;
    for (var frame = 0; frame < 22; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      // 底部展开不能触发下层页面横移，否则右侧会露出未绘制的黑色背景。
      expect(tester.getRect(background).left, 0);
      expect(tester.getRect(background).right, 390);
      final rect = tester.getRect(surface);
      expect(rect.top, greaterThan(0));
      expect(rect.top, lessThanOrEqualTo(previousTop));
      expect(rect.center.dx, closeTo(195, .01));
      previousTop = rect.top;
    }
    await tester.pumpAndSettle();
    expect(h.platform.mounts, 2);
    expect(cover, findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(cover).opacity, 1);
    expect(find.byKey(h.nativeBoundary), findsOneWidget);
    expect(tester.getSize(find.byKey(h.nativeBoundary)), originalSize);
    final titleReady = Completer<String?>();
    h.platform.controller.titleCallback = () => titleReady.future;
    h.callbacks.onWebViewCreated!(h.platform.controller.wrapped);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(cover).opacity, 1);
    titleReady.complete('已接回');
    await tester.pump();
    expect(cover, findsOneWidget);
    await tester.pumpAndSettle();
    expect(cover, findsNothing);
    expect(h.platform.mounts, 2);
    expect(h.platform.unmounts, 1);
    expect(h.platform.controller.loads, 0);
    expect(tester.takeException(), isNull);
    await h.dispose(tester);
  });

  testWidgets('慢截图不阻塞点击收起，首帧开始移动，迟到结果不覆盖会话', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    final screenshot = Completer<Uint8List?>();
    var requests = 0;
    h.platform.controller.screenshotCallback = () {
      requests++;
      return screenshot.future;
    };
    h.callbacks.onScrollChanged!(h.platform.controller.wrapped, 0, 30);
    await tester.pump(const Duration(milliseconds: 500));
    expect(requests, 1);
    await tester.tap(find.byTooltip('收起到底部'));
    expect(h.tabs.tabs, hasLength(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('browser-route-surface'))).dy,
      greaterThan(0),
    );
    expect(requests, 1);
    await tester.pumpAndSettle();
    expect(h.platform.unmounts, 1);
    screenshot.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    expect(h.tabs.tabs.single.preview, isNull);
    await h.dispose(tester);
  });

  testWidgets('顶部下拉跟手，反拖和取消回弹，超过距离后收起且不重载', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    final surface = find.byKey(const ValueKey('browser-route-surface'));
    final area = find.byKey(const ValueKey('browser-minimize-drag-area'));
    final gesture = await tester.startGesture(tester.getCenter(area));
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(tester.getTopLeft(surface).dy, closeTo(100, 1));
    expect(
      tester
          .widget<ClipRRect>(surface)
          .borderRadius
          .resolve(TextDirection.ltr)
          .topLeft
          .x,
      greaterThan(20),
    );
    final handle = find.byKey(const ValueKey('browser-drag-handle'));
    expect(tester.widget<Opacity>(handle).opacity, 1);
    if (const bool.fromEnvironment('BROWSER_PREVIEW')) {
      await h.capture(tester, 'drag-minimize-handle');
    }
    final background = find.byKey(
      const ValueKey('browser-test-background'),
      skipOffstage: false,
    );
    final backgroundSize = tester.getSize(background);
    expect(tester.getRect(background).left, 0);
    expect(tester.getRect(background).right, 390);
    final layouts = h.backgroundLayouts;
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(tester.getTopLeft(surface).dy, closeTo(60, 1));
    expect(tester.getSize(background), backgroundSize);
    expect(tester.getRect(background).left, 0);
    expect(tester.getRect(background).right, 390);
    expect(h.backgroundLayouts, layouts);
    expect(h.tabs.tabs, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(surface), Offset.zero);
    expect(tester.widget<Opacity>(handle).opacity, 0);
    expect(h.navigator.currentState!.userGestureInProgress, isFalse);
    expect(h.platform.mounts, 1);
    final commit = await tester.startGesture(tester.getCenter(area));
    await commit.moveBy(const Offset(0, 24));
    await tester.pump();
    await commit.moveBy(const Offset(0, 320));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(surface).dy, closeTo(320, 1));
    await commit.up();
    await tester.pumpAndSettle();
    expect(h.tabs.tabs, hasLength(1));
    expect(h.platform.unmounts, 1);
    expect(h.platform.controller.loads, 0);
    expect(tester.takeException(), isNull);
    await h.dispose(tester);
  });

  testWidgets('底栏上拉跟手，可中途取消和重新展开', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    await tester.tap(find.byTooltip('收起到底部'));
    await tester.pumpAndSettle();
    final session = h.tabs.tabs.single;
    final area = find.byKey(const ValueKey('browser-restore-drag-area'));
    final surface = find.byKey(const ValueKey('browser-route-surface'));
    final gesture = await tester.startGesture(tester.getCenter(area));
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    final top = tester.getTopLeft(surface).dy;
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(surface).dy, closeTo(top, .01));
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(tester.getTopLeft(surface).dy, closeTo(top - 50, 1));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(h.tabs.tabs, [session]);
    expect(session.isClosed, isFalse);
    expect(h.navigator.currentState!.userGestureInProgress, isFalse);
    final open = await tester.startGesture(tester.getCenter(area));
    await open.moveBy(const Offset(0, -24));
    await tester.pump();
    await open.moveBy(const Offset(0, -360));
    await tester.pump(const Duration(milliseconds: 200));
    await open.up();
    await tester.pumpAndSettle();
    expect(h.tabs.tabs, isEmpty);
    expect(tester.getTopLeft(surface), Offset.zero);
    expect(h.navigator.currentState!.userGestureInProgress, isFalse);
    expect(h.platform.controller.loads, 0);
    expect(tester.takeException(), isNull);
    await h.dispose(tester);
  });

  testWidgets('有预览时下拉取消先接回原生画面，截图不直接消失', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    await h.prepareSnapshot(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('browser-minimize-drag-area')),
      ),
    );
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    final cover = find.byKey(const ValueKey('browser-snapshot-cover'));
    expect(cover, findsOneWidget);
    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(cover, findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(cover).opacity, 1);
    await tester.pumpAndSettle();
    expect(cover, findsNothing);
    expect(h.platform.mounts, 1);
    expect(h.platform.unmounts, 0);
    expect(h.tabs.tabs, isEmpty);
    await h.dispose(tester);
  });

  testWidgets('恢复时控制器提前就绪也等真正展开完成才撤下截图', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    await h.prepareSnapshot(tester);
    await tester.tap(find.byTooltip('收起到底部'));
    await tester.pumpAndSettle();
    final session = (await h.tabs.take(h.tabs.tabs.single))!;
    WebViewPage.restore(h.navigator.currentState!, session);
    await tester.pump();
    h.callbacks.onWebViewCreated!(h.platform.controller.wrapped);
    final cover = find.byKey(const ValueKey('browser-snapshot-cover'));
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(cover, findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(cover).opacity, 1);
      expect(
        BrowserDockViewport.motionOf(tester.element(find.byType(WebViewPage)))!
            .active,
        isTrue,
      );
    }
    await tester.pumpAndSettle();
    expect(cover, findsNothing);
    expect(h.platform.mounts, 2);
    expect(h.platform.unmounts, 1);
    expect(h.platform.controller.loads, 0);
    expect(tester.takeException(), isNull);
    await h.dispose(tester);
  });

  testWidgets('失败时合并恢复操作，Bing 仅用于本次搜索且不改变默认 Google', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    const query = '中文 Flutter & Dart';
    await h.search(tester, query);
    expect(
      Uri.parse(h.platform.controller.loadRequests.single).host,
      'www.google.com',
    );
    h.fail();
    await tester.pumpAndSettle();
    expect(find.text('本次用 Bing 搜索'), findsOneWidget);
    expect(find.text('暂时无法搜索'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-slow-search')), findsNothing);
    expect(find.text(query), findsOneWidget);
    expect(h.preferences.getString('browser_search_engine'), isNull);
    expect(h.platform.controller.loads, 1);
    await tester.tap(find.text('本次用 Bing 搜索'));
    await tester.pumpAndSettle();
    final target = Uri.parse(h.platform.controller.loadRequests.last);
    expect(target.host, 'www.bing.com');
    expect(target.queryParameters['q'], query);
    expect(h.preferences.getString('browser_search_engine'), isNull);
    expect(find.text('本次用 Bing 搜索'), findsNothing);
    await h.finish(tester);
    await h.search(tester, '下一次搜索');
    expect(
      Uri.parse(h.platform.controller.loadRequests.last).host,
      'www.google.com',
    );
    await h.dispose(tester);
  });

  testWidgets('Google 超时才提示；成功、取消、子资源和旧导航错误不误报', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    final google = BrowserSearchEngine.google.search('网络测试').toString();
    h.start(google);
    h.fail(mainFrame: false);
    h.fail(type: WebResourceErrorType.CANCELLED);
    h.fail(url: 'https://old.example/');
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('本次用 Bing 搜索'), findsNothing);
    expect(find.text('无法加载此网页'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('本次用 Bing 搜索'), findsOneWidget);
    expect(find.text('让浏览更轻松'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-load-error')), findsNothing);
    await h.finish(tester);
    expect(find.text('本次用 Bing 搜索'), findsNothing);
    h.start(google);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止加载'));
    await tester.pump(const Duration(seconds: 13));
    h.fail();
    await tester.pumpAndSettle();
    expect(find.text('本次用 Bing 搜索'), findsNothing);
    expect(h.platform.controller.stops, 1);
    h.start(_url);
    h.fail();
    await tester.pumpAndSettle();
    expect(find.text('无法加载此网页'), findsOneWidget);
    expect(find.text('本次用 Bing 搜索'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(h.platform.controller.reloads, 1);
    await h.dispose(tester);
  });

  testWidgets('站点 HTTP 错误保留网页内容并撤下网络提示', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    for (final status in [403, 404, 500]) {
      h.start(BrowserSearchEngine.google.search('验证页面').toString());
      await tester.pump(const Duration(seconds: 13));
      expect(find.byKey(const ValueKey('browser-slow-search')), findsOneWidget);
      h.callbacks.onReceivedHttpError!(
        h.platform.controller.wrapped,
        WebResourceRequest(
          url: WebUri(h.platform.controller.currentUrl),
          isForMainFrame: true,
        ),
        WebResourceResponse(statusCode: status),
      );
      await tester.pump(const Duration(seconds: 13));
      expect(find.byKey(const ValueKey('browser-slow-search')), findsNothing);
      expect(find.byKey(const ValueKey('browser-load-error')), findsNothing);
      expect(find.text('让浏览更轻松'), findsOneWidget);
      await h.finish(tester);
    }
    await h.dispose(tester);
  });

  group('网页安全区', () {
    const landscape = Size(844, 390);
    const notch = FakeViewPadding(left: 47, right: 47, bottom: 21);
    Map<String, Object?> report({
      required bool cover,
      List<double> env = const [0, 0, 0, 0],
      List<double>? background = const [12, 34, 56, 1],
    }) => {
      'cover': cover,
      'env': env,
      'background': background,
      'canvas': [250, 250, 250, 1],
    };
    BrowserWebViewport viewport(WidgetTester tester) =>
        tester.widget<BrowserWebViewport>(find.byType(BrowserWebViewport));
    int edgeSamples(_Harness h) => h.platform.controller.screenshotRequests
        .where((c) => c?.compressFormat == CompressFormat.PNG)
        .length;
    void send(_Harness h, Map<String, Object?> payload) =>
        h.platform.controller.handlers[BrowserSafeAreaProbe.handlerName]!([
          payload,
        ]);
    Rect page(WidgetTester tester, _Harness h) =>
        tester.getRect(find.byKey(h.nativeBoundary));

    tearDown(BrowserSafeAreaPolicy.resetForTest);

    testWidgets('原生安全区随旋转更新，恢复时重新同步同一个保活实例', (tester) async {
      const channel = MethodChannel('com.fluxdo/browser_safe_area');
      final calls = <Map<dynamic, dynamic>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call.arguments as Map);
          return true;
        },
      );
      final h = _Harness();
      tester.view.padding = notch;
      await h.mount(tester, size: landscape);
      expect(calls.last['left'], isTrue);
      send(h, report(cover: true, env: [47, 0, 47, 0]));
      await tester.pump();
      expect(calls.last['left'], isFalse);
      expect(calls.last['right'], isFalse);
      expect(calls.last['top'], isTrue);
      expect(calls.last['bottom'], isTrue);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
      await tester.pumpAndSettle();
      expect(calls.last['left'], isTrue);
      expect(calls.last['right'], isTrue);
      final keepAliveId = calls.last['keepAliveId'];
      await tester.tap(find.byTooltip('收起到底部'));
      await tester.pumpAndSettle();
      final session = (await h.tabs.take(h.tabs.tabs.single))!;
      final beforeRestore = calls.length;
      WebViewPage.restore(h.navigator.currentState!, session);
      await tester.pumpAndSettle();
      h.callbacks.onWebViewCreated!(h.platform.controller.wrapped);
      await tester.pumpAndSettle();
      expect(calls.length, greaterThan(beforeRestore));
      expect(calls.last['keepAliveId'], keepAliveId);
      expect(keepAliveId, h.platform.controller.getViewId());
      await h.dispose(tester);
    });

    testWidgets('工具栏已避让时仍检查网页错误的上下 env', (tester) async {
      final h = _Harness();
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
      await h.mount(tester);
      expect(viewport(tester).unsafe, EdgeInsets.zero);
      final broken = report(cover: true, env: [0, 44, 0, 24]);
      h.platform.controller.evaluate = (source) =>
          source == BrowserSafeAreaProbe.measureSource ? broken : null;
      send(h, broken);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(BrowserSafeAreaPolicy.nativeEnvReliable, isFalse);
      await h.dispose(tester);
    });

    testWidgets('全零样本之后网页上报非零 env 会重新检查', (tester) async {
      final h = _Harness();
      await h.mount(tester);
      var measured = report(cover: true);
      h.platform.controller.evaluate = (source) =>
          source == BrowserSafeAreaProbe.measureSource ? measured : null;
      send(h, measured);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(BrowserSafeAreaPolicy.nativeEnvReliable, isNull);
      measured = report(cover: true, env: [0, 44, 0, 24]);
      send(h, measured);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(BrowserSafeAreaPolicy.nativeEnvReliable, isFalse);
      await h.dispose(tester);
    });

    testWidgets('普通网页让出刘海，cover 网页铺满，实测 env 一致后保持', (tester) async {
      final h = _Harness();
      tester.view.padding = notch;
      await h.mount(tester, size: landscape);
      expect(page(tester, h).left, 47);
      expect(page(tester, h).right, landscape.width - 47);
      send(h, report(cover: false));
      await tester.pump();
      expect(viewport(tester).top, const Color(0xff0c2238));
      expect(viewport(tester).bottom, const Color(0xff0c2238));
      await tester.pump(const Duration(milliseconds: 400));
      expect(edgeSamples(h), 0);
      final measured = report(cover: true, env: [47, 0, 47, 0]);
      h.platform.controller.evaluate = (source) =>
          source == BrowserSafeAreaProbe.measureSource ? measured : null;
      send(h, measured);
      await tester.pump();
      expect(page(tester, h).left, 0);
      expect(page(tester, h).right, landscape.width);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(BrowserSafeAreaPolicy.nativeEnvReliable, isTrue);
      expect(page(tester, h).left, 0);
      await h.dispose(tester);
    });

    testWidgets('原生 env 连续两次对不上时退回留边，并对后续网页生效', (tester) async {
      final h = _Harness();
      tester.view.padding = notch;
      await h.mount(tester, size: landscape);
      final broken = report(cover: true);
      h.platform.controller.evaluate = (source) =>
          source == BrowserSafeAreaProbe.measureSource ? broken : null;
      send(h, broken);
      await tester.pump();
      expect(page(tester, h).left, 0);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(BrowserSafeAreaPolicy.nativeEnvReliable, isNull);
      expect(page(tester, h).left, 0);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(BrowserSafeAreaPolicy.nativeEnvReliable, isFalse);
      expect(page(tester, h).left, 47);
      send(h, report(cover: true, env: [1, 0, 1, 0]));
      await tester.pump();
      expect(page(tester, h).left, 47);
      await h.dispose(tester);
    });

    testWidgets('网页没有声明底色时才截图取色，取不到时用画布色', (tester) async {
      final h = _Harness();
      tester.view.padding = notch;
      await h.mount(tester, size: landscape);
      send(h, report(cover: false, background: null));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(edgeSamples(h), greaterThan(0));
      expect(viewport(tester).top, const Color(0xfffafafa));
      expect(viewport(tester).bottom, const Color(0xfffafafa));
      final sampled = edgeSamples(h);
      send(h, report(cover: true, env: [47, 0, 47, 0], background: null));
      await tester.pump();
      await tester.pump(const Duration(seconds: 13));
      expect(edgeSamples(h), sampled);
      await h.dispose(tester);
    });

    testWidgets('从底部恢复时沿用会话里的安全区声明', (tester) async {
      final h = _Harness();
      tester.view.padding = notch;
      await h.mount(tester, size: landscape);
      send(h, report(cover: true, env: [47, 0, 47, 0]));
      await tester.pump();
      await tester.tap(find.byTooltip('收起到底部'));
      await tester.pumpAndSettle();
      final session = (await h.tabs.take(h.tabs.tabs.single))!;
      expect(session.safeArea?.cover, isTrue);
      WebViewPage.restore(h.navigator.currentState!, session);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserWebViewport>(find.byType(BrowserWebViewport))
            .edgeToEdge,
        isTrue,
      );
      await h.dispose(tester);
    });
  });

  testWidgets('收藏可直接打开，历史可填入编辑，搜索引擎可手动切换', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    await tester.tap(_display);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Flutter 开发文档'));
    await tester.pumpAndSettle();
    expect(h.platform.controller.loadRequests.last, 'https://flutter.dev/');
    await h.finish(tester);
    await tester.tap(_display);
    await tester.pumpAndSettle();
    final history = find.ancestor(
      of: find.text('Dart 语言指南'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: history, matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_address).controller!.text,
      'https://dart.dev/',
    );
    expect(h.platform.controller.loads, 1);
    await tester.tap(find.byKey(const ValueKey('browser-search-engine')));
    await tester.pumpAndSettle();
    expect(find.text('默认搜索引擎'), findsOneWidget);
    await tester.tap(find.text('DuckDuckGo').last);
    await tester.pumpAndSettle();
    expect(h.preferences.getString('browser_search_engine'), 'duckDuckGo');
    await tester.enterText(_address, 'Dart 教程');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(
      Uri.parse(h.platform.controller.loadRequests.last).host,
      'duckduckgo.com',
    );
    await h.dispose(tester);
  });

  testWidgets('页内查找防抖、计数、前后匹配和退出后清理', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在网页中查找'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('browser-find-input'));
    await tester.enterText(input, 'F');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(input, 'Flutter');
    await tester.pump(const Duration(milliseconds: 219));
    expect(h.platform.findController!.queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(h.platform.findController!.queries, ['Flutter']);
    h.platform.findController!.result(1, 7);
    await tester.pump();
    expect(find.text('2/7'), findsOneWidget);
    await tester.tap(find.byTooltip('上一处'));
    await tester.tap(find.byTooltip('下一处'));
    expect(h.platform.findController!.directions, [false, true]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(h.platform.findController!.clears, 1);
    expect(find.byType(WebViewPage), findsOneWidget);
    await h.dispose(tester);
  });

  for (final layout in [
    (size: const Size(320, 640), scale: 1.6, reduceMotion: false),
    (size: const Size(390, 844), scale: 1.0, reduceMotion: true),
    (size: const Size(1200, 800), scale: 1.0, reduceMotion: false),
  ]) {
    testWidgets(
      '布局 ${layout.size} 字号 ${layout.scale} 减少动画 ${layout.reduceMotion}',
      (tester) async {
        final h = _Harness();
        await h.mount(
          tester,
          size: layout.size,
          textScale: layout.scale,
          reduceMotion: layout.reduceMotion,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(_display);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        expect(_address, findsOneWidget);
        expect(find.byType(BrowserBottomToolbar), findsNothing);
        expect(tester.takeException(), isNull);
        if (layout.size.width >= 840) {
          final capsule = tester.getRect(
            find.byKey(const ValueKey('browser-address-capsule')),
          );
          final current = tester.getRect(
            find.byKey(const ValueKey('browser-current-page')),
          );
          expect(capsule.left, closeTo(current.left, .1));
          expect(capsule.right, closeTo(current.right, .1));
        }
        tester.view.viewInsets = const FakeViewPadding();
        await tester.tap(find.byKey(const ValueKey('browser-leading')));
        await tester.pumpAndSettle();
        h.start(BrowserSearchEngine.google.search('测试').toString());
        h.fail();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('收起到底部'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(h.tabs.tabs.length, 1);
        await h.dispose(tester);
      },
    );
  }

  testWidgets('浏览器组件视觉预览', (tester) async {
    if (!const bool.fromEnvironment('BROWSER_PREVIEW')) return;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSansVF.ttf'))).load();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest) {
      if (!(entry['family'] as String).contains('Material')) continue;
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final h = _Harness();
      h.platform.controller.title = '让浏览更轻松';
      await h.mount(tester, brightness: brightness);
      await h.capture(tester, '${brightness.name}-page');
      await tester.tap(_display);
      await tester.pumpAndSettle();
      await h.capture(tester, '${brightness.name}-address');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.enterText(_address, 'Flutter 动画');
      await tester.pumpAndSettle();
      await h.capture(tester, '${brightness.name}-keyboard-inset');
      tester.view.viewInsets = const FakeViewPadding();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 13));
      await h.capture(tester, '${brightness.name}-slow-search');
      h.fail();
      await tester.pumpAndSettle();
      await h.capture(tester, '${brightness.name}-fallback');
      h.start(_url);
      await h.finish(tester);
      await h.prepareSnapshot(tester);
      await tester.tap(find.byTooltip('收起到底部'));
      await tester.pump();
      await tester.pump();
      for (var frame = 0; frame < 7; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
        await h.capture(tester, '${brightness.name}-minimize-$frame');
      }
      await tester.pumpAndSettle();
      final session = (await h.tabs.take(h.tabs.tabs.single))!;
      WebViewPage.restore(h.navigator.currentState!, session);
      await tester.pump();
      h.callbacks.onWebViewCreated!(h.platform.controller.wrapped);
      for (var frame = 0; frame < 11; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
        await h.capture(tester, '${brightness.name}-restore-$frame');
      }
      await tester.pumpAndSettle();
      await h.dispose(tester);
    }
    final desktop = _Harness();
    desktop.platform.controller.title = '让浏览更轻松';
    await desktop.mount(tester, size: const Size(1200, 800));
    await tester.tap(_display);
    await tester.pumpAndSettle();
    await desktop.capture(tester, 'desktop-address');
    expect(tester.takeException(), isNull);
    await desktop.dispose(tester);
    final narrow = _Harness();
    narrow.platform.controller.title = '让浏览更轻松';
    await narrow.mount(tester, size: const Size(320, 640), textScale: 1.6);
    await tester.tap(_display);
    await tester.pumpAndSettle();
    await narrow.capture(tester, 'narrow-address');
    await tester.tap(find.byKey(const ValueKey('browser-leading')));
    await tester.pumpAndSettle();
    narrow.start(BrowserSearchEngine.google.search('测试搜索').toString());
    await tester.pump(const Duration(seconds: 13));
    await narrow.capture(tester, 'narrow-slow-search');
    narrow.fail();
    await tester.pumpAndSettle();
    await narrow.capture(tester, 'narrow-fallback');
    expect(tester.takeException(), isNull);
    await narrow.dispose(tester);
  });
}

/// 仅替代测试中的原生网页内容；工具栏和动画使用真实生产组件。
class _PreviewArticle extends StatelessWidget {
  const _PreviewArticle();
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('阅读 · 设计', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 20),
        Text('让浏览更轻松', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 16),
        Text(
          '这是用于检查浏览器布局的示例文章。网页、地址栏与底部操作各有清晰的位置。',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 28),
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(
            Symbols.travel_explore_rounded,
            size: 88,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 28),
        Text('随时继续阅读', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const Text('点击右上角收起网页，稍后从底栏恢复。点击地址栏，即可输入网址或搜索关键词。'),
      ],
    ),
  );
}
