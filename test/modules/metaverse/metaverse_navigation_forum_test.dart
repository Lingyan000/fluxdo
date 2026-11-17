import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/navigation/nav_entry.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/models/user_action.dart';
import 'package:fluxdo/modules/metaverse/host/metaverse_forum_adapter.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_forum_request.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_surface_view.dart';
import 'package:fluxdo/navigation/nav_entries_provider.dart';
import 'package:fluxdo/navigation/nav_entry_registry.dart';
import 'package:fluxdo/navigation/navigation_activity_scope.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> manifestJson() => jsonDecode(
  File('test/fixtures/metaverse/forum-activity/plugin.json').readAsStringSync(),
) as Map<String, dynamic>;
MetaversePluginManifest manifest() =>
    MetaversePluginManifest.parse(manifestJson(), reservedHosts: ['linux.do']);

class Engine implements MetaverseScriptEngine {
  final codes = <String>[];
  @override
  void Function(Object?)? onMessage;
  @override
  void Function(String)? onFatal;
  @override
  Future<void> evaluate(String code, {String name = ''}) async {
    codes.add(code);
  }

  @override
  void dispose() {}
}

class Secrets implements SecretStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Delegate extends MetaversePluginHostDelegate {
  int? account = 1;
  int reads = 0;
  final opened = <MetaverseForumDestination>[];
  @override
  Future<void> openForum(
    BuildContext context,
    MetaverseForumDestination destination,
  ) async => opened.add(destination);
  Completer<Object?>? pending;
  @override
  int? currentAccountId() => account;
  @override
  String? currentUsername() => account == null ? null : 'demo';
  @override
  Future<Object?> readForum(
    MetaverseForumRequest request, {
    required void Function() checkActive,
  }) async {
    reads++;
    return pending?.future ?? {'items': [], 'nextOffset': null};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ForumService implements DiscourseService {
  String? filter;
  bool silent = false;
  @override
  Future<User> getUser(String username, {bool isSilent = false}) async =>
      User.fromJson({
        'id': 2,
        'username': username,
        'name': 'Demo',
        'email': 'private@example.org',
        'unread_notifications': 4,
        'trust_level': 2,
        'last_seen_at': '2026-11-17T00:00:00Z',
      });
  @override
  Future<UserActionResponse> getUserActions(
    String username, {
    String? filter,
    int offset = 0,
    bool isSilent = false,
  }) async {
    this.filter = filter;
    silent = isSilent;
    return const UserActionResponse(
      actions: [
        UserAction(topicId: 42, title: 'Topic', actionType: 4),
        UserAction(topicId: 43, title: 'Must not leak', actionType: 8),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Bridge implements MetaversePluginBridge {
  @override
  Future<Object?> call(String method, Map<String, Object?> params) async =>
      null;
  @override
  void log(String level, String message) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('导航贡献稳定、用户选择、停用保留编辑项，旧清单不能偷偷扩权', () {
    final m = manifest();
    final installed = InstalledMetaversePlugin(
      manifest: m,
      source: 'file',
      enabled: true,
    );
    final entry = pluginNavigationEntries([installed]).single;
    expect(entry.id, 'plugin:example.forum.activity:activity');
    expect(entry.available, isTrue);
    expect(entry.requiresLogin, isTrue);
    expect(entry.defaultInBottomNav, isFalse);
    expect(entry.lazy, isTrue);
    expect(
      () => MetaversePluginManifest.parse({
        ...manifestJson(),
        'requiredFeatures': <String>[],
      }),
      throwsA(isA<MetaverseManifestException>()),
    );
    expect(
      pluginNavigationEntries([installed.copyWith(enabled: false)])
          .single
          .available,
      isFalse,
    );
    expect(
      pluginNavigationEntries([installed.copyWith(suspendedReason: 'failed')])
          .single
          .available,
      isFalse,
    );
    expect(pluginNavigationEntries([]), isEmpty);
    expect(NavEntryRegistry.byId('metaverse'), isNotNull);
    final all = [...NavEntryRegistry.buildAll(), entry];
    expect(
      resolveNavigationEntries(all, [
        'home',
        entry.id,
        entry.id,
        'profile',
      ], loggedIn: true).map((e) => e.id),
      ['home', entry.id, 'profile'],
    );
    expect(
      resolveNavigationEntries(all, [
        'home',
        entry.id,
        'profile',
      ], loggedIn: false).map((e) => e.id),
      ['home', 'profile'],
    );
    expect(
      resolveNavigationEntries(NavEntryRegistry.buildAll(), [
        entry.id,
      ], loggedIn: true).map((e) => e.id),
      ['home', 'profile'],
    );
    expect(
      NavEntryRegistry.desktopEntries(
        resolveNavigationEntries(all, ['profile', entry.id], loggedIn: true),
      ).map((e) => e.id),
      ['home', 'mini_apps', 'profile', entry.id],
    );
    final raw = manifestJson();
    expect(
      () => MetaversePluginManifest.parse({...raw, 'schema': 10}),
      throwsA(isA<MetaverseManifestException>()),
    );
    final modal = manifestJson();
    (modal['pages'] as List).first['presentation'] = 'modal';
    expect(
      () => MetaversePluginManifest.parse(modal),
      throwsA(isA<MetaverseManifestException>()),
    );
    final limited = manifestJson();
    limited['permissions']['forum'] = ['profiles'];
    expect(m.sameApprovalAs(MetaversePluginManifest.parse(limited)), isFalse);
    final renamed = manifestJson();
    renamed['pages'][0]['navigation']['label'] = 'New';
    expect(m.sameApprovalAs(MetaversePluginManifest.parse(renamed)), isTrue);
  });
  test('论坛调用拒绝任意路径、未知资源、私信过滤器和失效游标', () {
    for (final username in [
      '../session',
      'demo/other',
      'demo%2fother',
      'demo?x=1',
      '',
    ]) {
      expect(
        () => MetaverseForumRequest.parse({
          'resource': 'user',
          'username': username,
        }),
        throwsA(isA<MetaversePluginCallException>()),
      );
    }
    for (final p in [
      {'resource': 'logout', 'username': 'demo'},
      {
        'resource': 'actions',
        'username': 'demo',
        'actions': [8],
      },
      {'resource': 'actions', 'username': 'demo', 'filter': '8'},
      {'resource': 'reactions', 'username': 'demo', 'before': -1},
      {'resource': 'user', 'username': 'demo', 'url': '/session'},
    ]) {
      expect(
        () => MetaverseForumRequest.parse(p),
        throwsA(isA<MetaversePluginCallException>()),
      );
    }
    expect(
      () => MetaverseForumDestination.parse({'type': 'topic', 'topicId': 0}),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(
      () => MetaverseForumDestination.parse({
        'type': 'user',
        'username': 'demo',
        'url': '/session',
      }),
      throwsA(isA<MetaversePluginCallException>()),
    );
  });
  test('论坛适配仅序列化指定字段，过滤服务异常返回的非声明动态', () async {
    final service = ForumService();
    final adapter = MetaverseForumAdapter(service, MetaverseForumBudget());
    final profile = await adapter.read(
      'a',
      MetaverseForumRequest.parse({'resource': 'user', 'username': 'demo'}),
      checkActive: () {},
    );
    expect(jsonEncode(profile), isNot(contains('private@example.org')));
    expect(jsonEncode(profile), isNot(contains('unread_notifications')));
    final response = await adapter.read(
      'a',
      MetaverseForumRequest.parse({
        'resource': 'actions',
        'username': 'demo',
        'actions': ['topics', 'replies'],
      }),
      checkActive: () {},
    ) as Map;
    expect(response['items'], hasLength(1));
    expect(service.filter, '4,5');
    expect(service.silent, isTrue);
    expect(response['nextOffset'], 2);
  });
  test('请求预算跨插件与运行时共享，429 冷却和时间窗口恢复', () {
    var now = DateTime.utc(2026, 11, 17);
    final budget = MetaverseForumBudget(clock: () => now);
    budget.acquire('a');
    budget.acquire('a');
    expect(
      () => budget.acquire('a'),
      throwsA(isA<MetaversePluginCallException>()),
    );
    budget.release('a');
    budget.release('a');
    for (var i = 0; i < 118; i++) {
      budget.acquire('a');
      budget.release('a');
    }
    expect(
      () => budget.acquire('a'),
      throwsA(isA<MetaversePluginCallException>()),
    );
    budget.acquire('b');
    budget.release('b');
    budget.backoff(10);
    expect(
      () => budget.acquire('b'),
      throwsA(isA<MetaversePluginCallException>()),
    );
    now = now.add(const Duration(seconds: 61));
    budget.acquire('a');
    budget.release('a');
  });
  testWidgets('未访问标签不构建，切换后保留原状态', (tester) async {
    var active = false, created = 0;
    late StateSetter update;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LazyNavigationPage(
              active: active,
              builder: (_) => _Counter(onCreate: () => created++),
            );
          },
        ),
      ),
    );
    expect(created, 0);
    update(() => active = true);
    await tester.pump();
    expect(created, 1);
    update(() => active = false);
    await tester.pump();
    update(() => active = true);
    await tester.pump();
    expect(created, 1);
  });
  testWidgets('所有界面隐藏时冻结定时器，有一个可见就恢复，关闭释放', (tester) async {
    final engine = Engine();
    final runtime = await MetaversePluginRuntime.start(
      engineFactory: () async => engine,
      script: '',
      bridge: Bridge(),
    );
    final a = runtime.openSurface(kind: 'page', page: 'activity');
    final b = runtime.openSurface(kind: 'card');
    engine.onMessage!({'t': 'timer', 'id': 1, 'ms': 1000});
    await tester.pump(const Duration(milliseconds: 400));
    runtime.setForeground(a, false);
    runtime.setForeground(b, false);
    await tester.pump(const Duration(seconds: 5));
    expect(
      engine.codes.where((c) => c == '__fluxdoMetaverse.timer(1)'),
      isEmpty,
    );
    runtime.setForeground(b, true);
    await tester.pump(const Duration(seconds: 1));
    expect(
      engine.codes.where((c) => c == '__fluxdoMetaverse.timer(1)'),
      hasLength(1),
    );
    expect(engine.codes.where((c) => c.contains('card.hide')), hasLength(1));
    runtime.dispose();
  });

  group('论坛宿主边界与页面可见性', () {
    late Directory directory;
    late MetaversePluginStore store;
    late Delegate delegate;
    late Engine engine;
    late MetaversePluginHost host;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('forum-plugin-test-');
      store = MetaversePluginStore(
        preferences: await SharedPreferences.getInstance(),
        secretStore: Secrets(),
        rootDirectory: () async => directory,
      );
      delegate = Delegate();
      engine = Engine();
      host = MetaversePluginHost(
        manifest: manifest(),
        store: store,
        network: MetaversePluginNetwork(
          lookup: (_) async => throw StateError('no network'),
        ),
        engineFactory: () async => engine,
        delegate: delegate,
        codeLoader: () async => (
          ui: 'import fluxdo; widget Activity = Label(text: "Ready");',
          script: '',
        ),
      );
    });
    tearDown(() async {
      host.shutdown();
      await directory.delete(recursive: true);
    });
    Future<Object?> read(
      MetaversePluginSurface surface, [
      Map<String, Object?>? params,
    ]) =>
        PluginExecutionContext(
          pluginId: host.id,
          pluginVersion: '1.0.0',
          runtimeId: host.runtimeId,
          surfaceId: surface.id,
        ).run(
          () => host.call(
            'forum.read',
            params ?? {'resource': 'actions', 'username': 'demo'},
          ),
        );
    test('无可见界面不能读取，隐藏或账号变化丢弃迟到结果', () async {
      final surface = await host.open(kind: 'page', page: 'activity');
      await expectLater(
        host.call('forum.read', {'resource': 'actions', 'username': 'demo'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(await read(surface), isA<Map>());
      host.setSurfaceForeground(surface, false);
      await expectLater(
        read(surface),
        throwsA(isA<MetaversePluginCallException>()),
      );
      host.setSurfaceForeground(surface, true);
      delegate.pending = Completer<Object?>();
      final pending = read(surface);
      final check = expectLater(
        pending,
        throwsA(isA<MetaversePluginCallException>()),
      );
      delegate.account = 2;
      delegate.pending!.complete({'secret': 'previous account'});
      await check;
      expect(delegate.reads, 2);
      delegate.account = 1;
      delegate.pending = null;
      host.close(surface);
      await expectLater(
        read(surface),
        throwsA(isA<MetaversePluginCallException>()),
      );
      await expectLater(
        host.call('forum.open', {'type': 'topic', 'topicId': 42}),
        throwsA(isA<MetaversePluginCallException>()),
      );
    });
    test('没有对应论坛权限时不调用适配器', () async {
      final raw = manifestJson();
      raw['permissions']['forum'] = ['profiles'];
      final limited = MetaversePluginHost(
        manifest: MetaversePluginManifest.parse(raw),
        store: store,
        network: MetaversePluginNetwork(
          lookup: (_) async => throw StateError('no network'),
        ),
        engineFactory: () async => engine,
        delegate: delegate,
        codeLoader: () async => (
          ui: 'import fluxdo; widget Activity = Label(text: "Ready");',
          script: '',
        ),
      );
      addTearDown(limited.shutdown);
      final surface = await limited.open(kind: 'page', page: 'activity');
      await expectLater(
        PluginExecutionContext(
          pluginId: limited.id,
          pluginVersion: '1.0.0',
          runtimeId: limited.runtimeId,
          surfaceId: surface.id,
        ).run(
          () => limited.call('forum.read', {
            'resource': 'actions',
            'username': 'demo',
          }),
        ),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(delegate.reads, 0);
    });
    test('论坛插件存储按账号分区，旧运行实例不能读取新账号的数据', () async {
      await host.open(kind: 'page', page: 'activity');
      await host.call('storage.set', {'key': 'cache', 'value': 'account one'});
      delegate.account = 2;
      await expectLater(
        host.call('storage.get', {'key': 'cache'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      host.shutdown();
      await host.open(kind: 'page', page: 'activity');
      expect(await host.call('storage.get', {'key': 'cache'}), isNull);
      await host.call('storage.set', {'key': 'cache', 'value': 'account two'});
      expect((await store.readStorage(host.id)).values.toSet(), {
        'account one',
        'account two',
      });
      await expectLater(
        host.call('storage.get', {'key': '@forum-account:1:cache'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
    });
    test('真实 CLI 产物在 QuickJS 中调用论坛桥并生成原生页面数据', () async {
      final actual = MetaversePluginHost(
        manifest: manifest(),
        store: store,
        network: MetaversePluginNetwork(
          lookup: (_) async => throw StateError('no network'),
        ),
        engineFactory: createMetaverseScriptEngine,
        delegate: delegate,
        codeLoader: () async => (
          ui: File('test/fixtures/metaverse/forum-activity/ui.rfwtxt')
              .readAsStringSync(),
          script: File('test/fixtures/metaverse/forum-activity/main.js')
              .readAsStringSync(),
        ),
      );
      addTearDown(actual.shutdown);
      final surface = await actual.open(kind: 'page', page: 'activity');
      for (var i = 0; i < 200 && surface.data['loading'] != false; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(surface.data['error'], '');
      expect(surface.data['loading'], false);
      expect(surface.data['items'], []);
      expect(delegate.reads, 1);
    });
    testWidgets('启动期间切走不派发 open，并发可见页不会被空闲回收', (tester) async {
      final ready = Completer<MetaverseScriptEngine>();
      final delayed = MetaversePluginHost(
        manifest: manifest(),
        store: store,
        network: MetaversePluginNetwork(
          lookup: (_) async => throw StateError('no network'),
        ),
        engineFactory: () => ready.future,
        delegate: delegate,
        idleTimeout: const Duration(seconds: 1),
        codeLoader: () async => (
          ui: 'import fluxdo; widget Activity = Label(text: "Ready");',
          script: '',
        ),
      );
      addTearDown(delayed.shutdown);
      var visible = true;
      final hidden = delayed.open(
        kind: 'page',
        page: 'activity',
        isVisible: () => visible,
      );
      final rejected = expectLater(
        hidden,
        throwsA(isA<MetaversePluginCallException>()),
      );
      final shown = delayed.open(
        kind: 'page',
        page: 'activity',
        isVisible: () => true,
      );
      visible = false;
      ready.complete(engine);
      await tester.pump();
      await rejected;
      await shown;
      expect(
        engine.codes.where((c) => c.contains('dispatch("page.open"')),
        hasLength(1),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(delayed.isRunning, isTrue);
      delayed.shutdown();
    });
    testWidgets('原生论坛导航只消费一次当前界面的点击', (tester) async {
      final surface = await host.open(kind: 'page', page: 'activity');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              host.attachSurface(surface, context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      Future<Object?> navigate() =>
          PluginExecutionContext(
            pluginId: host.id,
            pluginVersion: '1.0.0',
            runtimeId: host.runtimeId,
            surfaceId: surface.id,
          ).run(
            () => host.call('forum.open', {
              'type': 'topic',
              'topicId': 42,
              'postNumber': 3,
            }),
          );
      host.dispatchUserEvent(surface, 'open', const {});
      await navigate();
      expect(delegate.opened.single.topicId, 42);
      expect(delegate.opened.single.postNumber, 3);
      await expectLater(
        navigate(),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(delegate.opened, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('底栏回顶和刷新只作用于当前插件页，隐藏时的操作不补发', (tester) async {
      var active = true;
      NavActionEvent? event;
      late StateSetter update;
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return NavigationActivityScope(
                  active: active,
                  action: event,
                  child: PrimaryScrollController(
                    controller: scroll,
                    child: SingleChildScrollView(
                      controller: scroll,
                      child: Column(
                        children: [
                          MetaversePluginSurfaceView(
                            host: host,
                            kind: MetaversePluginSurfaceKind.page,
                            page: 'activity',
                            navigationId:
                                'plugin:example.forum.activity:activity',
                          ),
                          const SizedBox(height: 2000),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      scroll.jumpTo(400);
      update(
        () => event = const NavActionEvent(
          targetId: 'plugin:example.forum.activity:activity',
          action: NavAction.scrollToTop,
          nonce: 1,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, 0);
      update(
        () => event = const NavActionEvent(
          targetId: 'plugin:example.forum.activity:activity',
          action: NavAction.refresh,
          nonce: 2,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        engine.codes.where((c) => c.contains('dispatch("page.refresh"')),
        hasLength(1),
      );
      update(() {
        active = false;
      });
      await tester.pump();
      update(
        () => event = const NavActionEvent(
          targetId: 'plugin:example.forum.activity:activity',
          action: NavAction.refresh,
          nonce: 3,
        ),
      );
      await tester.pump();
      update(() {
        active = true;
      });
      await tester.pump();
      expect(
        engine.codes.where((c) => c.contains('dispatch("page.refresh"')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      host.shutdown();
    });
    testWidgets('隐藏标签不启动，切换只 hide/resume，后台返回不重新 open', (tester) async {
      var active = false;
      late StateSetter update;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return NavigationActivityScope(
                  active: active,
                  child: MetaversePluginSurfaceView(
                    host: host,
                    kind: MetaversePluginSurfaceKind.page,
                    page: 'activity',
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(host.isRunning, isFalse);
      update(() => active = true);
      await tester.pump();
      await tester.pump();
      expect(host.isRunning, isTrue);
      expect(
        engine.codes.where((c) => c.contains('dispatch("page.open"')),
        hasLength(1),
      );
      update(() => active = false);
      await tester.pump();
      expect(
        engine.codes.where((c) => c.contains('dispatch("page.hide"')),
        hasLength(1),
      );
      update(() => active = true);
      await tester.pump();
      expect(
        engine.codes.where((c) => c.contains('dispatch("page.resume"')),
        hasLength(1),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        engine.codes.where((c) => c.contains('dispatch("page.open"')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      host.shutdown();
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter({required this.onCreate});
  final VoidCallback onCreate;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) => const Text('counter');
}
