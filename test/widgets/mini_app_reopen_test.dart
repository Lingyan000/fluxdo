import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_engine.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_host_adapter.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runner_page.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runtime_surface.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_modal_blur.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_floating_controls.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_glass_backdrop.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_tab_session.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_providers.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_embed_card.dart';
import 'package:fluxdo/services/browser_tabs.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/navigation/browser_dock_observer.dart';
import 'package:fluxdo/widgets/browser/browser_dock_host.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/navigation/app_route_observer.dart';
import 'package:fluxdo/services/network/cookie/webview_cookie_priming.dart';
import 'package:fluxdo/utils/platform_utils.dart';

import '../support/cf_test_platform.dart';
import '../support/url_launcher_test_platform.dart';

const details = MiniAppDetails(
  MiniApp(
    id: '01a1b02d-04ed-7342-baa5-769b244b7b9a',
    name: '软块合成',
    version: '1',
  ),
  'https://linux.do/apps/01a1b02d-04ed-7342-baa5-769b244b7b9a?embed_mode=true',
  configuration: {'channel': 'production', 'releaseId': 1},
);

class _Me extends CurrentUserNotifier {
  @override
  User? build() => User(id: 2, username: 'me', trustLevel: 1);
}

class _Platform extends CfTestPlatform {
  bool probeNativeInput = false;
  final views = <_View>[];
  late _Controller current;
  int loads = 0;
  bool pendingSound = false;
  final kept = <InAppWebViewKeepAlive, _Controller>{};
  final released = <InAppWebViewKeepAlive>[];
  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      current;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    expect(params.initialSettings?.cacheEnabled, isTrue);
    current = params.keepAlive == null
        ? _Controller(this)
        : kept.putIfAbsent(params.keepAlive!, () => _Controller(this));
    current.viewParams = params;
    final view = _View(params, current);
    views.add(view);
    return view;
  }
}

class _View extends CfTestWebView {
  _View(super.params, this.controller);
  final _Controller controller;
  bool created = false;
  bool disposed = false;
  final input = _NativeInput();
  @override
  void dispose() {
    disposed = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!created) {
      created = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => params.onWebViewCreated!(controller.wrapped),
      );
    }
    if (!controller.owner.probeNativeInput) return const SizedBox.expand();
    // 用真正的平台手势代理验证派发时机，不再用 Flutter ListView 冒充 WebView。
    return GestureDetector(
      onVerticalDragUpdate: (_) {},
      child: PlatformViewSurface(
        controller: input,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        gestureRecognizers: params.gestureRecognizers ?? {},
      ),
    );
  }
}

class _NativeInput extends PlatformViewController {
  final events = <PointerEvent>[];
  @override
  int get viewId => 987;
  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async =>
      events.add(event);
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearFocus() async {}
}

class _Controller extends CfTestController {
  _Controller(this.owner) : super(owner.cookies);
  final _Platform owner;
  late PlatformInAppWebViewWidgetCreationParams viewParams;
  String url = 'about:blank';
  bool compatible = true;
  bool ready = false;
  bool failed = false;
  bool destroyed = false;
  String? html;
  Completer<Map<String, dynamic>>? snapshotGate;
  Uint8List? screenshot;
  Completer<Uint8List?>? screenshotGate;
  ScreenshotConfiguration? lastCaptureConfiguration;
  int captures = 0;
  int pauses = 0, resumes = 0;
  Completer<void>? pauseGate, hostSuspendGate;
  bool nativeSuspended = false, hostSuspended = false;
  Map<String, dynamic>? permission;
  Map<String, dynamic>? externalLink;
  bool linkClaimed = false;
  Completer<bool>? permissionGate;
  void Function(bool)? onPermissionAnswer;
  @override
  Future<Uint8List?> takeScreenshot({
    ScreenshotConfiguration? screenshotConfiguration,
  }) async {
    captures++;
    lastCaptureConfiguration = screenshotConfiguration;
    return screenshotGate == null ? screenshot : await screenshotGate!.future;
  }

  Completer<void>? cssGate;
  final soundProbe = Completer<CallAsyncJavaScriptResult?>();
  @override
  Future<WebUri?> getUrl() async => WebUri(url);
  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    WebUri? allowingReadAccessTo,
    Uri? iosAllowingReadAccessTo,
  }) async {
    owner.loads++;
    url = urlRequest.url.toString();
    ready = false;
    viewParams.onLoadStart!(wrapped, WebUri(url));
    if (viewParams.initialSettings?.useShouldInterceptRequest == true) {
      final response = await viewParams.shouldInterceptRequest!(
        wrapped,
        WebResourceRequest(
          url: WebUri(url),
          method: 'GET',
          isForMainFrame: true,
          headers: {'Sec-Fetch-Dest': 'document'},
        ),
      );
      html = response?.data == null ? null : utf8.decode(response!.data!);
    }
  }

  @override
  Future<void> loadData({
    required String data,
    String mimeType = 'text/html',
    String encoding = 'utf8',
    WebUri? baseUrl,
    WebUri? historyUrl,
    WebUri? allowingReadAccessTo,
    Uri? androidHistoryUrl,
    Uri? iosAllowingReadAccessTo,
  }) async {
    owner.loads++;
    html = data;
    url = baseUrl.toString();
    viewParams.onLoadStart!(wrapped, WebUri(url));
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.startsWith('window.fluxdoMiniAppHost?.setSuspended(')) {
      final suspend = source.contains('(true)');
      if (suspend) await hostSuspendGate?.future;
      hostSuspended = suspend;
      return null;
    }
    if (source == 'window.fluxdoMiniAppHost?.destroy();') {
      destroyed = true;
      return null;
    }
    if (source == MiniAppHostAdapter.clearExternalLinks) {
      externalLink = null;
      linkClaimed = false;
      return null;
    }
    if (externalLink case final link?) {
      if (source == MiniAppHostAdapter.takeExternalLink(link['id'] as String)) {
        if (linkClaimed) return false;
        linkClaimed = true;
        return true;
      }
      if (source ==
          MiniAppHostAdapter.finishExternalLink(link['id'] as String)) {
        externalLink = null;
        linkClaimed = false;
        return null;
      }
    }
    if (permission?['signature'] case final String signature) {
      if (source == MiniAppHostAdapter.permissionOperation(signature)) {
        return true;
      }
      for (final allow in [false, true]) {
        if (source ==
            MiniAppHostAdapter.permissionOperation(signature, allow: allow)) {
          onPermissionAnswer?.call(allow);
          return permissionGate == null ? true : permissionGate!.future;
        }
      }
    }
    if (source == MiniAppHostAdapter.snapshot && snapshotGate != null) {
      return snapshotGate!.future;
    }
    return {
      'compatible': compatible,
      'ready': ready,
      'loading': compatible && !ready,
      'muted': true,
      'failed': failed,
      'engineMounted': html != null,
      'webPermission': permission != null,
      'permission': permission,
      'externalLink': linkClaimed ? null : externalLink,
    };
  }

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const {},
    ContentWorld? contentWorld,
  }) async {
    if (owner.pendingSound) {
      return soundProbe.future;
    }
    return CallAsyncJavaScriptResult(value: {'available': true, 'muted': true});
  }

  @override
  Future<void> injectCSSCode({required String source}) async {
    await cssGate?.future;
  }

  @override
  Future<void> pause() async {
    pauses++;
    await pauseGate?.future;
    nativeSuspended = true;
  }

  @override
  Future<void> resume() async {
    resumes++;
    nativeSuspended = false;
  }

  @override
  Future<void> setAllMediaPlaybackSuspended({required bool suspended}) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      throw UnimplementedError();
    }
    return Future.value();
  }

  @override
  Future<void> setMuted({required bool muted}) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      throw UnimplementedError();
    }
    return Future.value();
  }

  @override
  Future<void> pauseAllMediaPlayback() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      throw UnimplementedError();
    }
    return Future.value();
  }

  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive keepAlive) async {
    owner.released.add(keepAlive);
    owner.kept.remove(keepAlive);
  }
}

void main() {
  for (final engine in MiniAppEngine.values) {
    testWidgets('官方授权后外链接续、导航竞态与过期取消 (${engine.name})', (tester) async {
      final platform = _Platform();
      final previous = InAppWebViewPlatform.instance;
      final previousLauncher = UrlLauncherPlatform.instance;
      final launcher = TestUrlLauncher();
      UrlLauncherPlatform.instance = launcher;
      InAppWebViewPlatform.instance = platform;
      PlatformUtils.debugDesktopOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        PlatformUtils.debugDesktopOverride = null;
        debugDefaultTargetPlatformOverride = null;
        UrlLauncherPlatform.instance = previousLauncher;
        if (previous != null) InAppWebViewPlatform.instance = previous;
      });
      SharedPreferences.setMockInitialValues({
        'pref_mini_app_engine': engine.name,
        'pref_open_external_links_in_app_browser': false,
        'pref_dialog_blur': false,
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.runAsync(() async {
        final folder = await Directory.systemTemp.createTemp(
          'mini-app-authorized-link-',
        );
        await platform.initialize(cookieDirectory: folder.path);
        await WebViewCookiePriming.instance.prime(details.embedUrl);
      });
      final id = details.app.id;
      final configuredDetails = MiniAppDetails(
        details.app,
        details.embedUrl,
        configuration: {
          ...details.configuration,
          'appId': id,
          'anonymous': false,
          'frameHostUrl': '/mini-app-api/frame-host',
          for (final action in ['launch', 'check', 'runtime', 'usage'])
            '${action}Url': '/mini-app-api/production/$id/$action',
          'httpAuthorizationUrl':
              '/mini-app-api/production/$id/http-authorization',
          'webSocketAuthorizationUrl':
              '/mini-app-api/production/$id/websocket-authorization',
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentUserProvider.overrideWith(_Me.new),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorObservers: [appRouteObserver],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: AppLocaleUtils.supportedLocales,
              home: MiniAppRunnerPage(details: configuredDetails),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final controller = platform.current;
      controller.ready = true;
      final callbacks = controller.viewParams;
      final navigationScript = callbacks.initialUserScripts!.singleWhere(
        (script) =>
            script.source ==
            MiniAppHostAdapter.navigationScript(Uri.parse(details.embedUrl)),
      );
      expect(navigationScript.forMainFrameOnly, isTrue);
      expect(
        navigationScript.injectionTime,
        UserScriptInjectionTime.AT_DOCUMENT_START,
      );
      await tester.pump(const Duration(milliseconds: 260));
      const url = 'https://hb.lafi.sh/tips';
      var serial = 0;
      Future<void> prompt({
        bool navigation = false,
        bool staleRead = false,
      }) async {
        controller.permission = {
          'signature': 'link-${++serial}',
          'title': '软块合成 请求操作',
          'action': '打开外部链接',
          'notice': url,
          'allow': '允许打开',
          'reject': '拒绝打开',
        };
        controller.permissionGate = Completer<bool>();
        controller.onPermissionAnswer = (allow) {
          // 对应官方按钮 click 内同步导航，早于 evaluateJavascript 的返回。
          if (navigation) {
            unawaited(
              Future<void>.sync(() async {
                await callbacks.shouldOverrideUrlLoading!(
                  controller.wrapped,
                  NavigationAction(
                    request: URLRequest(url: WebUri(url)),
                    isForMainFrame: true,
                    hasGesture: false,
                  ),
                );
              }),
            );
          } else if (allow) {
            controller.externalLink = {'id': 'link-$serial', 'url': url};
          }
        };
        await tester.pump(const Duration(milliseconds: 260));
        await tester.pumpAndSettle();
        expect(find.byType(MiniAppPermissionSurface), findsOneWidget);
        if (staleRead) {
          controller.snapshotGate = Completer<Map<String, dynamic>>();
          await tester.pump(const Duration(milliseconds: 260));
        }
      }

      Future<void> answer(bool allow, {bool accepted = true}) async {
        final oldPermission = controller.permission;
        await tester.tap(
          find.byKey(
            ValueKey('mini-app-permission-${allow ? 'allow' : 'reject'}'),
          ),
        );
        await tester.pump();
        expect(
          find.text(t.externalLink_openInSystemBrowser),
          findsNothing,
          reason: '原生授权回答仍在等待时不能丢请求或同时弹出离站确认',
        );
        controller.permission = null;
        controller.permissionGate!.complete(accepted);
        await tester.pump();
        if (controller.snapshotGate case final pending?) {
          controller.snapshotGate = null;
          pending.complete({
            'compatible': true,
            'ready': true,
            'webPermission': true,
            'permission': oldPermission,
          });
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 260));
        await tester.pumpAndSettle();
      }

      Future<void> confirm() async {
        expect(find.byType(MiniAppPermissionSurface), findsNothing);
        expect(find.text('hb.lafi.sh'), findsOneWidget);
        await tester.tap(find.text(t.externalLink_openInSystemBrowser));
        await tester.pumpAndSettle();
        expect(controller.url, details.embedUrl);
      }

      await prompt(staleRead: true);
      await answer(true);
      expect(launcher.opened, isEmpty);
      await confirm();
      expect(launcher.opened, [url]);

      await prompt();
      await answer(false);
      expect(find.text(t.externalLink_openInSystemBrowser), findsNothing);
      expect(launcher.opened, [url]);

      await prompt();
      await answer(true, accepted: false);
      expect(find.text(t.externalLink_openInSystemBrowser), findsNothing);
      expect(controller.externalLink, isNull);

      await prompt();
      await tester.tap(find.byKey(const ValueKey('mini-app-permission-allow')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(controller.externalLink, isNull, reason: '授权响应超时不保留待跳转链接');
      controller.permission = null;
      controller.permissionGate!.complete(true);
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(find.text(t.externalLink_openInSystemBrowser), findsNothing);

      await prompt(navigation: true);
      await answer(true);
      await confirm();
      expect(launcher.opened, [url, url]);

      await prompt(navigation: true);
      await answer(false);
      expect(find.text(t.externalLink_openInSystemBrowser), findsNothing);

      await prompt(navigation: true);
      await tester.tap(find.byKey(const ValueKey('mini-app-permission-allow')));
      await tester.pump();
      callbacks.onLoadStart!(controller.wrapped, WebUri(details.embedUrl));
      controller.permission = null;
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(find.text(t.externalLink_openInSystemBrowser), findsNothing);
      expect(launcher.opened, [url, url], reason: '刷新后的旧授权不能打开页面');
      await callbacks.shouldOverrideUrlLoading!(
        controller.wrapped,
        NavigationAction(
          request: URLRequest(url: WebUri(url)),
          isForMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(t.externalLink_openInSystemBrowser),
        findsOneWidget,
        reason: '新文档的主动导航不等待上一文档未结束的授权',
      );
      controller.permissionGate!.complete(true);
      await tester.pump();
      await confirm();
      expect(launcher.opened, [url, url, url]);
      expect(platform.loads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('小程序当前窗口和新窗口外链确认后启动，取消和返回立即恢复触摸', (tester) async {
    final platform = _Platform()..probeNativeInput = true;
    final previous = InAppWebViewPlatform.instance;
    final previousLauncher = UrlLauncherPlatform.instance;
    final launcher = TestUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
    InAppWebViewPlatform.instance = platform;
    PlatformUtils.debugDesktopOverride = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      PlatformUtils.debugDesktopOverride = null;
      debugDefaultTargetPlatformOverride = null;
      UrlLauncherPlatform.instance = previousLauncher;
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    SharedPreferences.setMockInitialValues({
      'pref_mini_app_engine': 'web',
      'pref_open_external_links_in_app_browser': false,
      'pref_dialog_blur': true,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('mini-app-links-');
      await platform.initialize(cookieDirectory: folder.path);
      await WebViewCookiePriming.instance.prime(details.embedUrl);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWith(_Me.new),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorObservers: [appRouteObserver],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const MiniAppRunnerPage(details: details),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final controller = platform.current;
    controller.ready = true;
    await tester.pump(const Duration(milliseconds: 260));
    final callbacks = controller.viewParams;
    const url = 'https://hb.lafi.sh/tips';
    Future<void> open(bool newWindow) async {
      final request = URLRequest(url: WebUri(url));
      if (newWindow) {
        expect(
          await callbacks.onCreateWindow!(
            controller.wrapped,
            CreateWindowAction(
              request: request,
              isForMainFrame: true,
              windowId: 1,
              hasGesture: true,
            ),
          ),
          isFalse,
        );
      } else {
        expect(
          await callbacks.shouldOverrideUrlLoading!(
            controller.wrapped,
            NavigationAction(
              request: request,
              isForMainFrame: true,
              hasGesture: true,
            ),
          ),
          NavigationActionPolicy.CANCEL,
        );
      }
    }

    for (final newWindow in [false, true]) {
      for (final confirm in [false, true]) {
        final before = launcher.opened.length;
        // 同一跳转可能触发多次回调，只允许一个确认和一次打开。
        await open(newWindow);
        await open(newWindow);
        await tester.pumpAndSettle();
        expect(find.text('hb.lafi.sh'), findsOneWidget);
        expect(launcher.opened.length, before);
        await tester.tap(
          find.text(
            confirm ? t.externalLink_openInSystemBrowser : t.common_cancel,
          ),
        );
        await tester.pumpAndSettle();
        expect(launcher.opened.length, before + (confirm ? 1 : 0));
        expect(launcher.queries, 0);
        expect(find.text('hb.lafi.sh'), findsNothing);
        final input = platform.views.last.input;
        input.events.clear();
        final touch = await tester.startGesture(
          tester.getCenter(find.byType(InAppWebView)),
        );
        await touch.moveBy(const Offset(0, 80));
        await tester.pump();
        expect(input.events.whereType<PointerMoveEvent>(), isNotEmpty);
        await touch.up();
        expect(controller.url, details.embedUrl, reason: '离站网页不能替换应用运行时');
      }
    }
    expect(launcher.opened, [url, url]);
    expect(platform.loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final desktop in [false, true]) {
    testWidgets('帖子弹窗收起恢复、切到完整页不重载、关闭销毁和账号清理 ($desktop)', (tester) async {
      final platform = _Platform();
      platform.probeNativeInput = true;
      final previous = InAppWebViewPlatform.instance;
      InAppWebViewPlatform.instance = platform;
      PlatformUtils.debugDesktopOverride = desktop;
      addTearDown(() {
        PlatformUtils.debugDesktopOverride = null;
        if (previous != null) InAppWebViewPlatform.instance = previous;
      });
      SharedPreferences.setMockInitialValues({'pref_mini_app_engine': 'web'});
      final prefs = await SharedPreferences.getInstance();
      final tabs = BrowserTabsController();
      final observer = BrowserDockObserver();
      final nav = GlobalKey<NavigatorState>();
      await tester.runAsync(() async {
        final folder = await Directory.systemTemp.createTemp('mini-app-tabs-');
        await platform.initialize(cookieDirectory: folder.path);
        await WebViewCookiePriming.instance.prime(details.embedUrl);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentUserProvider.overrideWith(_Me.new),
            miniAppDetailsProvider(details.app.id)
                .overrideWith((_) async => details),
            browserTabsProvider.overrideWithValue(tabs),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: nav,
              navigatorObservers: [observer, appRouteObserver],
              builder: (context, child) => BrowserDockHost(
                controller: tabs,
                observer: observer,
                child: child!,
                onRestore: (session) => MiniAppRunnerPage.restore(
                  nav.currentState!,
                  session as MiniAppTabSession,
                ),
              ),
              home: Scaffold(
                body: MiniAppEmbedCard(url: '${details.embedUrl}&room=42'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> settleRuntime() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        platform.current.ready = true;
        await tester.pump(const Duration(milliseconds: 260));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text(t.miniApp_open));
      await settleRuntime();
      expect(platform.loads, 1);
      expect(platform.current.url, contains('room=42'));
      final original = platform.current;
      Future<void> scrollBothWays() async {
        final input = platform.views.last.input;
        for (final dy in [-100.0, 100.0, -50.0, 50.0]) {
          input.events.clear();
          final touch = await tester.startGesture(
            tester.getCenter(find.byType(InAppWebView)),
          );
          await touch.moveBy(Offset(0, dy));
          await tester.pump(const Duration(milliseconds: 16));
          expect(input.events.whereType<PointerDownEvent>(), hasLength(1));
          expect(
            input.events.whereType<PointerMoveEvent>(),
            isNotEmpty,
            reason: '手指尚未抬起时必须已经派发到原生网页，不能等待外层手势',
          );
          await touch.up();
        }
      }

      await scrollBothWays();
      if (!desktop) {
        final pauses = original.pauses, resumes = original.resumes;
        // 原生 select/日期弹层只使窗口失焦；不能暂停网页或强制恢复焦点。
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(original.pauses, pauses);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(original.resumes, resumes);
        await scrollBothWays();
        // 真正退后台仍应暂停，回到前台恢复一次。
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 300));
        expect(original.pauses, pauses + 1);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(original.resumes, resumes + 1);

        // 原生 pause 回执晚于旧逻辑的 200ms 超时，恢复必须排在它之后。
        original.pauseGate = Completer<void>();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 600));
        final beforeResume = original.resumes;
        original.pauseGate!.complete();
        await tester.pump();
        expect(original.resumes, beforeResume + 1);
        expect(original.nativeSuspended, isFalse);
        original.pauseGate = null;
        await scrollBothWays();

        // 网页静音脚本很慢时，原生先正常恢复；旧脚本回执不能补发 pause。
        original.hostSuspendGate = Completer<void>();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(original.nativeSuspended, isFalse);
        final beforeLateHost = original.pauses;
        original.hostSuspendGate!.complete();
        await tester.pump();
        expect(original.pauses, beforeLateHost);
        expect(original.hostSuspended, isFalse);
        original.hostSuspendGate = null;

        // 原生菜单的开关不重复暂停/恢复，退场后网页立即接收双向拖动。
        final beforeMenu = (original.pauses, original.resumes);
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
          await tester.pumpAndSettle();
          final input = platform.views.last.input;
          input.events.clear();
          await tester.drag(
            find.byType(InAppWebView),
            const Offset(0, -60),
            warnIfMissed: false,
          );
          expect(input.events, isEmpty, reason: '菜单打开时不能穿透触摸');
          nav.currentState!.pop();
          await tester.pumpAndSettle();
          await scrollBothWays();
        }
        expect((original.pauses, original.resumes), beforeMenu);

        // 普通页面覆盖与系统后台状态叠加，pop 不能恢复仍在后台的实例。
        original.hostSuspendGate = Completer<void>();
        final route = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('覆盖小程序的页面')),
        );
        unawaited(nav.currentState!.push(route));
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        nav.currentState!.pop();
        await tester.pumpAndSettle();
        expect(original.nativeSuspended, isTrue);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(original.nativeSuspended, isFalse);
        original.hostSuspendGate!.complete();
        await tester.pump();
        original.hostSuspendGate = null;
        expect(original.nativeSuspended, isFalse);
        expect(original.hostSuspended, isFalse);
        await scrollBothWays();

        // 带未完成暂停收起实例，再挂载到新页面对象时仍共用原生执行顺序。
        original.pauseGate = Completer<void>();
      }
      final token = platform.views.first.params.keepAlive!;
      expect(observer.currentRoute, isA<PopupRoute>());
      expect(observer.hidden.value, isTrue);
      await tester.tap(find.byKey(const ValueKey('mini-app-minimize')));
      await tester.pump();
      expect(tabs.tabs, hasLength(1));
      final saved = tabs.tabs.single;
      var detached = false;
      saved.whenDetached.then((_) => detached = true);
      expect(detached, isFalse, reason: '退出动画期间不能同时挂载两次');
      await tester.pumpAndSettle();
      expect(detached, isTrue);
      expect(find.byType(MiniAppRunnerPage), findsNothing);
      expect(find.text(t.miniApp_resumePanel), findsOneWidget);
      expect(platform.released, isEmpty);
      expect(observer.hidden.value, isFalse);
      Future<void> restoreFromDock() async {
        if (desktop) {
          await tester.tap(
            find
                .descendant(
                  of: find.byType(BrowserDockHost),
                  matching: find.text(details.app.name),
                )
                .last,
          );
          return;
        }
        final area = find.byKey(const ValueKey('browser-restore-drag-area'));
        for (final cancelPointer in [true, false]) {
          final drag = await tester.startGesture(tester.getCenter(area));
          await drag.moveBy(const Offset(0, -24));
          await tester.pump();
          await drag.moveBy(const Offset(0, -80));
          await tester.pump();
          final runner = find.byType(MiniAppRunnerPage);
          final y = tester.getTopLeft(runner).dy;
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            tester.getTopLeft(runner).dy,
            closeTo(y, .1),
            reason: '手指停下时页面也必须停下',
          );
          await drag.moveBy(const Offset(0, -30));
          await tester.pump();
          expect(
            tester.getTopLeft(runner).dy,
            closeTo(y - 30, 1),
            reason: '弹窗和完整页都按手指实际位移跟随',
          );
          if (cancelPointer) {
            await drag.cancel();
          } else {
            await drag.moveBy(const Offset(0, 100));
            await tester.pump(const Duration(milliseconds: 200));
            await drag.up();
          }
          await tester.pumpAndSettle();
          expect(tabs.tabs, [saved]);
          expect(saved.isClosed, isFalse);
          expect(nav.currentState!.userGestureInProgress, isFalse);
          expect(platform.loads, 1);
        }
        // 快速甩动可能在路由绑定回调前抬手，仍要正确完成恢复。
        await tester.fling(area, const Offset(0, -180), 1400);
        await tester.pumpAndSettle();
        expect(tabs.tabs, isEmpty);
        expect(nav.currentState!.userGestureInProgress, isFalse);
      }

      await restoreFromDock();
      await settleRuntime();
      if (!desktop) {
        original.pauseGate!.complete();
        await tester.pump();
        original.pauseGate = null;
        expect(original.nativeSuspended, isFalse, reason: '旧页面暂停晚到不能覆盖恢复');
        await scrollBothWays();
      }
      expect(platform.current, same(original));
      expect(platform.loads, 1);
      expect(platform.views.last.params.keepAlive, same(token));
      expect(tabs.tabs, isEmpty);
      expect(observer.currentRoute, isA<PopupRoute>());
      await tester.tap(find.byKey(const ValueKey('mini-app-open-page')));
      await settleRuntime();
      await tester.pumpAndSettle();
      expect(observer.currentRoute, isA<PageRoute>());
      expect(find.byKey(const ValueKey('mini-app-minimize')), findsNothing);
      expect(find.byKey(const ValueKey('mini-app-open-page')), findsNothing);
      expect(platform.current, same(original));
      expect(platform.loads, 1, reason: '弹窗切页面保留当前游戏');
      await scrollBothWays();
      expect(platform.views.last.params.keepAlive, same(token));
      expect(platform.released, isEmpty);
      expect(tabs.tabs, isEmpty, reason: '切页面不能额外创建收起条目');
      await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.miniApp_collapsePanel));
      await tester.pumpAndSettle();
      expect(tabs.tabs, hasLength(1), reason: '完整页仍可从菜单主动收起');
      await restoreFromDock();
      await settleRuntime();
      expect(observer.currentRoute, isA<PageRoute>(), reason: '底栏保留最后的展示形式');
      expect(platform.current, same(original));
      expect(platform.loads, 1);
      expect(find.byKey(const ValueKey('mini-app-minimize')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mini-app-close')));
      await tester.pumpAndSettle();
      expect(platform.released, [token]);
      expect(find.text(t.miniApp_resumePanel), findsNothing);
      await tester.tap(find.text(t.miniApp_open));
      await settleRuntime();
      expect(platform.current, isNot(same(original)));
      expect(platform.loads, 2);
      await tester.tap(find.byKey(const ValueKey('mini-app-minimize')));
      await tester.pumpAndSettle();
      expect(tabs.tabs, hasLength(1));
      AuthSession().advance();
      await tester.pumpAndSettle();
      expect(tabs.tabs, isEmpty);
      expect(platform.released, hasLength(2));
      expect(find.text(t.miniApp_resumePanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      tabs.dispose();
    });
  }

  testWidgets('Android 菜单立即打开，慢帧启用统一模糊；开关关闭不取帧且不重建网页', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final platform = _Platform();
    final previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = platform;
    PlatformUtils.debugDesktopOverride = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      PlatformUtils.debugDesktopOverride = null;
      debugDefaultTargetPlatformOverride = null;
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    SharedPreferences.setMockInitialValues({
      'pref_mini_app_engine': 'web',
      'pref_dialog_blur': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final nav = GlobalKey<NavigatorState>();
    final preview = GlobalKey();
    await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('mini-app-blur-');
      await platform.initialize(cookieDirectory: folder.path);
      await WebViewCookiePriming.instance.prime(details.embedUrl);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWith(_Me.new),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: nav,
            builder: (_, child) => RepaintBoundary(key: preview, child: child!),
            navigatorObservers: [appRouteObserver],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const MiniAppRunnerPage(details: details),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final controller = platform.current;
    controller.ready = true;
    await tester.pump(const Duration(milliseconds: 260));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.green, ui.BlendMode.src);
    final picture = recorder.endRecording();
    controller.screenshot = await tester.runAsync(() async {
      final image = await picture.toImage(40, 80);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    });
    final frame = find.descendant(
      of: find.byType(MiniAppModalFrame),
      matching: find.byType(RawImage),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();
    final keyboardSize = tester.getSize(find.byType(InAppWebView));
    controller.screenshotGate = Completer<Uint8List?>();
    // 在真实异步区发起解码链，但保持截图挂起，避免用等待时长模拟成功。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
    });
    await tester.pumpAndSettle();
    expect(find.text(t.miniApp_info), findsOneWidget, reason: '截图未到菜单已可操作');
    await tester.pump(const Duration(milliseconds: 500));
    expect(frame, findsNothing);
    expect(find.byType(BackdropFilter), findsNothing, reason: '不能仅模糊顶栏');
    // 开菜单后键盘收起，首帧仍是旧尺寸。重试必须取新的尺寸，而非永久拒绝。
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    final blur = tester
        .widget<MiniAppModalFrame>(find.byType(MiniAppModalFrame))
        .blur;
    controller.screenshotGate!.complete(controller.screenshot);
    // 退避计时器走测试时钟，图像解码走真实异步区，同时推进到有效帧到达。
    for (var i = 0; i < 20 && !blur.value; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(frame, findsOneWidget);
    expect(
      find.byType(BackdropFilter),
      findsNothing,
      reason: '原生页面的合成图直接用 ImageFiltered，公共弹层不能再拆层取背景',
    );
    expect(
      find.descendant(
        of: find.byType(MiniAppModalFrame),
        matching: find.byType(ImageFiltered),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(frame),
      const Size(390, 844),
      reason: '模糊底图必须覆盖顶栏和正文，不能只在 WebView 内拼接',
    );
    await tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final shot = await boundary.toImage();
      final pixels = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
      // 顶栏底部 y=56 两侧必须连续，避免平台视图边界形成硬接缝。
      int channel(int y, int c) =>
          pixels!.getUint8((y * shot.width + 200) * 4 + c);
      for (var y = 52; y < 61; y++) {
        for (var c = 0; c < 3; c++) {
          expect((channel(y, c) - channel(y - 1, c)).abs(), lessThan(15));
        }
      }
      const directory = String.fromEnvironment('MINI_APP_PREVIEW_DIR');
      if (directory.isNotEmpty) {
        await Directory(directory).create(recursive: true);
        final png = await shot.toByteData(format: ui.ImageByteFormat.png);
        await File('$directory/modal-continuous.png')
            .writeAsBytes(png!.buffer.asUint8List());
      }
      shot.dispose();
    });
    expect(controller.captures, 2, reason: '丢弃键盘收起前的画面，重新取得有效帧');
    expect(
      controller.lastCaptureConfiguration?.compressFormat,
      CompressFormat.JPEG,
    );
    expect(
      controller.lastCaptureConfiguration!.snapshotWidth! *
          tester.view.devicePixelRatio,
      lessThanOrEqualTo(360),
    );
    final beforeReload = tester.widget<RawImage>(frame).image!;
    controller.screenshotGate = Completer<Uint8List?>();
    controller.viewParams.onLoadStart!(
      controller.wrapped,
      WebUri(controller.url),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(blur.value, isTrue, reason: '弹层期间网页重新加载，也保留当前模糊');
    expect(tester.widget<RawImage>(frame).image, same(beforeReload));
    controller.screenshotGate!.complete(controller.screenshot);
    for (var i = 0; i < 20 && identical(blur.image, beforeReload); i++) {
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
    expect(controller.captures, 3);
    expect(blur.image, isNot(same(beforeReload)));
    expect(beforeReload.debugDisposed, isTrue);
    final captured = tester.widget<RawImage>(frame).image!;
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(frame, findsOneWidget, reason: '退场中仍使用同一画面');
    await tester.pumpAndSettle();
    // 截图解码在真实异步区执行，弹层完成后也要排空该区的 continuation。
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(frame, findsNothing);
    expect(captured.debugDisposed, isTrue);
    expect(
      tester.getSize(find.byType(InAppWebView)).height,
      keyboardSize.height + 200,
    );
    expect(platform.views, hasLength(1));
    await ProviderScope.containerOf(
      tester.element(find.byType(MiniAppRunnerPage)),
    ).read(preferencesProvider.notifier).setDialogBlur(false);
    await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
    await tester.pumpAndSettle();
    expect(controller.captures, 3, reason: '关闭模糊完全跳过取帧');
    expect(find.byType(BackdropFilter), findsNothing);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    await ProviderScope.containerOf(
      tester.element(find.byType(MiniAppRunnerPage)),
    ).read(preferencesProvider.notifier).setDialogBlur(true);
    controller.screenshotGate = null;
    controller.screenshot = null;
    await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(controller.captures, greaterThanOrEqualTo(6), reason: '空帧持续退避重试');
    expect(find.text(t.miniApp_info), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing, reason: '失败后不独自模糊工具栏');
    expect(frame, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 全屏玻璃只捕获控件区域，收回后改用低频取色', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final previous = InAppWebViewPlatform.instance;
    final platform = _Platform();
    InAppWebViewPlatform.instance = platform;
    PlatformUtils.debugDesktopOverride = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      PlatformUtils.debugDesktopOverride = null;
      debugDefaultTargetPlatformOverride = null;
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    SharedPreferences.setMockInitialValues({'pref_mini_app_engine': 'web'});
    final prefs = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('mini-app-dock-');
      await platform.initialize(cookieDirectory: folder.path);
      await WebViewCookiePriming.instance.prime(details.embedUrl);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWith(_Me.new),
        ],
        child: TranslationProvider(
          child: MaterialApp(home: const MiniAppRunnerPage(details: details)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final controller = platform.current;
    controller.ready = true;
    await tester.pump(const Duration(milliseconds: 260));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.green, ui.BlendMode.src);
    final picture = recorder.endRecording();
    controller.screenshot = await tester.runAsync(() async {
      final image = await picture.toImage(40, 20);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return bytes!.buffer.asUint8List();
    });
    await tester.tap(find.byKey(const ValueKey('mini-app-fullscreen')));
    await tester.pumpAndSettle();
    final dock = tester.widget<MiniAppFullscreenDock>(
      find.byType(MiniAppFullscreenDock),
    );
    MiniAppGlassFrame? patch;
    for (var i = 0; i < 10 && patch == null; i++) {
      await tester.pump(const Duration(milliseconds: 150));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      patch = await tester.runAsync<MiniAppGlassFrame?>(
        () => dock.captureBackdrop!(const Rect.fromLTWH(250, 200, 180, 80)),
      );
    }
    expect(patch, isNotNull);
    expect(patch!.globalBounds.right, lessThanOrEqualTo(390));
    expect(
      controller.lastCaptureConfiguration!.rect!.width,
      lessThanOrEqualTo(180),
    );
    expect(controller.lastCaptureConfiguration!.rect!.height, 80);
    expect(
      controller.lastCaptureConfiguration!.snapshotWidth! * 2,
      lessThanOrEqualTo(220),
    );
    patch.image.dispose();
    // 真正展开后，慢取样不挡住按钮，且不会生成全屏的截图覆盖层。
    controller.screenshotGate = Completer<Uint8List?>();
    await tester.tap(find.byKey(const ValueKey('mini-app-show-controls')));
    await tester.pumpAndSettle();
    expect(find.byType(MiniAppGlassBackdrop), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mini-app-fullscreen-exit')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(MiniAppModalFrame),
        matching: find.byType(RawImage),
      ),
      findsNothing,
    );
    final captureCount = controller.captures;
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.captures, captureCount);
    await tester.tapAt(const Offset(100, 600));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MiniAppGlassBackdrop>(find.byType(MiniAppGlassBackdrop))
          .showBackdrop,
      isFalse,
    );
    controller.screenshotGate!.complete(null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('轻量引擎切换销毁旧页面，隔离迟到回调，失败可切回网页且不改默认偏好', (tester) async {
    final platform = _Platform();
    final previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = platform;
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() {
      PlatformUtils.debugDesktopOverride = null;
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    SharedPreferences.setMockInitialValues({
      'pref_mini_app_engine': 'lightweight',
    });
    final prefs = await SharedPreferences.getInstance();
    final id = details.app.id;
    final lightDetails = MiniAppDetails(
      details.app,
      details.embedUrl,
      configuration: {
        ...details.configuration,
        'appId': id,
        'anonymous': false,
        'frameHostUrl': '/mini-app-api/frame-host',
        for (final action in ['launch', 'check', 'runtime', 'usage'])
          '${action}Url': '/mini-app-api/production/$id/$action',
        'httpAuthorizationUrl':
            '/mini-app-api/production/$id/http-authorization',
        'webSocketAuthorizationUrl':
            '/mini-app-api/production/$id/websocket-authorization',
      },
    );
    await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('mini-app-engine-');
      await platform.initialize(cookieDirectory: folder.path);
      await WebViewCookiePriming.instance.prime(details.embedUrl);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWith(_Me.new),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorObservers: [appRouteObserver],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: MiniAppRunnerPage(details: lightDetails),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(platform.current.html, contains('data-fluxdo-engine="lightweight"'));
    platform.current.ready = true;
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();
    final first = platform.current;
    // 保持旧快照等待，验证新文档不被旧轮询阻塞。
    first.snapshotGate = Completer<Map<String, dynamic>>();
    await tester.pump(const Duration(milliseconds: 260));

    first.viewParams.onReceivedError!(
      first.wrapped,
      WebResourceRequest(url: WebUri(first.url), isForMainFrame: true),
      WebResourceError(type: WebResourceErrorType.UNKNOWN, description: '启动失败'),
    );
    await tester.pump();
    await tester.tap(find.text(t.miniApp_engineFallback));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(first.destroyed, isTrue);
    expect(platform.views.first.disposed, isTrue);
    expect(platform.loads, 2);
    expect(platform.current.html, isNull);
    platform.current.ready = true;
    await tester.pump(const Duration(milliseconds: 260));
    expect(
      find.byType(MiniAppLaunchSurface),
      findsNothing,
      reason: '新的文档不能等待旧页面的状态查询结束',
    );
    first.snapshotGate!.complete({'compatible': true, 'failed': true});
    first.viewParams.onLoadStart!(first.wrapped, WebUri(first.url));
    first.viewParams.onLoadStop!(first.wrapped, WebUri(first.url));
    await tester.pump();
    expect(find.byType(MiniAppLaunchSurface), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
    await tester.pumpAndSettle();
    expect(find.text(t.miniApp_engine), findsNothing, reason: '运行菜单不再提供引擎选择');
    expect(
      prefs.getString('pref_mini_app_engine'),
      MiniAppEngine.lightweight.name,
      reason: '当前实例的切换不改写设置中的默认引擎',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(platform.views.every((view) => view.disposed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭销毁页面，重开使用新实例；资源缓存开启且就绪不等待 loadStop 或声音探测', (tester) async {
    final platform = _Platform();
    final previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = platform;
    addTearDown(() {
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWith(_Me.new),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: nav,
            navigatorObservers: [appRouteObserver],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const Scaffold(),
          ),
        ),
      ),
    );
    Future<void> open(MiniAppDetails app) async {
      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => MiniAppRunnerPage(
              details: app,
              initialEngine: MiniAppEngine.web,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
    }

    // 避免本测试访问真实 Cookie，同步阶段直接复用测试平台空存储。
    await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('mini-app-reopen-');
      await platform.initialize(cookieDirectory: folder.path);
      await WebViewCookiePriming.instance.prime(details.embedUrl);
    });
    await open(details);
    expect(platform.loads, 1);
    platform.pendingSound = true;
    platform.current.ready = true;
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    expect(
      find.byType(MiniAppLaunchSurface),
      findsNothing,
      reason: '未触发 onLoadStop，宿主已就绪也必须撤下遮罩',
    );
    // 声音菜单探测慢时也不能继续遮住已经启动的应用。
    platform.pendingSound = false;
    await tester.pump();
    final first = platform.current;
    final firstView = platform.views.single;
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(firstView.disposed, isTrue);
    await open(details);
    expect(platform.current, isNot(same(first)));
    expect(platform.loads, 2, reason: '资源缓存不等于页面保活，每次重新导航与授权');
    expect(platform.current.ready, isFalse);
    expect(find.byType(MiniAppLaunchSurface), findsOneWidget);
    // 已关闭页面的声音结果迟到，也不能改变新实例或继续操作旧视图。
    first.soundProbe.complete(
      CallAsyncJavaScriptResult(value: {'available': true, 'muted': false}),
    );
    await tester.pump();
    expect(find.byType(MiniAppLaunchSurface), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 上一份文档的 loadStop 延迟完成，不能撤掉新文档的加载遮罩。
    final second = platform.current;
    second.cssGate = Completer<void>();
    second.viewParams.onLoadStop!(second.wrapped, WebUri(second.url));
    await tester.pump();
    second.compatible = false;
    second.viewParams.onLoadStart!(second.wrapped, WebUri(second.url));
    await tester.pump();
    second.cssGate!.complete();
    await tester.pump();
    expect(find.byType(MiniAppLaunchSurface), findsOneWidget);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    await open(
      MiniAppDetails(
        details.app,
        details.embedUrl,
        configuration: {'channel': 'production', 'releaseId': 2},
      ),
    );
    expect(platform.current, isNot(same(first)));
    expect(platform.loads, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(platform.views.every((view) => view.disposed), isTrue);
    await tester.pump();
    await tester.pump();
  });
}
