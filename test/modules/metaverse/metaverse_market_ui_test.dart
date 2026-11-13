import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
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
  setUpAll(() async {
    if (!snapshots) return;
    expect(
      await loadPreviewCjkFont(),
      isTrue,
      reason: '截图需要可用的中文字体，可设置 PREVIEW_CJK_FONT',
    );
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
        metaverseMarketProvider.overrideWith(_Catalog.new),
        metaversePluginsProvider.overrideWith(_Plugins.new),
      ],
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
          home: RepaintBoundary(
            key: capture,
            child:
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
}
