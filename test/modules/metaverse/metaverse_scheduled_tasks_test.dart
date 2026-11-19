import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/modules/metaverse/host/metaverse_task_actions.dart';
import 'package:fluxdo/modules/metaverse/host/metaverse_task_dispatcher.dart';
import 'package:fluxdo/modules/metaverse/host/metaverse_task_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_forum_request.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_task.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import 'metaverse_navigation_forum_test.dart' show Secrets;

class _Notifications extends Fake implements LocalNotificationService {
  final delivered = <int>[];
  @override
  Future<bool> requestPluginPermission() async => true;
  @override
  Future<void> showPlugin({
    required int id,
    required String pluginName,
    required String title,
    required String body,
  }) async => delivered.add(id);
  @override
  Future<void> cancelNotification(int id) async => delivered.remove(id);
}

class _Delegate extends MetaversePluginHostDelegate {
  _Delegate(this.control, this.plugin, this.notifications);
  final MetaverseTaskStore control;
  final InstalledMetaversePlugin plugin;
  final _Notifications notifications;
  int account = 7, edition = 1, confirmations = 0;
  final requests = <Set<MetaversePluginPermission>>[];
  @override
  Future<bool> requestPermissions(BuildContext context, Set<MetaversePluginPermission> missing, {required void Function() checkActive}) async {
    requests.add({...missing});
    checkActive();
    return accept;
  }
  bool accept = false;
  Completer<void>? started, release;
  @override
  int currentAccountId() => account;
  @override
  String currentUsername() => 'owner';
  @override
  Future<bool> confirmBackground(BuildContext context, String task) async {
    confirmations++;
    return accept;
  }

  @override
  Future<bool> confirmNotifications(BuildContext context) async => accept;
  @override
  void toast(String message, String type) {}
  @override
  Future<Object?> taskOperation(
    String method,
    Map<String, Object?> params, {
    required void Function() checkActive,
  }) => MetaverseTaskActions(
    control,
    plugin.manifest,
    account,
    changed: () async {},
    checkActive: checkActive,
    notifications: notifications,
  ).call(method, params);
  @override
  Future<Object?> readForum(
    MetaverseForumRequest request, {
    required void Function() checkActive,
  }) async {
    if (request.resource == MetaverseForumResource.user) {
      return {'username': request.username, 'id': 9};
    }
    if (request.resource != MetaverseForumResource.actions) {
      return {'items': []};
    }
    if (started != null && !started!.isCompleted) {
      started!.complete();
      await release!.future;
    }
    checkActive();
    return {
      'items': [
        for (var n = 1; n <= edition; n++)
          {
            'id': 'a$n',
            'action': 'topics',
            'topicId': n,
            'postNumber': 1,
            'createdAt': DateTime.utc(2026, 10, n).toIso8601String(),
            'title': '话题 $n',
          },
      ],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(bool Function() ready, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MetaverseTaskStore control;
  late MetaversePluginStore data;
  late MetaversePluginNetwork network;
  late InstalledMetaversePlugin installed;
  late _Delegate delegate;
  late MetaversePluginPackage package;
  var ms = 1000000;
  MetaversePluginHost host({String? script}) => MetaversePluginHost(
    manifest: installed.manifest,
    blockedPermissions: installed.blockedPermissions,
    store: data,
    network: network,
    engineFactory: createMetaverseScriptEngine,
    delegate: delegate,
    codeLoader: script == null
        ? () => data.readCodeRevision(installed.id, installed.codeRevision!)
        : () async => (ui: package.code.ui, script: script),
  );
  Future<String?> tick({
    bool background = false,
    String? script,
    Duration timeout = const Duration(seconds: 24),
  }) => dispatchMetaverseTask(
    control: control,
    background: background,
    installed: () => [installed],
    newHost: (_) => host(script: script),
    available: (a) => a == delegate.account,
    timeout: timeout,
  );
  void sync() => control.sync(
    accountId: delegate.account,
    username: 'owner',
    plugins: [installed],
  );
  setUp(() async {
    ms = 1000000;
    root = await Directory.systemTemp.createTemp('fluxdo-tasks');
    control = MetaverseTaskStore(
      root,
      clock: () => DateTime.fromMillisecondsSinceEpoch(ms),
    );
    SharedPreferences.setMockInitialValues({});
    data = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: Secrets(),
      rootDirectory: () async => root,
    );
    network = MetaversePluginNetwork(
      lookup: (_) async => throw StateError('测试禁止网络'),
    );
    package = await MetaversePluginInstaller(network: network).importBundle(
      File('test/fixtures/metaverse/activity-feed-1.2.0.fluxplugin').openRead(),
    );
    installed = InstalledMetaversePlugin(
      manifest: package.manifest,
      source: package.source,
      enabled: true,
      codeRevision: MetaversePluginStore.revisionOf(package.code),
    );
    await data.writeCode(installed.id, package.code);
    await data.saveIndex([installed]);
    delegate = _Delegate(control, installed, _Notifications());
    sync();
  });
  tearDown(() async {
    network.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('安装发行包：名单、拒绝与批准、关闭页面、系统刷新、未读通知、打开与撤销', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.runAsync(() async {
      final pageHost = host();
      addTearDown(pageHost.shutdown);
      final surface = await pageHost.open(kind: 'page', page: 'settings');
      pageHost.attachSurface(surface, context);
      await _until(() => surface.data['title'] != null, '管理页加载');
      pageHost.dispatchUserEvent(surface, 'add', {'value': 'demo'});
      await _until(
        () =>
            surface.data['title'] == '1 位订阅 · 0 条未读' &&
            (surface.data['items'] as List?)?.length == 1,
        '首轮只建基线',
      );
      pageHost.dispatchUserEvent(surface, 'schedule', {'mode': 'background'});
      await _until(
        () => delegate.confirmations == 1 && pageHost.canApplyDevelopmentUpdate,
        '拒绝后台授权',
      );
      expect(control.tasks(7, installed.id), isEmpty);
      delegate.accept = true;
      pageHost.dispatchUserEvent(surface, 'schedule', {'mode': 'background'});
      await _until(() => surface.data['background'] == true, '批准后台任务');
      pageHost.dispatchUserEvent(surface, 'notify', {});
      await _until(() => surface.data['notify'] == true, '批准通知');
      pageHost.close(surface);
      pageHost.shutdown();
      delegate.edition = 2;
      ms += 30000;
      final results = await Future.wait([tick(background: true), tick()]);
      expect(results.whereType<String>(), [installed.id]);
      expect(control.badges(7).values.single, 1);
      final id = delegate.notifications.delivered.single;
      final target = MetaverseTaskStore(root).notificationTarget(id)!;
      expect(target['page'], 'feed');
      final reopened = host();
      addTearDown(reopened.shutdown);
      final feed = await reopened.open(kind: 'page', page: target['page']);
      reopened.attachSurface(feed, context);
      await _until(() => feed.data['title'] == '1 位订阅 · 1 条未读', '通知打开落点');
      reopened.dispatchUserEvent(feed, 'read', {});
      await _until(() => feed.data['title'] == '1 位订阅 · 0 条未读', '全部已读');
      expect(delegate.notifications.delivered, isEmpty);
      ms += 30000;
      await tick();
      expect(control.badges(7).values.single, 0);
      delegate.started = Completer();
      delegate.release = Completer();
      delegate.edition = 3;
      ms += 30000;
      final lateResult = tick();
      await delegate.started!.future.timeout(const Duration(seconds: 4));
      final before = await data.readStorage(installed.id);
      control.revoke(installed.id);
      delegate.release!.complete();
      expect(await lateResult, isNull);
      expect(await data.readStorage(installed.id), before);
      expect(control.notificationTarget(id), isNull);
      expect(delegate.notifications.delivered, isEmpty);
      reopened.shutdown();
    });
  });

  testWidgets('按需授权只接受当前点击；拒绝后保留输入，批准后在原页面完成订阅', (tester) async {
    installed = installed.copyWith(blockedPermissions: {MetaversePluginPermission.forumActivity});
    final pageHost = host();
    addTearDown(pageHost.retire);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {context = c;return const SizedBox();})));
    await tester.runAsync(() async {
      final surface = await pageHost.open(kind: 'page', page: 'add');
      pageHost.attachSurface(surface, context);
      await _until(() => surface.data['title'] != null, '首次打开');
      expect(delegate.requests, isEmpty);
      for (final names in [['sandbox'], ['payments'], ['forumActivity']]) {
        await expectLater(pageHost.call('permissions.request', {'names': names}), throwsA(isA<MetaversePluginCallException>()));
      }
      pageHost.dispatchUserEvent(surface, 'input', {'value':'alex'});
      pageHost.dispatchUserEvent(surface, 'add', {});
      await _until(() => '${surface.data['error']}'.contains('未允许'), '拒绝授权');
      expect(surface.data['users'], isEmpty);
      expect(surface.data['input'], 'alex');
      delegate.accept = true;
      pageHost.dispatchUserEvent(surface, 'add', {});
      await _until(() => surface.data['title'] == '1 位订阅 · 0 条未读', '授权后继续原操作');
      expect(delegate.requests, [{MetaversePluginPermission.forumActivity}, {MetaversePluginPermission.forumActivity}]);
      expect((await pageHost.call('permissions.status', {}) as Map)['forumActivity'], isTrue);
    });
  });

  test('单项撤销使其他引擎的旧租约失效，只降级后台计划并移除被撤销的通知', () async {
    final other = MetaverseTaskStore(root, clock: () => DateTime.fromMillisecondsSinceEpoch(ms));
    final request = MetaverseTaskSchedule('refresh', 10);
    control.schedule(7, installed.id, request, background: true);
    control.allowNotifications(7, installed.id, true);
    final notice = control.notification(7, installed.id, 'notice', page: 'feed', params: {})['id'];
    ms += 10000;
    final active = other.claim(background: true)!;
    final partial = installed.copyWith(blockedPermissions: {MetaversePluginPermission.forumFollowing});
    expect(control.applyPermissions(partial), isEmpty);
    expect(other.active(active), isFalse);
    expect(other.notificationTarget(notice), isNotNull);
    expect(other.tasks(7, installed.id).single['background'], isTrue);
    ms += 10000;
    var ran = false;
    await dispatchMetaverseTask(control: other, background: false, available: (_) => true,
      installed: () => [installed], newHost: (_) {ran = true; return host();});
    expect(ran, isFalse, reason: '持有旧安装索引的引擎必须重新读取策略');
    final limited = partial.copyWith(blockedPermissions: {...partial.blockedPermissions,
      MetaversePluginPermission.background, MetaversePluginPermission.notifications});
    expect(control.applyPermissions(limited), [notice]);
    expect(other.notificationTarget(notice), isNull);
    expect(other.notificationsAllowed(7, installed.id), isFalse);
    expect(other.tasks(7, installed.id).single['background'], isFalse);
    expect(() => other.allowNotifications(7, installed.id, true), throwsA(isA<MetaversePluginCallException>()));
    expect(() => other.schedule(7, installed.id, request, background: true), throwsA(isA<MetaversePluginCallException>()));
    control.applyPermissions(installed);
    expect(other.notificationsAllowed(7, installed.id), isFalse);
    expect(other.tasks(7, installed.id).single['background'], isFalse);
  });

  test('独立连接抢占、后台长短间隔、冷启动账号与来源失效', () {
    final other = MetaverseTaskStore(
      root,
      clock: () => DateTime.fromMillisecondsSinceEpoch(ms),
    );
    void schedule(int interval) => control.schedule(
      7,
      installed.id,
      MetaverseTaskSchedule('refresh', interval),
      background: true,
    );
    schedule(3600);
    ms += 3600000;
    final lease = control.claim(background: true)!;
    expect(other.claim(background: false), isNull);
    other.finish(lease);
    ms += 900000;
    expect(control.claim(background: true), isNull);
    schedule(10);
    ms += 10000;
    final short = control.claim(background: true)!;
    control.finish(short);
    ms += 10000;
    expect(control.claim(background: true), isNull);
    expect(control.claim(background: false), isNotNull);
    control.allowNotifications(7, installed.id, true);
    final id =
        control.notification(
              7,
              installed.id,
              'notice',
              page: 'feed',
              params: {},
            )['id']
            as int;
    expect(other.notificationTarget(id)?['account'], 7);
    other.allowNotifications(7, installed.id, false);
    expect(control.notificationTarget(id), isNull);
    control.queueEvents(7, [{'pluginId': installed.id, 'event': 'plugin_task'}, {'pluginId': 'uninstalled', 'event': 'plugin_task'}]);
    expect(other.takeEvents().map((event) => event['pluginId']), [installed.id]);
    expect(control.takeEvents(), isEmpty);
    final alternate = InstalledMetaversePlugin(
      manifest: installed.manifest,
      source: 'other',
      enabled: true,
    );
    expect(other.sync(accountId: 7, username: 'owner', plugins: [alternate]), [
      id,
    ]);
    expect(control.notificationTarget(id), isNull);
    delegate.account = 8;
    sync();
    expect(control.tasks(8, installed.id), isEmpty);
    expect(control.badges(8), isEmpty);
    expect(
      () => other.setBadge(7, installed.id, 'feed', 1),
      throwsA(isA<MetaversePluginCallException>()),
    );
  });

  test('超时、脚本错误与限流退避，工作任务不能发起付款或授权', () async {
    final plugin = installed.id;
    for (final entry in {
      'task_timeout': "return new Promise(()=>{});",
      'task_failed': "throw new Error('业务失败');",
      'forum_rate_limited': "throw new Error('forum_rate_limited');",
      'task_handler_missing': null,
    }.entries) {
      control.schedule(
        7,
        plugin,
        const MetaverseTaskSchedule('refresh', 10),
        background: false,
      );
      ms += 10000;
      await tick(
        script: entry.value == null
            ? ''
            : "fluxdo.on('task.run',async()=>{${entry.value}})",
        timeout: Duration(
          milliseconds: entry.key == 'task_timeout' ? 400 : 4000,
        ),
      );
      final job = control.tasks(7, plugin).single;
      expect(job['error'], entry.key);
      expect(job['nextAt'], greaterThanOrEqualTo(ms + 60000));
    }
    control.schedule(
      7,
      plugin,
      const MetaverseTaskSchedule('refresh', 10),
      background: false,
    );
    ms += 10000;
    expect(
      await tick(
        script: '''fluxdo.on('task.run',async ctx=>{for(const action of [()=>ctx.api.permissions.request(['forumActivity']),()=>ctx.api.navigation.dismiss(),()=>ctx.api.payments.request({}),()=>ctx.api.connect.authorize(''),()=>ctx.api.notifications.requestPermission()]){let blocked=false;try{await action();}catch(e){blocked=e.message==='task_has_no_ui';}if(!blocked)throw Error('unexpected');}});''',
      ),
      plugin,
    );
  });

  test('跨实例条件写只允许一个获胜，旧 JSON 一次迁移且不会在清空后复活', () async {
    final plugin = installed.id;
    await File('${root.path}/$plugin/storage.json')
        .writeAsString('{"count":1}');
    final second = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: Secrets(),
      rootDirectory: () async => root,
    );
    final winners = await Future.wait([
      data.compareAndSet(plugin, 'count', 1, 2, checkActive: () {}),
      second.compareAndSet(plugin, 'count', 1, 3, checkActive: () {}),
    ]);
    expect(winners.where((x) => x), hasLength(1));
    await second.clearStorage(plugin);
    expect(await data.readStorage(plugin), isEmpty);
  });
}
