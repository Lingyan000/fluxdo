import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_engine.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_host_adapter.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_host_events.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runtime_cache.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runner_page.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_tab_session.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_window_session.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

const _id = '01a1b3ac-b68b-7d49-883d-51d49c784168';
final _entry = Uri.parse('https://linux.do/apps/$_id?embed_mode=true');
final _details = MiniAppDetails(
  const MiniApp(id: _id, name: 'Test'),
  _entry.toString(),
);
const _ready = {
  'compatible': true,
  'engineMounted': true,
  'ready': true,
  'loading': false,
  'muted': true,
  'soundAvailable': true,
};

class _Guest extends CurrentUserNotifier {
  @override
  User? build() => null;
}

class _Platform extends CfTestPlatform {
  late final _controller = _Controller(cookies);
  @override
  _Controller get controller => _controller;

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      controller;
}

class _Controller extends CfTestController {
  _Controller(super.cookies);
  Completer<Object?>? pending;
  int reads = 0;
  bool eventsEnabled = false;
  Map installedState = _ready;
  String? eventToken;
  int soundProbes = 0;

  Future<Object?> readRuntime() async => handlers[MiniAppRuntimeCache.handler]!(
    JavaScriptHandlerFunctionData(
      isMainFrame: true,
      origin: WebUri('https://linux.do'),
      requestUrl: WebUri(_entry.toString()),
      args: [
        {'action': 'read', 'hash': 'a' * 64},
      ],
    ),
  );

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const {},
    ContentWorld? contentWorld,
  }) async {
    soundProbes++;
    return CallAsyncJavaScriptResult(value: {'available': true, 'muted': true});
  }

  bool sendState(
    Map state, {
    int sequence = 1,
    String? token,
    bool mainFrame = true,
    String origin = 'https://linux.do',
    String? requestUrl,
  }) {
    final callback = handlers[MiniAppHostEvents.handler]!;
    return callback(
      JavaScriptHandlerFunctionData(
        isMainFrame: mainFrame,
        origin: WebUri(origin),
        requestUrl: WebUri(requestUrl ?? _entry.toString()),
        args: [
          {'token': token ?? eventToken, 'sequence': sequence, 'state': state},
        ],
      ),
    ) as bool;
  }

  @override
  Future<WebUri?> getUrl() async => WebUri(_entry.toString());

  @override
  Future<void> injectCSSCode({required String source}) async {}

  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive keepAlive) async {}

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (eventsEnabled && source.contains('const token = ')) {
      eventToken = RegExp('const token = "([^"]+)"')
          .firstMatch(source)!
          .group(1);
      return installedState;
    }
    if (source == MiniAppHostAdapter.snapshot) {
      reads++;
      return pending == null ? _ready : pending!.future;
    }
    return super.evaluateJavascript(source: source, contentWorld: contentWorld);
  }
}

class _RefreshPlatform extends _Platform {
  late _RefreshController _current = _RefreshController(cookies);
  final views = <CfTestWebView>[];
  @override
  _RefreshController get controller => _current;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    _current = _RefreshController(cookies)..viewParams = params;
    final view = webView = CfTestWebView(params);
    views.add(view);
    return view;
  }
}

class _RefreshController extends _Controller {
  _RefreshController(super.cookies) {
    eventsEnabled = true;
  }
  late PlatformInAppWebViewWidgetCreationParams viewParams;
  final released = <InAppWebViewKeepAlive>[];
  bool stopped = false;
  WebUri? loadedUrl;
  String? html;

  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive keepAlive) async {
    released.add(keepAlive);
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.startsWith('window.fluxdoMiniAppEvents?.dispose();')) {
      stopped = true;
      return null;
    }
    return super.evaluateJavascript(source: source, contentWorld: contentWorld);
  }

  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    WebUri? allowingReadAccessTo,
    Uri? iosAllowingReadAccessTo,
  }) async {
    loadedUrl = urlRequest.url;
    viewParams.onLoadStart!(wrapped, loadedUrl);
    if (viewParams.initialSettings?.useShouldInterceptRequest == true) {
      final response = await viewParams.shouldInterceptRequest!(
        wrapped,
        WebResourceRequest(
          url: loadedUrl!,
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
    html = data;
    loadedUrl = baseUrl;
    viewParams.onLoadStart!(wrapped, loadedUrl);
  }
}

void main() {
  for (final engine in MiniAppEngine.values) {
    for (final desktop in [false, true]) {
      testWidgets('菜单刷新重新进入当前引擎并保留启动参数 (${engine.name}, $desktop)', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({
          'pref_dialog_blur': false,
          'pref_mini_app_engine': MiniAppEngine.web.name,
        });
        final prefs = await SharedPreferences.getInstance();
        final previousPlatform = InAppWebViewPlatform.instance;
        final previousSession = MiniAppWindowSession.current;
        final platform = _RefreshPlatform();
        InAppWebViewPlatform.instance = platform;
        PlatformUtils.debugDesktopOverride = desktop;
        var primes = 0;
        MiniAppWindowSession.current = MiniAppWindowSession((
          method,
          args,
        ) async {
          if (method == 'prime') primes++;
          return null;
        });
        addTearDown(() {
          PlatformUtils.debugDesktopOverride = null;
          MiniAppWindowSession.current = previousSession;
          if (previousPlatform != null) {
            InAppWebViewPlatform.instance = previousPlatform;
          }
        });
        final entry = Uri.parse('$_entry&room=42');
        final details = MiniAppDetails(
          _details.app,
          _entry.toString(),
          configuration: {
            'appId': _id,
            'channel': 'production',
            'anonymous': true,
            'frameHostUrl': '/mini-app-api/frame-host',
            for (final action in ['launch', 'check', 'runtime', 'usage'])
              '${action}Url': '/mini-app-api/production/$_id/$action',
            'httpAuthorizationUrl':
                '/mini-app-api/production/$_id/http-authorization',
            'webSocketAuthorizationUrl':
                '/mini-app-api/production/$_id/websocket-authorization',
          },
        );
        final session =
            MiniAppTabSession(details: details, entry: entry, engine: engine)
              ..initialLoadRequested = true
              ..recorded = true;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              currentUserProvider.overrideWith(_Guest.new),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                theme: ThemeData(extensions: const [M3eFlags()]),
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: AppLocaleUtils.supportedLocales,
                home: MiniAppRunnerPage(
                  details: details,
                  launchUri: entry,
                  tabSession: session,
                  initialEngine: engine,
                  independentWindow: desktop,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final previous = platform.controller;
        final firstView = platform.views.single;
        firstView.params.onWebViewCreated!(previous.wrapped);
        await tester.pumpAndSettle();
        expect(primes, 0);
        await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('刷新'));
        await tester.tap(find.text('刷新'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(platform.views, hasLength(2));
        expect(previous.stopped, true);
        expect(previous.released, [firstView.params.keepAlive]);
        expect(previous.sendState(_ready), false, reason: '重启后的旧文档回调失效');
        final current = platform.controller;
        expect(current, isNot(same(previous)));
        expect(
          platform.views.last.params.keepAlive,
          isNot(firstView.params.keepAlive),
        );
        platform.views.last.params.onWebViewCreated!(current.wrapped);
        await tester.pumpAndSettle();
        expect(primes, 1);
        expect(current.loadedUrl.toString(), entry.toString());
        expect(current.html != null, engine == MiniAppEngine.lightweight);
        expect(session.engine, engine);
        expect(prefs.getString('pref_mini_app_engine'), MiniAppEngine.web.name);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }

  for (final engine in MiniAppEngine.values) {
    testWidgets('两套引擎共用状态事件，慢速兜底与旧文档隔离 (${engine.name})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _Platform();
      platform.controller.eventsEnabled = true;
      platform.controller.installedState = {
        ..._ready,
        'ready': false,
        'loading': true,
        'stage': '首屏绘制',
      };
      InAppWebViewPlatform.instance = platform;
      PlatformUtils.debugDesktopOverride = false;
      addTearDown(() {
        PlatformUtils.debugDesktopOverride = null;
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
      });
      final session =
          MiniAppTabSession(details: _details, entry: _entry, engine: engine)
            ..initialLoadRequested = true
            ..recorded = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentUserProvider.overrideWith(_Guest.new),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(extensions: const [M3eFlags()]),
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocaleUtils.supportedLocales,
              home: MiniAppRunnerPage(
                details: _details,
                tabSession: session,
                initialEngine: session.engine,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final controller = platform.controller;
      platform.webView!.params.onWebViewCreated!(controller.wrapped);
      await tester.pump();
      expect(controller.eventToken, isNotNull);
      expect(find.text('首屏绘制'), findsOneWidget, reason: '首次读取采用公共首屏等待状态');
      expect(controller.soundProbes, 0, reason: '已有声音状态时免去额外探测');
      final previousSession = MiniAppWindowSession.current;
      var runtimeRequests = 0;
      MiniAppWindowSession.current = MiniAppWindowSession((method, args) async {
        runtimeRequests++;
        return 'cached runtime';
      });
      try {
        expect(
          await controller.readRuntime(),
          engine == MiniAppEngine.lightweight ? 'cached runtime' : null,
        );
        expect(runtimeRequests, engine == MiniAppEngine.lightweight ? 1 : 0);
      } finally {
        MiniAppWindowSession.current = previousSession;
      }
      final loading = {
        ..._ready,
        'ready': false,
        'loading': true,
        'stage': '事件进度',
      };
      expect(controller.sendState(loading, mainFrame: false), false);
      expect(
        controller.sendState(loading, origin: 'https://other.test'),
        false,
      );
      expect(controller.sendState(loading, origin: 'null'), false);
      expect(controller.sendState(loading, requestUrl: 'about:blank'), false);
      expect(
        controller.sendState(loading, origin: 'https://linux.do:444'),
        false,
      );
      expect(controller.sendState(loading, token: 'old'), false);
      expect(controller.sendState(loading), true);
      await tester.pump();
      expect(find.text('事件进度'), findsOneWidget);
      final reads = controller.reads;
      await tester.pump(const Duration(seconds: 4));
      expect(controller.reads, reads, reason: '事件生效后停止每 250ms 读取');
      controller.pending = Completer<Object?>();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.reads, reads + 1);
      expect(
        controller.sendState({...loading, 'stage': '最新进度'}, sequence: 2),
        true,
      );
      final pending = controller.pending!;
      controller.pending = null;
      pending.complete(_ready);
      await tester.pump();
      expect(find.text('最新进度'), findsOneWidget, reason: '迟到读取不能覆盖新事件');
      expect(controller.sendState(_ready, sequence: 1), false);
      final oldToken = controller.eventToken;
      platform.webView!.params.onLoadStart!(
        controller.wrapped,
        WebUri(_entry.toString()),
      );
      await tester.pump();
      expect(controller.eventToken, isNot(oldToken));
      expect(
        controller.sendState(loading, token: oldToken, sequence: 3),
        false,
      );
      expect(controller.sendState(_ready), true);
      await tester.pumpWidget(const SizedBox());
      expect(controller.sendState(loading, sequence: 2), false);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final closeBeforeCompletion in [false, true]) {
    testWidgets('慢状态读取保持单个在途调用且可安全恢复/关闭 ($closeBeforeCompletion)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _Platform();
      InAppWebViewPlatform.instance = platform;
      PlatformUtils.debugDesktopOverride = false;
      final messages = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
        previousPrint(message, wrapWidth: wrapWidth);
      };
      addTearDown(() {
        debugPrint = previousPrint;
        PlatformUtils.debugDesktopOverride = null;
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
      });
      try {
        final session =
            MiniAppTabSession(
                details: _details,
                entry: _entry,
                engine: MiniAppEngine.lightweight,
              )
              ..initialLoadRequested = true
              ..recorded = true;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              currentUserProvider.overrideWith(_Guest.new),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                theme: ThemeData(extensions: const [M3eFlags()]),
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: AppLocaleUtils.supportedLocales,
                home: MiniAppRunnerPage(
                  details: _details,
                  tabSession: session,
                  initialEngine: session.engine,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
        await tester.pump();
        expect(platform.controller.reads, 1);

        final pending = platform.controller.pending = Completer<Object?>();
        await tester.pump(const Duration(milliseconds: 250));
        final reads = platform.controller.reads;
        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 4));
        expect(platform.controller.reads, reads, reason: '超时不能发起第二个尚未完成的 IPC');
        final reports = messages
            .where((message) => message.contains('mini_app_state_read_failed'))
            .toList();
        expect(reports, hasLength(1));
        expect(reports.single, contains('"hostReady":true'));
        expect(reports.single, contains('"operation":"evaluate_js"'));
        expect(
          messages.any(
            (message) => message.contains('mini_app_native_boot_failed'),
          ),
          false,
        );

        if (closeBeforeCompletion) await tester.pumpWidget(const SizedBox());
        platform.controller.pending = null;
        pending.complete(_ready);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
        if (!closeBeforeCompletion) {
          expect(platform.controller.reads, greaterThan(reads));
          await tester.pumpWidget(const SizedBox());
        }
        await tester.pump(const Duration(milliseconds: 1));
      } finally {
        debugPrint = previousPrint;
      }
    });
  }
}
