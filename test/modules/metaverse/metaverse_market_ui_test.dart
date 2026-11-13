import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/developer/metaverse_api_examples.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_catalog.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_page.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_provider.dart';
import 'package:fluxdo/modules/metaverse/developer/metaverse_developer_page.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_management_page.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';

import '../../helpers/preview_fonts.dart';

class _Catalog extends MetaverseMarketController {
  @override
  Future<void> addSource(String input) async {
    state = MetaverseMarketState(
      sources: [...state.sources, MetaverseMarketSource.fromInput(input)],
      entries: state.entries,
    );
  }

  @override
  MetaverseMarketState build() {
    const source = MetaverseMarketSource(MetaverseMarketSource.defaultUrl);
    return MetaverseMarketState(
      sources: [source],
      entries: [
        for (final item in [
          ('community.fluxdo.ldstore', 'LD士多', '购物'),
          ('community.fluxdo.quicknotes', '随手记', '效率'),
        ])
          MetaverseMarketEntry.parse({
            'id': item.$1,
            'name': item.$2,
            'version': '1.0.0',
            'apiVersion': 1,
            'summary': item.$1.endsWith('ldstore')
                ? '浏览商品、连接服务账号并查询订单'
                : '在元宇宙中编辑并保留本地备忘',
            'author': 'FluxDO 社区',
            'repository': 'https://github.com/Lingyan000/fluxdo-plugins',
            'packageUrl': 'https://example.org/plugin.fluxplugin',
            'sha256': 'a' * 64,
            'categories': [item.$3],
            'icon': item.$1.endsWith('ldstore') ? 'storefront' : 'edit',
          }, source),
      ],
    );
  }
}

class _Plugins extends MetaversePluginsController {
  @override
  List<InstalledMetaversePlugin> build() => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const snapshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');
  late SharedPreferences preferences;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    if (!snapshots) return;
    expect(
      await loadPreviewCjkFont(),
      isTrue,
      reason: '截图需要可用的中文字体，可设置 PREVIEW_CJK_FONT',
    );
    expect(await loadPreviewCjkFont(family: 'monospace'), isTrue);
    await (FontLoader('packages/material_symbols_icons/MaterialSymbolsRounded')
          ..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
        .load();
  });
  final capture = GlobalKey();
  Widget app({bool dark = false, double scale = 1, Widget? page}) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    final theme = buildAppTheme(
      ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness),
      AppColors.material(brightness),
      UiShapes.standard,
      const ThemeState(mode: ThemeMode.system, seedColor: Colors.indigo),
      fullscreenSwipeBack: false,
      pageBackground: false,
    );
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        metaverseMarketProvider.overrideWith(_Catalog.new),
        metaversePluginsProvider.overrideWith(_Plugins.new),
      ],
      child: RepaintBoundary(
        key: capture,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            debugShowCheckedModeBanner: false,
            theme: snapshots
                ? theme.copyWith(
                    textTheme: theme.textTheme.apply(fontFamily: 'MiSans'),
                  )
                : theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home:
                page ??
                Builder(
                  builder: (context) => DefaultTabController(
                    length: 2,
                    initialIndex: 1,
                    child: Scaffold(
                      appBar: AppBar(
                        title: Text(context.l10n.metaverse_title),
                        bottom: TabBar(
                          tabs: [
                            Tab(text: context.l10n.metaverse_myServices),
                            Tab(text: context.l10n.metaverse_market),
                          ],
                        ),
                      ),
                      body: const SafeArea(child: MetaverseMarketPage()),
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!snapshots) return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await Directory('build/plugin-ui').create(recursive: true);
      await File('build/plugin-ui/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.4]) {
      testWidgets('市场搜索对齐与详情在明暗主题正常展示 $dark $scale', (tester) async {
        tester.view.physicalSize = Size(scale > 1 ? 320 : 390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(app(dark: dark, scale: scale));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('LD士多'), findsOneWidget);
        expect(find.text('随手记'), findsOneWidget);
        final hintY = tester
            .getCenter(find.text(S.current.metaverse_marketSearch))
            .dy;
        final iconY = tester.getCenter(find.byIcon(Symbols.search_rounded)).dy;
        expect(
          (hintY - iconY).abs(),
          lessThanOrEqualTo(2),
          reason: '搜索提示和图标应垂直居中',
        );
        await screenshot(tester, 'market-${dark ? 'dark' : 'light'}-$scale');
        await tester.enterText(find.byType(TextField), '随手记');
        await tester.pump();
        expect(find.text('LD士多'), findsNothing);
        expect(
          tester.getCenter(find.byIcon(Symbols.search_rounded)).dy,
          tester.getCenter(find.byIcon(Symbols.close_rounded)).dy,
        );
        await tester.tap(find.byTooltip(S.current.common_clear));
        await tester.pump();
        expect(find.text('LD士多'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '随手记');
        await tester.pump();
        await tester.tap(find.text('随手记').last);
        await tester.pumpAndSettle();
        expect(find.byType(MetaverseMarketDetailPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('开发中心收纳在管理菜单并支持中文搜索 $dark', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(dark: dark, page: const MetaversePluginManagementPage()),
      );
      expect(find.text(S.current.metaverse_developerCenter), findsNothing);
      await tester.tap(
        find.byType(SwipeDismissiblePopupMenuButton<VoidCallback>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.current.metaverse_developerCenter));
      await tester.pumpAndSettle();
      expect(find.byType(MetaverseDeveloperPage), findsOneWidget);
      // 页面来自导航栈，截图边界改为直接承载相同页面。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(dark: dark, page: const MetaverseDeveloperPage()),
      );
      await tester.pumpAndSettle();
      await screenshot(tester, 'components-${dark ? 'dark' : 'light'}');
      await tester.enterText(find.byType(TextField), '搜索');
      await tester.pumpAndSettle();
      expect(find.text('ListPage'), findsOneWidget);
      expect(find.text('SearchInput'), findsOneWidget);
      expect(find.text('Button'), findsNothing);
      await tester.tap(find.text(S.current.metaverse_developerGuides));
      await tester.pumpAndSettle();
      expect(
        find.text(S.current.metaverse_developerLanguageTitle),
        findsOneWidget,
      );
      await screenshot(tester, 'guides-${dark ? 'dark' : 'light'}');
      expect(tester.takeException(), isNull);
    });
  }
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.4]) {
      testWidgets('市场源输入与校验 $dark $scale', (tester) async {
        tester.view.physicalSize = Size(scale > 1 ? 320 : 390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          app(
            dark: dark,
            scale: scale,
            page: const MetaverseMarketSourcesPage(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Lingyan000/fluxdo-plugins'), findsOneWidget);
        final field = find.byType(TextField);
        final hint = find.text('https://github.com/owner/repo');
        expect(
          (tester.getCenter(hint).dy -
                  tester.getCenter(find.byIcon(Symbols.link_rounded)).dy)
              .abs(),
          lessThanOrEqualTo(2),
        );
        await screenshot(tester, 'sources-$dark-$scale');
        await tester.enterText(field, 'invalid');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(
          find.text(S.current.metaverse_marketSourceInvalid),
          findsOneWidget,
        );
        await tester.enterText(field, 'https://github.com/example/catalog');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.text('example/catalog'), findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(
          find.text(S.current.metaverse_marketSourceInvalid),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('API 搜索详情与真实 Toast $dark', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(dark: dark, page: const MetaverseDeveloperPage()),
      );
      await tester.tap(find.text(S.current.metaverse_developerApis));
      await tester.pumpAndSettle();
      await screenshot(tester, 'api-list-$dark');
      await tester.enterText(find.byType(TextField), 'toast');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'toast'), findsOneWidget);
      expect(find.text('storage.get'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'toast'));
      await tester.pumpAndSettle();
      expect(find.byType(MetaverseApiPreviewPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          dark: dark,
          page: MetaverseApiPreviewPage(
            example: metaverseApiExamples.firstWhere((e) => e.name == 'toast'),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '交互演示已触发');
      await tester.tap(find.text('success'));
      final run = find.widgetWithText(
        FilledButton,
        S.current.metaverse_developerRun,
      );
      await tester.ensureVisible(run);
      await tester.tap(run);
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        if (tester.widget<FilledButton>(run).onPressed != null &&
            find
                .text(
                  S.current.metaverse_pluginToast(
                    S.current.metaverse_developerExample,
                    '交互演示已触发',
                  ),
                )
                .evaluate()
                .isNotEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text(
          S.current.metaverse_pluginToast(
            S.current.metaverse_developerExample,
            '交互演示已触发',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(run).onPressed, isNotNull);
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pump();
      await screenshot(tester, 'api-toast-$dark');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.current.metaverse_developerSimulateFailure));
      await tester.pump();
      await tester.ensureVisible(run);
      await tester.tap(run);
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        if (tester.widget<FilledButton>(run).onPressed != null) break;
      }
      expect(
        find.text(
          S.current.metaverse_pluginToast(
            S.current.metaverse_developerExample,
            '交互演示已触发',
          ),
        ),
        findsNothing,
      );
      await tester.ensureVisible(find.text(S.current.metaverse_apiResult));
      expect(find.text('demo_permission_denied'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  }

  testWidgets('支付 API 演示使用内存订单完成收银台交互', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(
        page: MetaverseApiPreviewPage(
          example: metaverseApiExamples.firstWhere(
            (e) => e.name == 'payments.request',
          ),
        ),
      ),
    );
    final run = find.widgetWithText(
      FilledButton,
      S.current.metaverse_developerRun,
    );
    await tester.ensureVisible(run);
    await tester.tap(run);
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      if (find.byType(PinInput).evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(seconds: 1));
    await screenshot(tester, 'api-payment-initial');
    expect(find.byType(PinInput), findsOneWidget, reason: tester.widgetList<SelectableText>(find.byType(SelectableText)).map((w) => w.data).join('\n'));
    expect(find.text(S.current.metaverse_apiPaymentDemo), findsOneWidget);
    for (final digit in ['1', '2', '3', '4', '5', '6']) {
      await tester.tap(find.byKey(ValueKey('ldc-key-$digit')));
      await tester.pump();
    }
    await tester.tap(find.text(S.current.metaverse_nativePayConfirm('1.00')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(S.current.metaverse_nativePaySuccess), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await screenshot(tester, 'api-payment-success');
    await tester.tap(find.text(S.current.metaverse_nativePayViewOrder));
    await tester.pump(const Duration(seconds: 1));
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      if (tester.widget<FilledButton>(run).onPressed != null) break;
    }
    await tester.ensureVisible(find.text(S.current.metaverse_apiResult));
    expect(find.textContaining('"state": "paid"'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
