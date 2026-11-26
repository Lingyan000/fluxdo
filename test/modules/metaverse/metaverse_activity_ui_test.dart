import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/metaverse/host/metaverse_forum_adapter.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_forum_request.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_service.dart';
import 'package:fluxdo/modules/metaverse/core/metaverse_service.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_page.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/navigation/app_route_observer.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/preview_fonts.dart';

const _bundle = 'test/fixtures/metaverse/release/activity-feed-1.0.0.fluxplugin';
const _plugin = 'community.fluxdo.activity';
const _screenshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');

class _Account extends CurrentUserNotifier {
  @override
  Future<User?> build() async => User.fromJson({'id': 7, 'username': 'reader'});
}

class _Forum extends Fake implements MetaverseForumAdapter {
  final reads = <MetaverseForumResource>[];
  @override
  Future<Object?> read(
    String id,
    MetaverseForumRequest request, {
    required void Function() checkActive,
  }) async {
    checkActive();
    reads.add(request.resource);
    if (request.resource == MetaverseForumResource.user) {
      return {'id': 9, 'username': request.username};
    }
    return {
      'items': [
        if (request.resource == MetaverseForumResource.actions)
          {
            'id': 'one',
            'topicId': 14,
            'createdAt': '2026-10-01T12:00:00Z',
            'action': 'topics',
            'title': '第一条动态',
          },
      ],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    (WidgetsBinding.instance as TestWidgetsFlutterBinding).platformDispatcher.localeTestValue = const Locale('zh');
  });
  tearDown(() {
    (WidgetsBinding.instance as TestWidgetsFlutterBinding).platformDispatcher.clearLocaleTestValue();
  });
  final capture = GlobalKey();
  setUpAll(() async {
    if (!_screenshots) return;
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
  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!_screenshots) return;
    await tester.runAsync(() async {
      final picture = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(capture))
          .toImage();
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      final file = File('build/activity-ui/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Widget app(Widget home, {bool dark = false, double scale = 1}) {
    final light = dark ? Brightness.dark : Brightness.light;
    const seed = Colors.indigo;
    final theme = buildAppTheme(
      ColorScheme.fromSeed(seedColor: seed, brightness: light),
      AppColors.material(light),
      UiShapes.standard,
      const ThemeState(mode: ThemeMode.system, seedColor: seed),
      fullscreenSwipeBack: false,
      pageBackground: false,
    );
    return RepaintBoundary(
      key: capture,
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [appRouteObserver],
          debugShowCheckedModeBanner: false,
          theme: _screenshots
              ? theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'MiSans'),
                )
              : theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
  }

  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final wide in [false, true]) {
    testWidgets('发行包使用横向头像或双栏名单，列表和头像各有点击目标 wide=$wide', (tester) async {
      size(tester, wide ? const Size(1120, 720) : const Size(360, 780));
      final bundle = jsonDecode(File(_bundle).readAsStringSync());
      final runtime = Runtime()
        ..update(
          metaverseWidgetLibraryName,
          createMetaverseWidgetLibrary(
            loadImage: (_) async => throw StateError('离线'),
          ),
        )
        ..update(
          metaversePluginLibraryName,
          parseLibraryFile((bundle['files']['ui.rfwtxt'] as String).replaceAll('\r\n','\n')),
        );
      addTearDown(runtime.dispose);
      final people = ['', '林间', 'mori', '小禾'];
      final headlines = [
        '分享一个离线阅读的小工具',
        '关于字体在小屏幕上的显示',
        '周末的社区活动有人参加吗',
        '整理了最近读过的开源项目',
      ];
      final excerpts = [
        '把想读的话题留在本地，通勤没有网络时也能打开。',
        '调了一下行距，大字模式下读长文舒服多了。',
        '这次会聊到本地优先的应用设计。',
        '附上了项目介绍，也欢迎大家补充。',
      ];
      final data = DynamicContent({
        'i18n': (jsonDecode(File('test/fixtures/metaverse/activity-feed-locales.json').readAsStringSync()) as Map)['zh'],
        'title': '3 位订阅 · 2 条未读',
        'hasUsers': true,
        'more': false,
        'people': [
          for (var i = 0; i < people.length; i++)
            {
              'name': people[i],
              'label': i == 0 ? '全部' : people[i],
              'count': i < 2 ? 2 : 0,
              'selected': i == 0,
              'avatar': '',
            },
        ],
        'types': [
          for (final name in ['全部', '发帖', '回复', '赞', '回应', 'Boost'])
            {'id': name, 'label': name, 'selected': name == '全部'},
        ],
        'hasUnread': true,
        'unreadOnly': false,
        'manual': false,
        'needsActivity': false,
        'error': '',
        'scheduleError': '',
        'items': [
          for (var i = 0; i < headlines.length; i++)
            {
              'name': people[1 + i % 3],
              'avatar': '',
              'title': headlines[i],
              'summary': excerpts[i],
              'meta': '${people[1 + i % 3]} · ${i.isEven ? '发帖 · 未读' : '回复'}',
              'time': DateTime.now()
                  .toUtc()
                  .subtract(Duration(minutes: i * 15 + 2))
                  .toIso8601String(),
              'id': '$i',
              'owner': 1,
              'topic': i + 1,
              'post': 1,
            },
        ],
      });
      final events = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          child: app(
            Scaffold(
              appBar: AppBar(title: const Text('动态订阅')),
              body: RemoteWidget(
                runtime: runtime,
                widget: const FullyQualifiedWidgetName(
                  metaversePluginLibraryName,
                  'Feed',
                ),
                data: data,
                onEvent: (name, _) => events.add(name),
              ),
            ),
            scale: wide ? 1 : 1.35,
            dark: wide,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('我的订阅'), wide ? findsOneWidget : findsNothing);
      expect(find.text(excerpts.first).hitTestable(), findsOneWidget);
      await tester.tap(find.text('林间').first);
      await tester.tap(find.text('未读'));
      await tester.tap(find.text(headlines.first));
      final avatar = find
            .ancestor(
              of: find.text('林').hitTestable().last,
              matching: find.byType(GestureDetector),
            )
            .first;
      await tester.tap(avatar);
      expect(
        events,
        containsAllInOrder(['select', 'unread', 'topic', 'profile']),
      );
      expect(tester.takeException(), isNull);
      await snapshot(tester, wide ? 'desktop-dark' : 'mobile-large');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  final settingsFixtures = jsonDecode(File('test/fixtures/metaverse/activity-feed-settings.json').readAsStringSync()) as List;
  for (final fixture in settingsFixtures) {
    final locale = fixture['locale'] as String, name = fixture['widget'] as String;
    testWidgets('订阅管理与名单导入四语小屏 $locale/$name', (tester) async {
      size(tester, const Size(320, 720));
      final bundle = jsonDecode(File(_bundle).readAsStringSync());
      final runtime = Runtime()
        ..update(metaverseWidgetLibraryName, createMetaverseWidgetLibrary(loadImage: (_) async => throw StateError('离线')))
        ..update(metaversePluginLibraryName, parseLibraryFile(
          (bundle['files']['ui.rfwtxt'] as String).replaceAll('\r\n', '\n')));
      addTearDown(runtime.dispose);
      final model = Map<String, Object?>.from(fixture['data'] as Map);
      final events = <String>[];
      await tester.pumpWidget(app(Scaffold(
        appBar: AppBar(title: Text(model['pageTitle'] as String)),
        body: RemoteWidget(runtime: runtime,
          widget: FullyQualifiedWidgetName(metaversePluginLibraryName, name),
          data: DynamicContent(model), onEvent: (name, _) => events.add(name)),
      ), dark: locale == 'en' || locale == 'zh-HK', scale: 1.4));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (name == 'BulkImport') {
        expect(find.byType(FilledButton).hitTestable(), findsOneWidget);
        await tester.tap(find.byType(FilledButton));
        expect(events, ['bulkApply']);
      } else {
        final catalogs = jsonDecode(File('test/fixtures/metaverse/activity-feed-locales.json').readAsStringSync()) as Map;
        final key = (catalogs['zh'] as Map).entries.firstWhere((entry) => entry.value == '系统设置').key;
        final button = find.text((model['i18n'] as Map)[key] as String);
        await tester.scrollUntilVisible(button, 160, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        await tester.tap(button);
        expect(events, ['notificationSettings']);
      }
      await snapshot(tester, 'settings-$locale-$name');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('整卡入口与菜单独立，页面按需授权后返回动态', (tester) async {
    size(tester, const Size(360, 780));
    final forum = _Forum();
    SharedPreferences.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('activity-sheet-');
    final prefs = await SharedPreferences.getInstance();
    late IsolateScriptEngine engine;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(_Account.new),
        sharedPreferencesProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        metaversePluginDirectoryProvider.overrideWith((_) async => root),
        metaverseScriptEngineFactoryProvider.overrideWithValue(
          () async => engine = await IsolateScriptEngine.spawn(),
        ),
        metaverseForumAdapterProvider.overrideWithValue(forum),
        metaverseTaskDriverProvider.overrideWithValue(null),
      ],
    );
    addTearDown(() {
      container.dispose();
      root.deleteSync(recursive: true);
    });
    final plugins = container.read(metaversePluginsProvider.notifier);
    await tester.runAsync(() async {
      await container.read(currentUserProvider.future);
      final package = await MetaversePluginInstaller(
        network: container.read(metaversePluginNetworkProvider),
      ).importBundle(File(_bundle).openRead());
      await plugins.install(
        package,
        choices: {MetaversePluginPermission.forumProfiles: true},
      );
      await plugins.setEnabled(_plugin, enabled: true);
      (await container.read(metaverseTaskStoreProvider.future)).sync(
        accountId: 7,
        username: 'reader',
        plugins: [plugins.byId(_plugin)!],
      );
    });
    Future<void> until(Finder finder) async {
      for (var i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        if (finder.hitTestable().evaluate().isNotEmpty) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 12)),
        );
      }
      fail(
        '没有显示 $finder，页面文字 ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().join(' / ')}',
      );
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: app(
          Scaffold(body: Padding(padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(child: MetaversePluginCard(
              service: MetaversePluginService(plugins.byId(_plugin)!),
              host: MetaverseCardHost(isProcessing:false,onDisable:(){},onReauthorize:(){}),
            )))),
        ),
      ),
    );
    await until(find.text('订阅用户'));
    await tester.pumpAndSettle();
    expect(find.byType(MetaversePluginPage),findsNothing);
    expect(find.text('进入动态'),findsNothing);
    await snapshot(tester,'service-card');
    await tester.tap(find.byType(SwipeDismissiblePopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text(S.current.metaverse_permissionSettings),findsOneWidget);
    expect(find.byType(MetaversePluginPage),findsNothing);
    navigatorKey.currentState!.pop();await tester.pumpAndSettle();
    // 卡片下方的统计和标题都能打开页面，菜单不参与整卡点击。
    await tester.tap(find.text('订阅用户'));
    await until(find.text('添加用户'));
    expect(find.text(S.current.metaverse_thirdParty),findsNothing);
    expect(find.byType(AppBar),findsOneWidget);
    expect(tester.widget<AppBar>(find.byType(AppBar)).actions,isEmpty);
    navigatorKey.currentState!.pop();await tester.pumpAndSettle();
    await until(find.text('订阅用户'));
    await tester.tap(find.text('动态订阅'));
    await until(find.text('添加用户'));
    await tester.tap(find.text('添加用户'));
    await until(find.text('订阅此人'));
    await tester.enterText(find.byType(TextField), 'mori');
    await tester.tap(find.text('订阅此人'));
    final allow = find.text(S.current.common_allow);
    await until(allow);
    expect(
      find.text(S.current.metaverse_permissionForumActivity),
      findsOneWidget,
    );
    expect(find.text(S.current.metaverse_permissionIdentity), findsOneWidget);
    expect(find.text(S.current.metaverse_forumProfiles), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    await snapshot(tester, 'request-permission');
    await tester.tap(find.text(S.current.common_cancel));
    await until(find.textContaining('未允许读取当前账号、读取动态'));
    expect(find.text('mori'), findsOneWidget);
    expect(forum.reads, isEmpty);
    expect(
      plugins.byId(_plugin)!.allows(MetaversePluginPermission.forumActivity),
      isFalse,
    );
    expect(plugins.byId(_plugin)!.allows(MetaversePluginPermission.identity), isFalse);
    await tester.tap(find.text('订阅此人'));
    await until(allow);
    await tester.tap(allow);
    await until(find.text('第一条动态'));
    await tester.pumpAndSettle();
    expect(find.text('订阅此人'), findsNothing);
    expect(
      container
          .read(metaversePluginStoreProvider)
          .loadIndex()
          .single
          .allows(MetaversePluginPermission.forumActivity),
      isTrue,
    );
    expect(plugins.byId(_plugin)!.allows(MetaversePluginPermission.identity), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    var terminated = false;
    engine.terminated.then((_) => terminated = true);
    container.read(metaversePluginHostsProvider).shutdownAll();
    for (var i = 0; i < 150 && !terminated; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(terminated, isTrue, reason: '释放测试使用的 QuickJS 实例');
    await tester.pump(const Duration(seconds: 6));
  });
}
