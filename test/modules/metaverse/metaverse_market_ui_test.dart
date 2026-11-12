import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_catalog.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_page.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_provider.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;

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
  Widget app({bool dark = false, double scale = 1}) => ProviderScope(
    overrides: [
      metaverseMarketProvider.overrideWith(_Catalog.new),
      metaversePluginsProvider.overrideWith(_Plugins.new),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          fontFamily: snapshots ? 'MiSans' : null,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: capture,
          child: const Scaffold(body: SafeArea(child: MetaverseMarketPage())),
        ),
      ),
    ),
  );

  for (final dark in [false, true]) {
    testWidgets('市场搜索与详情在窄屏、大字和明暗主题正常展示 $dark', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(dark: dark, scale: 1.4));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('LD士多'), findsOneWidget);
      expect(find.text('随手记'), findsOneWidget);
      if (const bool.fromEnvironment('PLUGIN_SNAPSHOTS')) {
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory('build/plugin-ui').create(recursive: true);
          await File('build/plugin-ui/market-${dark ? 'dark' : 'light'}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await tester.enterText(find.byType(TextField), '随手记');
      await tester.pump();
      expect(find.text('LD士多'), findsNothing);
      await tester.tap(find.text('随手记').last);
      await tester.pumpAndSettle();
      expect(find.byType(MetaverseMarketDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
