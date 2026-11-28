import 'package:fluxdo/pages/metaverse_page.dart';
import 'package:fluxdo/modules/metaverse/core/metaverse_service.dart';
import 'package:fluxdo/modules/metaverse/metaverse_registry.dart';
import 'package:fluxdo/modules/metaverse/metaverse_link_router.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_catalog.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_page.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_provider.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_provider.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_management_page.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_card_layout_page.dart';
import 'package:fluxdo/modules/metaverse/developer/metaverse_development_page.dart';
import 'package:fluxdo/modules/metaverse/developer/session/development_session.dart';

import '../../helpers/preview_fonts.dart';
import 'metaverse_auto_update_test.dart' show updateSource;

late MetaversePluginPackage _target;
late MetaverseMarketEntry _entry;
late Map<String, dynamic> _entryJson;

class _CardService extends MetaversePluginService {
  const _CardService(super.plugin);
  @override
  Widget buildCard(BuildContext context, MetaverseCardHost host) =>
      Text('card:$id');
}

class _Catalog extends MetaverseMarketController {
  @override
  MetaverseMarketState build() =>
      MetaverseMarketState(sources: [updateSource], entries: [_entry]);
  @override
  Future<void> refresh({bool force = false}) async {}
  @override
  Future<MetaversePluginPackage> download(MetaverseMarketEntry entry) async =>
      _target;
}

class _Account extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

class _Updates extends MetaverseUpdatesController {
  @override
  Future<MetaverseUpdateState> build() async => const MetaverseUpdateState();
  void report(String id, String source) => state = AsyncData(
    MetaverseUpdateState(
      reports: {
        id: {'source': source, 'status': 'review'},
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const snapshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');
  late Directory root;
  late ProviderContainer container;
  late InstalledMetaversePlugin installed;
  late SharedPreferences prefs;
  final boundary = GlobalKey();
  setUpAll(() async {
    if (snapshots) {
      expect(await loadPreviewCjkFont(), isTrue);
      final icon = Symbols.extension_rounded;
      await (FontLoader(
            'packages/${icon.fontPackage}/${icon.fontFamily}',
          )..addFont(
            rootBundle.load(
              'packages/${icon.fontPackage}/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
          .load();
    }
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plugin-followup-ui-');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        currentUserProvider.overrideWith(_Account.new),
        metaversePluginDirectoryProvider.overrideWith((_) async => root),
        metaverseMarketProvider.overrideWith(_Catalog.new),
        metaverseUpdatesProvider.overrideWith(_Updates.new),
        metaverseTaskDriverProvider.overrideWithValue(null),
        metaverseServicesProvider.overrideWith(
          (ref) => [
            for (final p in ref.watch(metaversePluginsProvider))
              _CardService(p),
          ],
        ),
      ],
    );
    final network = MetaversePluginNetwork();
    final installer = MetaversePluginInstaller(network: network);
    final previous = await installer.importBundle(
      File('test/fixtures/metaverse/ld-store-2.9.3.fluxplugin').openRead(),
      source: updateSource.id,
    );
    _target = await installer.importBundle(
      File('test/fixtures/metaverse/release/ld-store-1.0.0.fluxplugin')
          .openRead(),
      source: updateSource.id,
    );
    network.dispose();
    installed = await container
        .read(metaversePluginsProvider.notifier)
        .install(previous);
    await container
        .read(metaversePluginsProvider.notifier)
        .setEnabled(installed.id, enabled: true);
    installed = container
        .read(metaversePluginsProvider.notifier)
        .byId(installed.id)!;
    await container
        .read(metaversePluginStoreProvider)
        .updateStorage(installed.id, 'draft', 'retain');
    _entryJson = {
      'id': _target.manifest.id,
      'name': _target.manifest.name,
      'author': _target.manifest.author,
      'summary': '原生插件的首发版本',
      'version': '1.0.0',
      'apiVersion': 2,
      'repository': 'https://github.com/example/plugins',
      'packageUrl': 'https://example.org/plugin.fluxplugin',
      'sha256': 'a' * 64,
      'publisherKeyFingerprint': _target.signature!.fingerprint,
      'permissionsSummary': {
        'permissions': _target.manifest.declaredPermissions
            .map((p) => p.name)
            .toList(),
        'networkHosts': _target.manifest.networkHosts,
        'linkHosts': _target.manifest.linkHosts,
      },
    };
    _entry = MetaverseMarketEntry.parse(_entryJson, updateSource);
  });
  tearDown(() async {
    container.dispose();
    await root.delete(recursive: true);
  });

  Widget app(Widget page, {bool dark = false, double scale = 1,
      bool background = false}) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    var theme = buildAppTheme(
      ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness),
      AppColors.material(brightness),
      UiShapes.standard,
      const ThemeState(mode: ThemeMode.system, seedColor: Colors.indigo),
      fullscreenSwipeBack: false,
      pageBackground: background,
    );
    if (snapshots) {
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'MiSans'),
      );
    }
    return UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: theme,
            debugShowCheckedModeBanner: false,
            builder: (ctx, child) => PageBackgroundScope(
              backgroundBuilder: background ? (_) => DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [theme.colorScheme.surface, theme.colorScheme.secondaryContainer],
                )),
              ) : null,
              child: MediaQuery(
                data: MediaQuery.of(ctx)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            home: RoutePageBackground(child: page),
          ),
        ),
      ),
    );
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!snapshots) return;
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await Directory('build/plugin-followup-ui').create(recursive: true);
      await File('build/plugin-followup-ui/$name.png')
          .writeAsBytes(png!.buffer.asUint8List());
    });
  }

  for (final dark in [false, true]) {
    testWidgets('重置链接偏好菜单与确认框，小屏大字 $dark', (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = container.read(metaversePluginsProvider.notifier);
      await controller.setPermission(installed.id, MetaversePluginPermission.links, true);
      final defaults = container.read(metaverseLinkDefaultsProvider.notifier);
      final host = _target.manifest.linkHosts.first;
      await defaults.remember(host, MetaverseLinkDefaults.browser);
      await tester.pumpWidget(app(const MetaversePluginManagementPage(),
        dark: dark, scale: 1.4));
      await tester.pumpAndSettle();
      final menu = find.byType(SwipeDismissiblePopupMenuButton<VoidCallback>);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text(S.current.metaverse_resetLinkDefaults), findsOneWidget);
      await capture(tester, 'link-reset-menu-${dark ? 'dark' : 'light'}');
      await tester.tap(find.text(S.current.metaverse_resetLinkDefaults));
      await tester.pumpAndSettle();
      expect(find.text(S.current.metaverse_resetLinkDefaultsConfirm), findsOneWidget);
      await capture(tester, 'link-reset-dialog-${dark ? 'dark' : 'light'}');
      await tester.tap(find.text(S.current.common_cancel));
      await tester.pumpAndSettle();
      expect(container.read(metaverseLinkDefaultsProvider), {
        host: MetaverseLinkDefaults.browser,
      });
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.current.metaverse_resetLinkDefaults));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.current.common_reset));
      await tester.pumpAndSettle();
      expect(container.read(metaverseLinkDefaultsProvider), isEmpty);
      expect(prefs.getString(MetaverseLinkDefaults.preferenceKey), '{}');
      expect(find.text(S.current.metaverse_linkDefaultsReset), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text(S.current.metaverse_resetLinkDefaults), findsNothing);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    for (final background in [false, true]) {
      testWidgets('市场详情卡片背景一致，dark=$dark background=$background', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app(MetaverseMarketDetailPage(entry: _entry),
          dark: dark, background: background));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(S.current.metaverse_marketCompatibility));
        await tester.pumpAndSettle();
        await capture(tester, 'market-background-$background-${dark ? 'dark' : 'light'}');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('版本替换审阅与权限预览，小屏大字 $dark', (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(MetaverseMarketDetailPage(entry: _entry), dark: dark, scale: 1.4),
      );
      await tester.pumpAndSettle();
      expect(find.text(S.current.metaverse_publisherSigned), findsOneWidget);
      await capture(tester, 'market-${dark ? 'dark' : 'light'}');
      await tester.tap(find.byType(SwipeDismissiblePopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.current.metaverse_switchVersion('1.0.0')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        find.text(S.current.metaverse_replaceConfirm).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          S.current.metaverse_replaceReview('2.9.3', '1.0.0'),
        ),
        findsOneWidget,
      );
      await capture(tester, 'review-${dark ? 'dark' : 'light'}');
      await tester.tap(find.text(S.current.metaverse_replaceConfirm));
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 &&
              container
                      .read(metaversePluginsProvider.notifier)
                      .byId(installed.id)!
                      .manifest
                      .version !=
                  '1.0.0';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      final next = container
          .read(metaversePluginsProvider.notifier)
          .byId(installed.id)!;
      expect(next.manifest.version, '1.0.0');
      expect(next.enabled, isTrue);
      expect(next.blockedPermissions, installed.blockedPermissions);
      expect(
        await tester.runAsync(
          () => container
              .read(metaversePluginStoreProvider)
              .readStorage(installed.id),
        ),
        containsPair('draft', 'retain'),
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('同源无签名已安装插件隐藏版本替换入口', (tester) async {
    final controller = container.read(metaversePluginsProvider.notifier);
    await tester.runAsync(() async {
      await controller.remove(installed.id);
      final unsigned = await controller.install(MetaversePluginPackage(
        manifest: _target.manifest, source: updateSource.id, code: _target.code,
      ));
      expect(unsigned.publisherKey, isNull);
    });
    await tester.pumpWidget(app(MetaverseMarketDetailPage(entry: _entry)));
    await tester.pumpAndSettle();
    expect(find.byType(SwipeDismissiblePopupMenuButton<String>), findsNothing);
    expect(find.text(S.current.metaverse_pluginManage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final reason in ['withdrawn', 'incompatible']) {
    testWidgets('$reason 市场条目不允许版本替换', (tester) async {
      _entry = MetaverseMarketEntry.parse({
        ..._entryJson,
        if (reason == 'withdrawn') 'withdrawn': true,
        if (reason == 'incompatible') 'requiredFeatures': ['futureCapability'],
      }, updateSource);
      await tester.pumpWidget(app(MetaverseMarketDetailPage(entry: _entry)));
      await tester.pumpAndSettle();
      expect(
        find.byType(SwipeDismissiblePopupMenuButton<String>),
        findsNothing,
      );
    });
  }
  for (final preview in ['unknown', 'unsigned']) {
    testWidgets('市场发布者预览 $preview 不混淆签名状态', (tester) async {
      final raw = {..._entryJson};
      if (preview == 'unknown') {
        raw.remove('publisherKeyFingerprint');
      } else {
        raw['publisherKeyFingerprint'] = null;
      }
      _entry = MetaverseMarketEntry.parse(raw, updateSource);
      await tester.pumpWidget(app(MetaverseMarketDetailPage(entry: _entry)));
      await tester.pumpAndSettle();
      expect(
        find.text(
          preview == 'unknown'
              ? S.current.metaverse_publisherPending
              : S.current.metaverse_publisherUnsigned,
        ),
        findsOneWidget,
      );
      expect(find.text(S.current.metaverse_publisherSigned), findsNothing);
    });
  }
  testWidgets('首页隐藏卡片且管理角标按插件去重', (tester) async {
    await container.read(metaverseUpdatesProvider.future);
    await tester.pumpWidget(app(const MetaversePage()));
    await tester.pumpAndSettle();
    expect(find.text('card:${installed.id}'), findsOneWidget);
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
    await container
        .read(metaverseCardLayoutProvider.notifier)
        .setVisible(installed.id, false);
    await tester.pumpAndSettle();
    expect(find.text('card:${installed.id}'), findsNothing);
    expect(container.read(metaversePluginsProvider).single.enabled, isTrue);
    (container.read(metaverseUpdatesProvider.notifier) as _Updates).report(
      installed.id,
      installed.source,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
    await tester.runAsync(
      () => container
          .read(metaversePluginsProvider.notifier)
          .suspend(installed.id, 'test_timeout'),
    );
    await tester.pumpAndSettle();
    expect(container.read(metaverseAttentionProvider).length, 1);
  });

  testWidgets('卡片隐藏不关闭插件，暂停状态与更新状态可识别', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const MetaverseCardLayoutPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_target.manifest.name));
    await tester.pumpAndSettle();
    expect(container.read(metaverseCardLayoutProvider).single.visible, isFalse);
    expect(container.read(metaversePluginsProvider).single.enabled, isTrue);
    await capture(tester, 'cards');
    final updates =
        container.read(metaverseUpdatesProvider.notifier) as _Updates;
    await container.read(metaverseUpdatesProvider.future);
    updates.report(installed.id, installed.source);
    expect(container.read(metaverseAttentionProvider), {installed.id});
    await tester.runAsync(
      () => container
          .read(metaversePluginsProvider.notifier)
          .suspend(installed.id, 'test_timeout'),
    );
    await tester.pumpWidget(app(const MetaversePluginManagementPage()));
    await tester.pumpAndSettle();
    expect(find.text(S.current.metaverse_pluginLogs), findsOneWidget);
    expect(find.text(S.current.metaverse_resumePlugin), findsOneWidget);
    await capture(tester, 'management');
    await tester.tap(find.text(S.current.metaverse_resumePlugin));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(metaversePluginsProvider).single.suspendedReason,
      isNull,
    );
    expect(find.text(S.current.metaverse_updateReview), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('扫码先填入等待连接，非法协议和缺指纹不能覆盖地址', (tester) async {
    var result =
        'fluxdo-dev://192.168.1.2:5174?key=${'k' * 32}&cert=${'a' * 64}';
    await tester.pumpWidget(
      app(MetaverseDevelopmentPage(scanPairing: (_) async => result)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.metaverse_scanPairing));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, result);
    final valid = result;
    for (final bad in [
      'https://example.org/',
      'fluxdo-dev://192.168.1.2:5174?key=${'k' * 32}',
    ]) {
      result = bad;
      await tester.tap(find.text(S.current.metaverse_scanPairing));
      await tester.pumpAndSettle();
      expect(field.controller!.text, valid);
    }
    expect(container.read(metaverseDevelopmentSessionProvider).state, 'idle');
    await capture(tester, 'pairing');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    container.invalidate(metaverseDevelopmentSessionProvider);
    await tester.pump();
  });
}
