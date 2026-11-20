import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/navigation/nav_entries_provider.dart';
import 'package:fluxdo/navigation/nav_entry_registry.dart';
import 'package:fluxdo/pages/bottom_nav_settings_page.dart';
import 'package:fluxdo/pages/metaverse_page.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/navigation/navigation_activity_scope.dart';
import 'package:fluxdo/modules/metaverse/core/metaverse_service.dart';
import 'package:fluxdo/modules/metaverse/metaverse_registry.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_provider.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_dialogs.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/preview_fonts.dart';

class _User extends CurrentUserNotifier {
  @override
  Future<User?> build() async => User.fromJson({'id': 1, 'username': 'demo'});
}

class _Service extends MetaverseService {
  int refreshes = 0;
  @override
  String get id => 'test.service';
  @override
  bool isEnabled(ProviderContainer container) => true;
  @override
  Widget buildCard(BuildContext context, MetaverseCardHost host) =>
      const SizedBox(height: 1800);
  @override
  Future<void> refresh(
    ProviderContainer container, {
    required bool Function() isActive,
  }) async {
    if (isActive()) refreshes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Market extends MetaverseMarketController {
  int refreshes = 0;
  @override
  MetaverseMarketState build() => const MetaverseMarketState(sources: []);
  @override
  Future<void> refresh({bool force = false}) async {
    refreshes++;
  }
}

class _Plugins extends MetaversePluginsController {
  @override
  List<InstalledMetaversePlugin> build() => [];
}

class _Hosts implements MetaversePluginHosts {
  int refreshes = 0;
  @override
  void refreshVisibleCards() {
    refreshes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('元宇宙入口按当前子页回顶和刷新，隐藏时不响应底栏动作', (tester) async {
    final service = _Service(), market = _Market(), hosts = _Hosts();
    final container = ProviderContainer(
      overrides: [
        metaverseServicesProvider.overrideWithValue([service]),
        metaverseMarketProvider.overrideWith(() => market),
        metaversePluginsProvider.overrideWith(_Plugins.new),
        metaversePluginHostsProvider.overrideWithValue(hosts),
      ],
    );
    addTearDown(container.dispose);
    var active = true;
    late StateSetter update;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return NavigationActivityScope(
                  active: active,
                  child: const MetaversePage(workspace: true),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.refreshes, 1);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(400);
    container.read(navActionBusProvider.notifier).state = const NavActionEvent(
      targetId: NavEntryIds.metaverse,
      action: NavAction.scrollToTop,
      nonce: 1,
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    container.read(navActionBusProvider.notifier).state = const NavActionEvent(
      targetId: NavEntryIds.metaverse,
      action: NavAction.refresh,
      nonce: 2,
    );
    await tester.pumpAndSettle();
    expect(service.refreshes, 2);
    expect(hosts.refreshes, 1);
    await tester.tap(find.text(S.current.metaverse_market));
    await tester.pumpAndSettle();
    // 页面首次进入读取市场，随后底栏操作应只额外刷新一次。
    expect(market.refreshes, 1);
    container.read(navActionBusProvider.notifier).state = const NavActionEvent(
      targetId: NavEntryIds.metaverse,
      action: NavAction.refresh,
      nonce: 3,
    );
    await tester.pumpAndSettle();
    expect(market.refreshes, 2);
    expect(service.refreshes, 2);
    update(() {
      active = false;
    });
    await tester.pump();
    container.read(navActionBusProvider.notifier).state = const NavActionEvent(
      targetId: NavEntryIds.metaverse,
      action: NavAction.refresh,
      nonce: 4,
    );
    await tester.pump();
    expect(market.refreshes, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  const snapshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');
  final m = MetaversePluginManifest.parse(
    jsonDecode(
      File('test/fixtures/metaverse/forum-activity/plugin.json')
          .readAsStringSync(),
    ),
  );
  setUpAll(() async {
    if (!snapshots) return;
    expect(await loadPreviewCjkFont(), isTrue);
    await (FontLoader('packages/material_symbols_icons/MaterialSymbolsRounded')
          ..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final dark in [false, true]) {
    testWidgets('底栏编辑保留失效入口，能添加元宇宙和插件，权限弹框可滚动 dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'pref_bottom_nav_ids': ['home', 'plugin:missing.plugin:old', 'profile'],
      });
      final prefs = await SharedPreferences.getInstance();
      final brightness = dark ? Brightness.dark : Brightness.light;
      final theme = buildAppTheme(
        ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness),
        AppColors.material(brightness),
        UiShapes.standard,
        const ThemeState(mode: ThemeMode.system, seedColor: Colors.indigo),
        fullscreenSwipeBack: false,
        pageBackground: false,
      );
      final capture = GlobalKey();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUserProvider.overrideWith(_User.new),
          navEntriesProvider.overrideWithValue([
            ...NavEntryRegistry.buildAll(),
            ...pluginNavigationEntries([
              InstalledMetaversePlugin(
                manifest: m,
                source: 'file',
                enabled: true,
              ),
            ]),
          ]),
        ],
      );
      addTearDown(container.dispose);
      Widget app(Widget child) => UncontrolledProviderScope(
        container: container,
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
                    .copyWith(textScaler: TextScaler.linear(dark ? 1.4 : 1)),
                child: child!,
              ),
              home: child,
            ),
          ),
        ),
      );
      Future<void> screenshot(String name) async {
        if (!snapshots) return;
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/plugin-navigation-ui/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.pumpWidget(app(const BottomNavSettingsPage()));
      await tester.pumpAndSettle();
      final l = S.current;
      expect(find.text(l.metaverse_navigationUnavailable), findsOneWidget);
      await tester.tap(find.text(l.metaverse_title));
      await tester.pumpAndSettle();
      expect(container.read(preferencesProvider).bottomNavIds, [
        'home',
        'plugin:missing.plugin:old',
        'profile',
        'metaverse',
      ]);
      final pluginEntry = find.ancestor(
        of: find.text(m.name),
        matching: find.widgetWithText(ListTile, '动态'),
      );
      await tester.scrollUntilVisible(
        pluginEntry,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      while (pluginEntry.hitTestable().evaluate().isEmpty) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -200));
        await tester.pumpAndSettle();
      }
      await tester.tap(pluginEntry.hitTestable());
      await tester.pumpAndSettle();
      expect(
        container.read(preferencesProvider).bottomNavIds.last,
        'plugin:example.forum.activity:activity',
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot('navigation-${dark ? 'dark-large' : 'light'}');
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showMetaversePluginInstallSheet(
                    context,
                    m,
                    isUpdate: false,
                  ),
                  child: const Text('Review'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text(l.metaverse_forumProfiles), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot('permission-${dark ? 'dark-large' : 'light'}');
      await tester.tap(find.text(l.common_cancel));
      await tester.pumpAndSettle();
    });
  }
}
