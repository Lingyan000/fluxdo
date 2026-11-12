import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_artwork_palette.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_card_surface.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_feedback_dialog.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_detail_page.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_embed_card.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_gallery_page.dart';
import 'package:fluxdo/modules/mini_apps/home_mini_apps_layer.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_launch_shelf.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_gallery_widgets.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_metadata.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_providers.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_service.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runner_page.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runner_chrome.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_window_bridge.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runtime_surface.dart';
import 'package:fluxdo/services/navigation/app_route_observer.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/utils/avatar_url.dart';
import 'package:fluxdo/utils/url_helper.dart';
import 'package:fluxdo/widgets/keyboard_shortcut_handler.dart';
import 'package:fluxdo/widgets/common/smart_avatar.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

class _RuntimePlatform extends CfTestPlatform {
  late final _runtimeController = _RuntimeController(cookies);
  @override
  _RuntimeController get controller => _runtimeController;
}

class _RuntimeController extends CfTestController {
  _RuntimeController(super.cookies);
  @override
  Future<void> injectCSSCode({required String source}) async {}
}

Future<void> _hostDocumentLoaded(
  WidgetTester tester,
  _RuntimePlatform platform,
) async {
  await tester.pump();
  if (platform.webView != null) {
    platform.webView!.params.onLoadStop!(
      platform.controller.wrapped,
      WebUri('https://linux.do/apps/${_app.id}?embed_mode=true'),
    );
  }
  await tester.pumpAndSettle();
}

class _Me extends CurrentUserNotifier {
  @override
  User? build() => User(id: 2, username: 'me', trustLevel: 1);
}

const _app = MiniApp(
  id: '01a1b3ac-b68b-7d49-883d-51d49c784168',
  name: '软块合成：一个比较长的微应用名称',
  author: '开发者',
  description: '拖动后松手，发射数字块。相同数字的方块碰撞即可合成，挑战更高分。',
  usageCount: 200,
);

const _narrowCardApp = MiniApp(
  id: 'narrow-card',
  name: '广告游戏系列_减3加5',
  description: '图标已经说明了一切，想必逛着各种小程序的你已经准备好了。',
  author: '野怪',
  version: '1.1.0',
  usageCount: 63,
  recentUsageCount: 63,
);

class _Api extends MiniAppService {
  _Api() : super(dio: Dio());
  int ratingCalls = 0;
  final tipRequests = <String>[];
  final queries = <String>[];
  final requests = <(String, String, bool)>[];
  Completer<MiniAppDetails>? detailsRequest;
  List<MiniApp> apps = [_app];
  @override
  Future<MiniAppDirectory> directory({
    required String sort,
    required String query,
    required bool favorites,
    required int page,
  }) async {
    queries.add(query);
    requests.add((sort, query, favorites));
    final result = favorites ? apps.where((a) => a.favorited).toList() : apps;
    return MiniAppDirectory(
      apps: result,
      page: 0,
      perPage: 40,
      total: result.length,
    );
  }

  @override
  Future<MiniAppDetails> details(String id) async => detailsRequest != null
      ? detailsRequest!.future
      : MiniAppDetails(
          apps.firstWhere((app) => app.id == id),
          'https://linux.do/apps/$id?embed_mode=true',
          configuration: const {'channel': 'production', 'anonymous': false},
          feedback: const {
            'can_rate': true,
            'can_tip': true,
            'can_report': true,
          },
        );

  @override
  Future<void> rate(MiniAppDetails details, int score) async {
    ratingCalls++;
  }

  @override
  Future<List<Map<String, dynamic>>> reportTypes() async => [
    {'id': 4, 'name': '垃圾信息'},
    {'id': 8, 'name': '其他问题'},
  ];

  @override
  Future<Map<String, dynamic>> tipStatus(MiniAppDetails details) async => {
    'amounts': [1, 3, 5, 10],
    'balance': 9,
  };
  @override
  Future<Map<String, dynamic>> tip(
    MiniAppDetails details,
    int amount,
    String requestId,
  ) async {
    tipRequests.add(requestId);
    throw StateError('Network interrupted');
  }
}

void main() {
  const previewDirectory = String.fromEnvironment('MINI_APP_PREVIEW_DIR');
  const previewFont = String.fromEnvironment('MINI_APP_PREVIEW_FONT');
  final themes = ThemeResolver.resolve(
    spec: ThemeRegistry.material,
    mode: ThemeMode.system,
    black: false,
    seed: Colors.blue,
    variant: DynamicSchemeVariant.tonalSpot,
  );
  late SharedPreferences prefs;
  late _Api api;
  setUp(() async {
    PlatformUtils.debugDesktopOverride = false;
    SharedPreferences.setMockInitialValues({'pref_mini_app_engine': 'web'});
    prefs = await SharedPreferences.getInstance();
    api = _Api();
    LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  Widget wrap(
    Widget child, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentUserProvider.overrideWith(_Me.new),
      miniAppServiceProvider.overrideWithValue(api),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        navigatorObservers: [appRouteObserver],
        theme: ThemeData(
          colorScheme: brightness == Brightness.light
              ? themes.light
              : themes.dark,
          fontFamily: previewFont.isEmpty ? null : 'MiniAppPreview',
          extensions: const [M3eFlags()],
          searchBarTheme: const SearchBarThemeData(
            shape: WidgetStatePropertyAll(
              RoundedSuperellipseBorder(
                borderRadius: BorderRadius.all(Radius.circular(9999)),
              ),
            ),
          ),
        ),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    ),
  );

  for (final desktop in [false, true]) {
    testWidgets('应用信息骨架切换为整体内容和开发者头像 ($desktop)', (tester) async {
      PlatformUtils.debugDesktopOverride = desktop;
      api.detailsRequest = Completer<MiniAppDetails>();
      const avatarTemplate = '/user_avatar/linux.do/developer/{size}/1.png';
      final avatarUrl = UrlHelper.resolveUrlWithCdn(
        AvatarUrl.resolve(
          avatarTemplate,
          size: (40 * tester.view.devicePixelRatio).ceil(),
        ),
      );
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'mini-app-avatar-',
        );
        await BlobImageCache.configureForTesting(root: directory);
        final bytes = await rootBundle.load(
          'assets/images/icon_modern_preview.png',
        );
        await BlobImageCache.write(
          BlobImageCache.avatarBucket,
          avatarUrl,
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      });
      addTearDown(BlobImageCache.configureForTesting);
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => MiniAppDetailPage.show(context, _app.id),
                child: const Text('详情'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MiniAppDetailsSkeleton), findsOneWidget);
      expect(find.byType(MiniAppCardSurface), findsNothing);
      final metadata = MiniApp.fromJson({
        ..._app.toJson(),
        'version': '1.5.9',
        'recent_usage_count': 123,
        'rating_average': 4,
        'rating_count': 5,
        'can_tip': true,
        'author': {
          'username': 'developer',
          'name': '开发者',
          'avatar_template': avatarTemplate,
        },
      });
      api.detailsRequest!.complete(
        MiniAppDetails(metadata, 'https://linux.do/apps/${_app.id}'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MiniAppDetailsSkeleton), findsNothing);
      expect(find.byType(MiniAppDetailsContent), findsOneWidget);
      expect(find.byType(MiniAppCardSurface), findsNothing);
      expect(find.byType(SegmentedCardItem), findsNothing);
      expect(find.byType(SmartAvatar), findsOneWidget);
      expect(
        tester.widget<SmartAvatar>(find.byType(SmartAvatar)).imageUrl,
        avatarUrl,
      );
      expect(find.text(S.current.miniApp_recentUsage(123)), findsOneWidget);
      expect(find.text(S.current.miniApp_usage(200)), findsOneWidget);
      expect(find.text(S.current.miniApp_score('4.0', 5)), findsOneWidget);
      expect(find.text(S.current.miniApp_tipAvailable), findsOneWidget);
      expect(find.text(S.current.miniApp_version('1.5.9')), findsOneWidget);
      final developer = find.byType(MiniAppDeveloper);
      expect(
        tester
            .widget<InkWell>(
              find.descendant(of: developer, matching: find.byType(InkWell)),
            )
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      api.detailsRequest = null;
      await tester.pumpWidget(wrap(MiniAppDetailPage(appId: _app.id)));
      await tester.pumpAndSettle();
      expect(find.byType(MiniAppDetailsContent), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(MiniAppDetailsContent)).dy,
        lessThan(150),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final desktop in [false, true]) {
    testWidgets(
      'runner shared menu opens repeatedly without resizing WebView ($desktop)',
      (tester) async {
        PlatformUtils.debugDesktopOverride = desktop;
        addTearDown(() => PlatformUtils.debugDesktopOverride = null);
        final previousPlatform = InAppWebViewPlatform.instance;
        final platform = _RuntimePlatform();
        InAppWebViewPlatform.instance = platform;
        if (previousPlatform != null) {
          addTearDown(() => InAppWebViewPlatform.instance = previousPlatform);
        }
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          wrap(
            const MiniAppRunnerPage(
              details: MiniAppDetails(
                _app,
                'https://linux.do/apps/01a1b3ac-b68b-7d49-883d-51d49c784168?embed_mode=true',
                configuration: {'channel': 'production', 'anonymous': false},
                feedback: {
                  'can_rate': true,
                  'can_tip': true,
                  'can_report': true,
                },
              ),
            ),
          ),
        );
        await _hostDocumentLoaded(tester, platform);
        final viewSize = tester.getSize(find.byType(InAppWebView));
        expect(find.byIcon(Symbols.expand_more_rounded), findsNothing);
        for (var i = 0; i < 2; i++) {
          final blur = i == 0;
          await ProviderScope.containerOf(
            tester.element(find.byType(MiniAppRunnerPage)),
          ).read(preferencesProvider.notifier).setDialogBlur(blur);
          await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
          await tester.pumpAndSettle();
          expect(find.text(S.current.miniApp_rate), findsOneWidget);
          expect(tester.getSize(find.byType(InAppWebView)), viewSize);
          if (!desktop) {
            expect(
              find.byType(BackdropFilter),
              blur ? findsOneWidget : findsNothing,
              reason: '菜单必须遵循全局模糊开关',
            );
            expect(
              tester
                  .widget<AnimatedModalBarrier>(
                    find.byType(AnimatedModalBarrier),
                  )
                  .color
                  .value
                  ?.a,
              greaterThan(0),
              reason: '开关两种状态下都保留模态遮罩',
            );
          }
          await tester.tap(find.text(S.current.miniApp_rate));
          await tester.pumpAndSettle();
          expect(find.byType(MiniAppFeedbackDialog), findsOneWidget);
          expect(
            find.byType(BackdropFilter),
            blur ? findsOneWidget : findsNothing,
          );
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip(S.current.miniApp_info));
          await tester.pumpAndSettle();
          expect(find.byType(MiniAppDetailsContent), findsOneWidget);
          expect(
            find.byType(BackdropFilter),
            blur ? findsOneWidget : findsNothing,
          );
          expect(tester.getSize(find.byType(InAppWebView)), viewSize);
          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('子窗口反馈在广场重新显示时同步，不在隐藏期间发起刷新', (tester) async {
    await tester.pumpWidget(wrap(const MiniAppGalleryPage()));
    await tester.pumpAndSettle();
    final requests = api.requests.length;
    await tester.pumpWidget(wrap(const MiniAppGalleryPage(active: false)));
    MiniAppWindowBridge.updates.add(_app.id);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.requests.length, requests);
    await tester.pumpWidget(wrap(const MiniAppGalleryPage()));
    await tester.pumpAndSettle();
    expect(api.requests.length, requests + 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立窗口保留客户端菜单和评分面板，返回只关闭当前窗口', (tester) async {
    final previous = InAppWebViewPlatform.instance;
    final platform = _RuntimePlatform();
    InAppWebViewPlatform.instance = platform;
    addTearDown(() {
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    var closed = 0;
    await tester.pumpWidget(
      wrap(
        MiniAppRunnerPage(
          independentWindow: true,
          onCloseWindow: () => closed++,
          details: MiniAppDetails(
            _app,
            'https://linux.do/apps/${_app.id}?embed_mode=true',
            configuration: const {'channel': 'production', 'anonymous': false},
            feedback: const {
              'can_rate': true,
              'can_tip': true,
              'can_report': true,
            },
          ),
        ),
      ),
    );
    await _hostDocumentLoaded(tester, platform);
    final original = tester.element(find.byType(InAppWebView));
    await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
    await tester.pumpAndSettle();
    expect(find.text(S.current.miniApp_separateWindow), findsNothing);
    expect(find.text(S.current.miniApp_rate), findsOneWidget);
    await tester.tap(find.text(S.current.miniApp_rate));
    await tester.pumpAndSettle();
    expect(find.byType(MiniAppFeedbackDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(InAppWebView)), same(original));
    expect(closed, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(closed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('帖子卡片默认运行弹窗；收起后继续复用同一原生实例', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final previous = InAppWebViewPlatform.instance;
    final platform = _RuntimePlatform();
    InAppWebViewPlatform.instance = platform;
    addTearDown(() {
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    final uri = 'https://linux.do/apps/${_app.id}?room=42';
    await tester.pumpWidget(wrap(Scaffold(body: MiniAppEmbedCard(url: uri))));
    await tester.pumpAndSettle();
    expect(find.text(_app.name), findsOneWidget);
    expect(find.text(_app.description), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    await tester.tap(find.text(S.current.miniApp_open));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _hostDocumentLoaded(tester, platform);
    final runner = find.byType(MiniAppRunnerPage);
    final view = find.byType(InAppWebView);
    final originalToken = platform.webView!.params.keepAlive;
    expect(originalToken, isNotNull);
    expect(
      tester
          .widget<MiniAppRunnerPage>(runner)
          .launchUri!
          .queryParameters['room'],
      '42',
    );
    expect(ModalRoute.of(tester.element(runner)), isA<PopupRoute>());
    expect(find.byKey(const ValueKey('mini-app-open-page')), findsOneWidget);
    expect(
      tester.getSize(runner).height,
      lessThan(tester.getSize(find.byType(Navigator).first).height),
    );
    final originalElement = tester.element(view);
    final panelSize = tester.getSize(view);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.getSize(view).height, closeTo(panelSize.height - 280, 1));
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.miniApp_fullscreen));
    await tester.pumpAndSettle();
    expect(tester.getSize(view), const Size(390, 844));
    expect(tester.element(view), same(originalElement));
    await tester.tap(find.byKey(const ValueKey('mini-app-show-controls')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mini-app-fullscreen-exit')));
    await tester.pumpAndSettle();
    expect(tester.getSize(view), panelSize);
    expect(tester.element(view), same(originalElement));
    await tester.tap(find.byKey(const ValueKey('mini-app-minimize')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(view, findsNothing);
    await tester.tap(find.text(S.current.miniApp_resumePanel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _hostDocumentLoaded(tester, platform);
    expect(platform.webView!.params.keepAlive, same(originalToken));
    await tester.tap(find.byKey(const ValueKey('mini-app-close')));
    await tester.pumpAndSettle();
    expect(find.text(S.current.miniApp_resumePanel), findsNothing);
    expect(find.text(S.current.miniApp_open), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'runner fits rotation, cutouts and keyboard without recreating the app',
    (tester) async {
      PlatformUtils.debugDesktopOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      PreferencesNotifier.isPortraitLocked = true;
      await prefs.setBool('pref_portrait_lock', true);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _RuntimePlatform();
      InAppWebViewPlatform.instance = platform;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 34);
      addTearDown(() {
        PlatformUtils.debugDesktopOverride = null;
        debugDefaultTargetPlatformOverride = null;
        PreferencesNotifier.isPortraitLocked = false;
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        tester.view.resetPadding();
        tester.view.resetViewPadding();
        tester.view.resetViewInsets();
      });
      await tester.pumpWidget(
        wrap(
          const MiniAppRunnerPage(
            details: MiniAppDetails(
              _app,
              'https://linux.do/apps/01a1b3ac-b68b-7d49-883d-51d49c784168?embed_mode=true',
              configuration: {'channel': 'production', 'anonymous': false},
            ),
          ),
          scale: 1.8,
        ),
      );
      await _hostDocumentLoaded(tester, platform);
      final view = find.byType(InAppWebView);
      final originalElement = tester.element(view);
      final originalPlatformView = platform.webView;
      expect(tester.getSize(view), const Size(390, 710));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('mini-app-rotate')));
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere(
              (c) => c.method == 'SystemChrome.setPreferredOrientations',
            )
            .arguments,
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
      );

      tester.view.physicalSize = const Size(844, 390);
      tester.view.padding = const FakeViewPadding(left: 44, bottom: 21);
      tester.view.viewPadding = const FakeViewPadding(left: 44, bottom: 21);
      await tester.pumpAndSettle();
      expect(tester.getSize(view), const Size(800, 321));
      await tester.tap(find.byKey(const ValueKey('mini-app-fullscreen')));
      await tester.pumpAndSettle();
      // 系统栏隐藏，只剩物理刘海；悬浮圆环不改变 WebView 尺寸。
      tester.view.padding = const FakeViewPadding(left: 44);
      tester.view.viewPadding = const FakeViewPadding(left: 44);
      await tester.pumpAndSettle();
      expect(tester.getSize(view), const Size(800, 390));
      final dock = find.byKey(const ValueKey('mini-app-fullscreen-dock'));
      expect(tester.getRect(view).overlaps(tester.getRect(dock)), isTrue);
      await tester.tap(find.byKey(const ValueKey('mini-app-show-controls')));
      await tester.pumpAndSettle();
      expect(tester.getSize(view), const Size(800, 390));
      expect(tester.getRect(view).overlaps(tester.getRect(dock)), isTrue);

      // 网页退出自身全屏不能把用户选择的原生全屏一起关闭。
      platform.webView!.params.onEnterFullscreen!(platform.controller.wrapped);
      await tester.pumpAndSettle();
      platform.webView!.params.onExitFullscreen!(platform.controller.wrapped);
      await tester.pumpAndSettle();
      expect(dock, findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      expect(tester.getSize(view), const Size(800, 210));
      expect(tester.takeException(), isNull);
      final modesBeforeClosingKeyboard = calls
          .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
          .length;
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(
        calls
            .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
            .length,
        modesBeforeClosingKeyboard + 1,
      );
      expect(
        calls
            .lastWhere((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
            .arguments,
        'SystemUiMode.immersiveSticky',
      );

      await tester.tap(find.byKey(const ValueKey('mini-app-menu-button')));
      await tester.pumpAndSettle();
      expect(find.text('退出全屏'), findsOneWidget);
      expect(tester.getSize(view), const Size(800, 390));
      await tester.ensureVisible(find.text('跟随系统旋转'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跟随系统旋转'));
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere(
              (c) => c.method == 'SystemChrome.setPreferredOrientations',
            )
            .arguments,
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('mini-app-show-controls')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mini-app-rotate')));
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere(
              (c) => c.method == 'SystemChrome.setPreferredOrientations',
            )
            .arguments,
        ['DeviceOrientation.portraitUp'],
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(dock, findsNothing);
      expect(find.byType(MiniAppRunnerPage), findsOneWidget);
      expect(tester.element(view), same(originalElement));
      expect(platform.webView, same(originalPlatformView));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere(
              (c) => c.method == 'SystemChrome.setPreferredOrientations',
            )
            .arguments,
        ['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown'],
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('应用广场切换收藏只在选中后震动，最近使用区变化保留按钮组状态', (tester) async {
    final feedback = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        feedback.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(wrap(const MiniAppGalleryPage()));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MiniAppGalleryPage)),
    );
    container.read(miniAppRecentsProvider).record(_app);
    await tester.pumpAndSettle();
    expect(find.byType(MiniAppRecentSection), findsOneWidget);
    final group = find.byType(M3eButtonGroup<bool>);
    final original = tester.state(group);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('已收藏')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(feedback, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(feedback, isEmpty);
    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    expect(tester.widget<M3eButtonGroup<bool>>(group).selected, isTrue);
    expect(find.byType(MiniAppRecentSection), findsNothing);
    expect(feedback, ['HapticFeedbackType.selectionClick']);
    expect(tester.state(group), same(original));
    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    expect(feedback, hasLength(1));
    await tester.tap(find.byIcon(Symbols.explore_rounded));
    await tester.pumpAndSettle();
    expect(tester.widget<M3eButtonGroup<bool>>(group).selected, isFalse);
    expect(find.byType(MiniAppRecentSection), findsOneWidget);
    expect(feedback, hasLength(2));
    expect(tester.state(group), same(original));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared sort menu preserves query and favorites; report dropdown selects type',
    (tester) async {
      await tester.pumpWidget(wrap(const MiniAppGalleryPage()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '合成');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('已收藏'));
      await tester.pumpAndSettle();
      expect(
        find.byType(SwipeDismissiblePopupMenuButton<String>),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('mini-app-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CheckedPopupMenuItem<String> && w.value == 'rating',
        ),
      );
      await tester.pumpAndSettle();
      expect(api.requests.last, ('rating', '合成', true));

      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: MiniAppFeedbackDialog(
              details: MiniAppDetails(_app, ''),
              action: MiniAppFeedback.report,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SwipeDismissiblePopupMenuButton<int>), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mini-app-report-type')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CheckedPopupMenuItem<int> && w.value == 8,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('其他问题'), findsOneWidget);
      final submit = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(submit.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native directory works at narrow width and large text; search debounces',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(wrap(const MiniAppGalleryPage(), scale: 1.8));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MiniAppGalleryPage)),
      );
      container.read(miniAppRecentsProvider).record(_app);
      await tester.pumpAndSettle();
      expect(find.byType(MiniAppDiscoveryCard), findsNothing);
      expect(find.byType(MiniAppDiscoveryRow), findsOneWidget);
      expect(find.byType(MiniAppRecentSection), findsOneWidget);
      expect(find.text(_app.name), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'test');
      await tester.pump(const Duration(milliseconds: 349));
      expect(api.queries, ['']);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pumpAndSettle();
      expect(api.queries, ['', 'test']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('窄卡片切换单列，长名称与使用统计不会挤成长条', (tester) async {
    api.apps = const [
      _narrowCardApp,
      _app,
      MiniApp(id: 'third', name: '第三个应用'),
    ];
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final (width, scale, columns) in [
      (360.0, 1.0, 1),
      (390.0, 1.0, 1),
      (569.0, 1.0, 1),
      (570.0, 1.0, 2),
      (843.0, 1.0, 2),
      (844.0, 1.0, 3),
      (960.0, 1.0, 3),
      (960.0, 1.8, 1),
    ]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpWidget(wrap(const MiniAppGalleryPage(), scale: scale));
      await tester.pumpAndSettle();
      final cardType = columns == 1
          ? MiniAppDiscoveryRow
          : MiniAppDiscoveryCard;
      final cards = find.byType(cardType);
      final first = tester.getRect(cards.first);
      final rowCount = tester
          .elementList(cards)
          .where(
            (element) =>
                tester.getTopLeft(find.byWidget(element.widget)).dy ==
                first.top,
          )
          .length;
      expect(rowCount, columns, reason: '视口 $width，字号缩放 $scale');
      if (columns > 1) expect(first.width, greaterThanOrEqualTo(264));
      if (scale == 1) {
        expect(first.height, lessThan(first.width));
        expect(
          tester.getTopLeft(find.text('63 次使用')).dy,
          tester.getTopLeft(find.text('近 7 天 63 次')).dy,
          reason: '使用量和近 7 天统计同排展示，视口 $width',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('桌面广场有刷新、滚动条和右键详情，键盘仅作用于当前工作区', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final active = ValueNotifier(true);
    await tester.pumpWidget(
      wrap(
        KeyboardShortcutHandler(
          navigatorKey: navigatorKey,
          child: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) =>
                MiniAppGalleryPage(active: value, workspace: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(M3eRefreshIndicator), findsNothing);
    expect(find.byType(HomeMiniAppsLayer), findsNothing);
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(find.byTooltip('返回首页'), findsNothing);
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(api.requests, hasLength(1));
    final original = tester.element(find.byType(MiniAppGalleryPage));
    expect(
      tester
          .widget<InkWell>(find.byKey(ValueKey('mini-app-launch-${_app.id}')))
          .onLongPress,
      isNull,
      reason: '桌面使用右键查看详情，不保留移动端长按手势',
    );
    final mouse = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('mini-app-launch-${_app.id}'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.byType(MiniAppDetailsContent), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), '合成');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    Future<void> refreshShortcut() async {
      if (Platform.isMacOS) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      }
      await tester.sendKeyEvent(
        Platform.isMacOS ? LogicalKeyboardKey.keyR : LogicalKeyboardKey.f5,
      );
      if (Platform.isMacOS) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      }
      await tester.pumpAndSettle();
    }

    final before = api.requests.length;
    await refreshShortcut();
    expect(api.requests.length, before + 1);
    expect(api.queries.last, '合成');
    active.value = false;
    await tester.pumpAndSettle();
    await refreshShortcut();
    expect(api.requests.length, before + 1);
    active.value = true;
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(MiniAppGalleryPage)), same(original));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '合成',
    );
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(api.requests.length, before + 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(wrap(const SizedBox()));
    // 快捷键在下一次事件循环注销，推进假时钟让延迟清理实际执行。
    await tester.pump(const Duration(milliseconds: 1));
    active.dispose();
  });

  testWidgets('浅拉不请求目录，深拉与展开复用真实广场及请求结果', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    final layer = GlobalKey<HomeMiniAppsLayerState>();
    final refresh = GlobalKey<M3eRefreshIndicatorState>();
    var refreshes = 0;
    await tester.pumpWidget(
      wrap(
        HomeMiniAppsLayer(
          key: layer,
          child: Scaffold(
            body: M3eRefreshIndicator(
              key: refresh,
              externalReveal: true,
              revealOffset: () => layer.currentState!.offset,
              onSecondaryAction: () => layer.currentState!.open(),
              onRefresh: () async => refreshes++,
              child: ListView(
                physics: RefreshRevealScrollPhysics(
                  holdLeadingEdge: () =>
                      refresh.currentState?.isRevealing ?? false,
                  parent: const AlwaysScrollableScrollPhysics(),
                ),
                children: const [SizedBox(height: 1200)],
              ),
            ),
          ),
        ),
      ),
    );
    final shallow = await tester.startGesture(const Offset(180, 160));
    await shallow.moveBy(const Offset(0, 25));
    await tester.pump();
    await shallow.moveBy(const Offset(0, 160));
    await tester.pump();
    expect(find.byType(MiniAppGalleryPage), findsNothing);
    expect(api.requests, isEmpty);
    await shallow.up();
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    final deep = await tester.startGesture(const Offset(180, 160));
    await deep.moveBy(const Offset(0, 25));
    await tester.pump();
    await deep.moveBy(const Offset(0, 240));
    await tester.pumpAndSettle();
    expect(layer.currentState!.isOpen, isFalse);
    final gallery = tester.element(find.byType(MiniAppGalleryPage));
    expect(find.byType(MiniAppDiscoveryRow), findsOneWidget);
    expect(api.requests, hasLength(1));
    await deep.up();
    await tester.pumpAndSettle();
    expect(layer.currentState!.isOpen, isTrue);
    expect(tester.element(find.byType(MiniAppGalleryPage)), same(gallery));
    layer.currentState!.close();
    await tester.pumpAndSettle();
    layer.currentState!.open();
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(MiniAppGalleryPage)), same(gallery));
    expect(api.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final inLayer in [true, false]) {
    for (final safeBottom in [0.0, 24.0]) {
      testWidgets(
        'search keyboard uses bottom space once ($inLayer, $safeBottom)',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          tester.view.viewPadding = FakeViewPadding(
            top: 44,
            bottom: safeBottom,
          );
          tester.view.padding = FakeViewPadding(top: 44, bottom: safeBottom);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewInsets);
          api.apps = List.generate(
            24,
            (i) => MiniApp(id: 'app-$i', name: '应用 $i'),
          );
          final layer = GlobalKey<HomeMiniAppsLayerState>();
          await tester.pumpWidget(
            wrap(
              inLayer
                  ? HomeMiniAppsLayer(
                      key: layer,
                      child: const Scaffold(body: SizedBox.expand()),
                    )
                  : const MiniAppGalleryPage(),
            ),
          );
          if (inLayer) layer.currentState!.open();
          await tester.pumpAndSettle();
          final originalGallery = tester.element(
            find.byType(MiniAppGalleryPage),
          );
          await tester.enterText(find.byType(TextField), '应用');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          final results = find.byType(CustomScrollView);
          final controller = tester
              .widget<CustomScrollView>(results)
              .controller!;
          controller.jumpTo(120);
          await tester.pumpAndSettle();
          final callsBeforeKeyboard = api.requests.length;
          final footerTop = 844 - (64 + safeBottom);
          for (final keyboard in [
            0.0,
            44.0,
            160.0,
            320.0,
            240.0,
            88.0,
            44.0,
            0.0,
          ]) {
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            tester.view.padding = FakeViewPadding(
              top: 44,
              bottom: keyboard > 0 ? 0 : safeBottom,
            );
            await tester.pumpAndSettle();
            final expectedBottom = inLayer && footerTop < 844 - keyboard
                ? footerTop
                : 844 - keyboard;
            expect(
              tester.getBottomLeft(results).dy,
              closeTo(expectedBottom, .5),
              reason: 'results should meet the keyboard or the visible return strip',
            );
            expect(
              tester.element(find.byType(MiniAppGalleryPage)),
              same(originalGallery),
            );
            expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              '应用',
            );
            expect(controller.offset, 120);
            expect(api.requests.length, callsBeforeKeyboard);
            if (inLayer) {
              expect(layer.currentState!.offset, footerTop);
            }
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }

  testWidgets(
    'visible details opens native sheet; favorites has a useful empty state',
    (tester) async {
      await tester.pumpWidget(wrap(const MiniAppGalleryPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('应用信息'));
      await tester.pumpAndSettle();
      expect(find.byType(MiniAppDetailsContent), findsOneWidget);
      expect(find.text('打开应用'), findsOneWidget);
      expect(find.text(_app.description), findsWidgets);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('已收藏'));
      await tester.pumpAndSettle();
      expect(find.text('还没有收藏应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 1.8]) {
    testWidgets('long press opens details without launching ($scale)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(wrap(const MiniAppGalleryPage(), scale: scale));
      await tester.pumpAndSettle();
      final directoryTile = find.byKey(ValueKey('mini-app-launch-${_app.id}'));
      await tester.longPress(directoryTile);
      await tester.pumpAndSettle();
      expect(find.byType(MiniAppDetailsContent), findsOneWidget);
      expect(find.byType(MiniAppRunnerPage), findsNothing);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MiniAppGalleryPage)),
      );
      container.read(miniAppRecentsProvider).record(_app);
      await tester.pumpAndSettle();
      await tester.longPress(
        find.byKey(ValueKey('mini-app-recent-${_app.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MiniAppDetailsContent), findsOneWidget);
      expect(find.byType(MiniAppRunnerPage), findsNothing);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      // 关闭长按详情后，原卡片的短按仍可正常启动。
      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _RuntimePlatform();
      InAppWebViewPlatform.instance = platform;
      if (previousPlatform != null) {
        addTearDown(() => InAppWebViewPlatform.instance = previousPlatform);
      }
      await tester.tap(find.byKey(ValueKey('mini-app-recent-${_app.id}')));
      await tester.pump();
      await _hostDocumentLoaded(tester, platform);
      expect(find.byType(MiniAppRunnerPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('directory and detail layout across themes and screen widths', (
    tester,
  ) async {
    if (previewDirectory.isNotEmpty) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      // 字体已改为按需下载，预览通过参数读取本机字体。
      if (previewFont.isNotEmpty) {
        await tester.runAsync(() async {
          final bytes = await File(previewFont).readAsBytes();
          await (FontLoader(
            'MiniAppPreview',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        });
      }
      await (FontLoader(
            'packages/material_symbols_icons/${Symbols.apps_rounded.fontFamily}',
          )..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
          .load();
    }
    api.apps = const [
      _narrowCardApp,
      MiniApp(
        id: 'one',
        name: '软块合成',
        description: '拖动、碰撞、合成，挑战更高的数字。',
        author: 'ffy1',
        authorUsername: 'ffy1',
        recentUsageCount: 287,
        usageCount: 1234,
        canTip: true,
        rating: 4.8,
        ratingCount: 12,
        version: '1.0.0',
      ),
      MiniApp(
        id: 'two',
        name: 'Music Player',
        description: '在 LINUX DO 里听歌？！',
        author: '神墨',
        rating: 5,
        ratingCount: 10,
        favorited: true,
      ),
      MiniApp(
        id: 'three',
        name: '每日 Bingo',
        description: '缤果卡每日刷新，快来挑战吧！',
        author: 'lafish',
      ),
      MiniApp(
        id: 'four',
        name: 'Linux.do 像素乐园',
        description: '全社区共用的一块像素画布，和佬友一起创作。',
        author: 'Bosch',
      ),
      MiniApp(
        id: 'five',
        name: '万年历拼图',
        description: '移动、旋转和组合拼块，每日一战。',
        author: 'Megasoft',
      ),
    ];
    if (previewDirectory.isNotEmpty) {
      api.apps = api.apps.toList();
      // 预览复用本地图标，走真实图片缓存和取色，不访问远程图床。
      await tester.runAsync(() async {
        final cache = Directory('$previewDirectory/artwork-cache');
        await cache.create(recursive: true);
        await BlobImageCache.configureForTesting(root: cache);
        final assets = [
          'assets/ai_brands/claude-color.svg',
          'assets/ai_brands/deepseek-color.svg',
          'assets/ai_brands/huggingface-color.svg',
          'assets/images/icon_modern_preview.png',
        ];
        for (var index = 0; index < assets.length; index++) {
          final asset = assets[index];
          final url = 'https://mini-app.test/preview/${asset.split('/').last}';
          final data = await rootBundle.load(asset);
          await BlobImageCache.write(
            BlobImageCache.contentBucket,
            url,
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          api.apps[index] = MiniApp.fromJson({
            ...api.apps[index].toJson(),
            'icon_url': url,
          });
          for (final brightness in Brightness.values) {
            await MiniAppArtworkPalette.resolve(url, brightness);
          }
        }
      });
      addTearDown(BlobImageCache.configureForTesting);
    }
    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      if (previewDirectory.isEmpty) return;
      // 磁盘读取、解析、解码分别跨越真实 IO 与虚拟时钟，逐轮推进后再导出。
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(previewDirectory).create(recursive: true);
        await File('$previewDirectory/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      for (final width in [390.0, 960.0]) {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: wrap(const MiniAppGalleryPage(), brightness: brightness),
          ),
        );
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(MiniAppGalleryPage)),
        );
        for (final app in api.apps.take(4)) {
          container.read(miniAppRecentsProvider).record(app);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final cardType = width == 390
            ? MiniAppDiscoveryRow
            : MiniAppDiscoveryCard;
        expect(
          tester.getSize(find.byType(cardType).first).height,
          lessThan(280),
          reason: '卡片按内容收紧，避免固定高度撑出大块留白',
        );
        await capture('gallery-${brightness.name}-${width.toInt()}');
        if (width == 390) {
          await tester.tap(find.byTooltip('应用信息').first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture('detail-${brightness.name}');
          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          final layer = GlobalKey<HomeMiniAppsLayerState>();
          tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
          tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: wrap(
                HomeMiniAppsLayer(
                  key: layer,
                  child: const Scaffold(body: SizedBox.expand()),
                ),
                brightness: brightness,
              ),
            ),
          );
          layer.currentState!.open();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture('gallery-layer-${brightness.name}');
          await tester.tap(find.byKey(const ValueKey('mini-app-return-home')));
          await tester.pumpAndSettle();
          expect(layer.currentState!.isOpen, isFalse);
          tester.view.resetPadding();
          tester.view.resetViewPadding();
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  Widget dialogHost(MiniAppFeedback action) => Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: FilledButton(
          onPressed: () => showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => MiniAppFeedbackDialog(
              details: const MiniAppDetails(
                _app,
                '',
                feedback: {'my_rating': 4},
              ),
              action: action,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  testWidgets('runtime surfaces fit phone, landscape and large text', (
    tester,
  ) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      if (previewDirectory.isEmpty) return;
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(previewDirectory).create(recursive: true);
        await File('$previewDirectory/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    const details = MiniAppDetails(
      _app,
      '',
      feedback: {
        'can_rate': true,
        'can_tip': true,
        'can_report': true,
        'my_rating': 4,
      },
    );
    const permission = MiniAppPermissionRequest(
      signature: 'request-one',
      title: '软块合成请求操作',
      action: '播放音频',
      notice: '此应用在本次运行中可播放声音。',
      reject: '静音进入',
      allow: '开启声音',
    );
    for (final brightness in Brightness.values) {
      for (final size in [const Size(390, 844), const Size(844, 390)]) {
        tester.view.physicalSize = size;
        final scale = size.width > 400 ? 1.8 : 1.0;
        Future<void> mount(Widget child, {bool animating = false}) async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: wrap(child, brightness: brightness, scale: scale),
            ),
          );
          if (animating) {
            await tester.pump(const Duration(milliseconds: 300));
          } else {
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        }

        final suffix = '${brightness.name}-${size.width.toInt()}';
        await mount(
          const Scaffold(
            body: MiniAppLaunchSurface(
              app: _app,
              stage: '下载应用包',
              detail: '768 / 1024 KiB',
              progress: .75,
            ),
          ),
          animating: true,
        );
        await capture('runtime-loading-$suffix');
        bool? allowed;
        await mount(
          Scaffold(
            body: MiniAppPermissionSurface(
              app: _app,
              request: permission,
              onAnswer: (value) => allowed = value,
            ),
          ),
        );
        expect(allowed, isNull);
        expect(
          tester.getBottomLeft(find.text(permission.notice)).dy,
          lessThanOrEqualTo(
            tester
                .getTopLeft(
                  find.byKey(const ValueKey('mini-app-permission-allow')),
                )
                .dy,
          ),
          reason: '用途说明应在授权按钮之前完整可见，而不是被固定操作区挤出首屏',
        );
        await capture('runtime-permission-$suffix');
        await tester.tap(
          find.byKey(const ValueKey('mini-app-permission-reject')),
        );
        expect(allowed, isFalse);

        for (final action in MiniAppFeedback.values) {
          await mount(
            Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: FilledButton(
                    onPressed: () => MiniAppFeedbackDialog.show(
                      context,
                      details: details,
                      action: action,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          if (action == MiniAppFeedback.tip) {
            final disabled = tester.widget<InkWell>(
              find.byKey(const ValueKey('mini-app-tip-10')),
            );
            expect(disabled.onTap, isNull);
            await tester.ensureVisible(
              find.byKey(const ValueKey('mini-app-tip-3')),
            );
            await tester.tap(find.byKey(const ValueKey('mini-app-tip-3')));
            await tester.pumpAndSettle();
            expect(find.text('确认打赏 3 积分'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await capture('runtime-${action.name}-$suffix');
          if (action == MiniAppFeedback.report) {
            tester.view.viewInsets = const FakeViewPadding(bottom: 180);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            tester.view.resetViewInsets();
            await tester.pumpAndSettle();
          }
          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
        }
        await mount(
          Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showMiniAppMenu(
                    context,
                    details,
                    loggedIn: true,
                    anchorContext: context,
                    soundAvailable: true,
                    canRotate: true,
                  ),
                  child: const Text('open-menu'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open-menu'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture('runtime-menu-$suffix');
        await tester.ensureVisible(find.text('举报应用'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('举报应用'));
        await tester.pumpAndSettle();
        expect(find.text('举报应用'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets(
    'account change disables a previously opened native rating confirmation',
    (tester) async {
      await tester.pumpWidget(wrap(dialogHost(MiniAppFeedback.rating)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('很喜欢'), findsOneWidget);
      AuthSession().advance();
      await tester.pumpAndSettle();
      final submit = find.widgetWithText(FilledButton, '提交');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(api.ratingCalls, 0);
    },
  );

  testWidgets('choosing a star does not submit until confirmed', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(dialogHost(MiniAppFeedback.rating)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mini-app-rating-5')));
    await tester.pumpAndSettle();
    expect(find.text('非常出色'), findsOneWidget);
    expect(api.ratingCalls, 0);
    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.pumpAndSettle();
    expect(api.ratingCalls, 1);
    expect(find.byType(MiniAppFeedbackDialog), findsNothing);
  });

  testWidgets(
    'native tip retry keeps the same request ID after network failure',
    (tester) async {
      await tester.pumpWidget(wrap(dialogHost(MiniAppFeedback.tip)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mini-app-tip-1')));
      await tester.pumpAndSettle();
      final submit = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      );
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(api.tipRequests, hasLength(2));
      expect(api.tipRequests[0], api.tipRequests[1]);
      expect(tester.takeException(), isNull);
    },
  );
}
