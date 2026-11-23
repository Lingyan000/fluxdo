import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../../../l10n/s.dart';

class MetaverseApiExample {
  const MetaverseApiExample(
    this.name,
    this.arguments,
    this.result, {
    this.permission,
    this.apiVersion = 1,
    this.userAction = false,
    this.afterCall = 'console.log(result);',
  });
  final String name;
  final String arguments;
  final Object? result;
  final String? permission;
  final int apiVersion;
  final bool userAction;
  final String afterCall;
  String get script => scriptWith(arguments);
  String scriptWith(String input) =>
      '''fluxdo.on('${userAction ? 'action' : 'card.load'}', async (ctx) => {
  try {
    const result = await ctx.api.$name($input);
    $afterCall
  } catch (error) {
    console.error(error.message);
  }
});''';

  String description(AppLocalizations l) => switch (name) {
    'tasks.schedule' => l.metaverse_apiSchedule,
    'tasks.cancel' => l.metaverse_stopTask,
    'tasks.list' => l.metaverse_apiListTasks,
    'navigation.setBadge' => l.metaverse_apiBadge,
    'navigation.dismiss' => l.metaverse_apiDismiss,
    'notifications.status' || 'notifications.openSettings' => l.metaverse_apiNotificationStatus,
    'notifications.requestPermission' || 'notifications.show' || 'notifications.cancel' || 'notifications.isAllowed' || 'notifications.revoke' => l.metaverse_pluginNotificationsNote,
    'storage.get' => l.metaverse_apiStorageGet,
    'storage.set' => l.metaverse_apiStorageSet,
    'storage.setMany' => l.metaverse_apiStorageSetMany,
    'storage.compareAndSet' => l.metaverse_apiStorageCompare,
    'storage.remove' => l.metaverse_apiStorageRemove,
    'crypto.sha256' => l.metaverse_apiSha256,
    'crypto.pkce' => l.metaverse_apiPkce,
    'crypto.uuid' => l.metaverse_apiUuid,
    'credentials.status' => l.metaverse_apiCredentialStatus,
    'credentials.capture' => l.metaverse_apiCredentialCapture,
    'credentials.remove' => l.metaverse_apiCredentialRemove,
    'credentials.request' => l.metaverse_apiCredentialRequest,
    'connect.authorize' => l.metaverse_apiConnect,
    'forum.read' => l.metaverse_apiForumRead,
    'forum.open' => l.metaverse_apiForumOpen,
    'host.features' => l.metaverse_apiHostFeatures,
    'host.environment' => l.metaverse_apiEnvironment,
    'preferences.get' => l.metaverse_pluginPreferences,
    'permissions.status' || 'permissions.request' => l.metaverse_apiRuntimePermissions,
    'dialogs.confirm' => l.metaverse_apiConfirm,
    'auth.status' || 'auth.request' || 'auth.signOut' => l.metaverse_apiLegacyAuth,
    'payments.request' => l.metaverse_apiPayment,
    'fetch' => l.metaverse_apiFetch,
    'streams.open' || 'streams.close' => l.metaverse_apiStreams,
    'user.get' => l.metaverse_apiUser,
    'navigate' => l.metaverse_apiNavigate,
    'prepareNavigation' => l.metaverse_apiPrepareNavigation,
    'session.login' => l.metaverse_apiSessionLogin,
    'session.open' => l.metaverse_apiSessionOpen,
    'openUrl' => l.metaverse_apiOpenUrl,
    'browser.open' => l.metaverse_apiBrowserOpen,
    'toast' => l.metaverse_apiToast,
    _ => name,
  };
}

/// 返回值用于文档演示。生产调用仍由宿主的权限检查与服务适配处理。
const metaverseApiExamples = [
  MetaverseApiExample('host.environment', '', {'locale':'zh', 'platform':'android', 'timeZoneOffsetMinutes':480}, apiVersion: 2),
  MetaverseApiExample('preferences.get', '', {'compact':true, 'sort':'latest'}, apiVersion: 2),
  MetaverseApiExample('streams.open', "{id: 'updates', url: 'https://api.example.org/events'}", 'updates',
    permission: 'network', apiVersion: 2, afterCall: "console.log(result); fluxdo.on('stream.state', (_, state) => console.log(state)); fluxdo.on('stream.event', (_, frame) => console.log(JSON.parse(frame.data)));"),
  MetaverseApiExample('streams.close', "'updates'", null, permission: 'network', apiVersion: 2),
  MetaverseApiExample('permissions.status', '', {'forumActivity': false}, apiVersion: 2),
  MetaverseApiExample('permissions.request', "['forumActivity']", true, userAction: true, apiVersion: 2),
  MetaverseApiExample('tasks.schedule', "{id: 'refresh', intervalSeconds: 30, background: false}", true, permission: 'tasks', apiVersion: 2, userAction: true),
  MetaverseApiExample('tasks.cancel', "'refresh'", null, permission: 'tasks', apiVersion: 2),
  MetaverseApiExample('notifications.status', '', {'authorized': true, 'system': 'denied', 'canOpenSettings': true}, permission: 'notifications', apiVersion: 2),
  MetaverseApiExample('notifications.openSettings', '', true, permission: 'notifications', apiVersion: 2, userAction: true),
  MetaverseApiExample('notifications.isAllowed', '', false, permission: 'notifications', apiVersion: 2),
  MetaverseApiExample('notifications.revoke', '', null, permission: 'notifications', apiVersion: 2),
  MetaverseApiExample('tasks.list', '', [{'id': 'refresh', 'intervalSeconds': 30, 'background': false}], permission: 'tasks', apiVersion: 2),
  MetaverseApiExample('navigation.setBadge', "'feed', 3", null, permission: 'navigationBadge', apiVersion: 2),
  MetaverseApiExample('navigation.dismiss', '', false, apiVersion: 2),
  MetaverseApiExample('notifications.requestPermission', '', true, permission: 'notifications', apiVersion: 2, userAction: true),
  MetaverseApiExample('notifications.show', "{key: 'updates', title: '新动态', body: '有 3 条新动态', page: 'feed'}", true, permission: 'notifications', apiVersion: 2),
  MetaverseApiExample('notifications.cancel', "'updates'", null, permission: 'notifications', apiVersion: 2),
  MetaverseApiExample('forum.read', "{resource: 'actions', username: 'demo', actions: ['topics', 'replies'], offset: 0}",
    {'items': [{'topicId': 42, 'title': '示例话题', 'action': 'topics', 'postNumber': 1}], 'nextOffset': null},
    permission: 'forum.activity', apiVersion: 2),
  MetaverseApiExample('forum.open', "{type: 'topic', topicId: 42, postNumber: 1}", null,
    apiVersion: 2, userAction: true),
  MetaverseApiExample('host.features', '', ['confirmationDialog', 'virtualGrid', 'nativeExecutionLimits']),
  MetaverseApiExample('dialogs.confirm',
    "{title: '确认操作', message: '请阅读说明后继续。', confirmLabel: '同意并继续', agreement: {label: '服务条款', url: 'https://example.org/terms'}}",
    true, userAction: true),
  MetaverseApiExample('auth.status', '', {'authorized': false}, permission: 'auth'),
  MetaverseApiExample('auth.request', '', true, permission: 'auth', userAction: true),
  MetaverseApiExample('auth.signOut', '', null, permission: 'auth'),
  MetaverseApiExample(
    'storage.setMany',
    "{current: {value: 1}, previous: null}",
    null,
    apiVersion: 2,
  ),
  MetaverseApiExample(
    'crypto.sha256',
    "'abc'",
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    apiVersion: 2,
  ),
  MetaverseApiExample(
    'credentials.status',
    "'account', {jwt: true}",
    {'authorized': true, 'expiresAt': 2000000000, 'claims': {'sub': '42', 'name': 'Lin'}},
    permission: 'credentials',
    apiVersion: 2,
  ),
  MetaverseApiExample(
    'credentials.capture',
    "'account', {url: 'https://api.example.org/token', method: 'POST', body: {code: 'demo'}}, {tokenPath: ['access', 'value']}",
    {'authorized': true, 'expiresAt': null},
    permission: 'credentials, network',
    apiVersion: 2,
  ),
  MetaverseApiExample(
    'credentials.remove',
    "'account'",
    null,
    permission: 'credentials',
    apiVersion: 2,
  ),
  MetaverseApiExample(
    'credentials.request',
    "'account'",
    true,
    permission: 'credentials',
    apiVersion: 2,
    userAction: true,
  ),
  MetaverseApiExample(
    'connect.authorize',
    "'https://connect.linux.do/oauth2/authorize?client_id=demo&redirect_uri=https%3A%2F%2Fapi.example.org%2Fcallback&state=demo'",
    'https://api.example.org/callback?code=demo&state=demo',
    permission: 'connect',
    apiVersion: 2,
    userAction: true,
  ),
  MetaverseApiExample('crypto.pkce', '', {
    'verifier': 'demo-verifier',
    'challenge': 'demo-challenge',
    'method': 'S256',
  }, apiVersion: 2),
  MetaverseApiExample(
    'crypto.uuid',
    '',
    '96d7c264-e355-4d84-9dbe-6b3751671a41',
    apiVersion: 2,
  ),
  MetaverseApiExample(
    'payments.request',
    "{provider: 'linuxDoCredit', url: 'https://credit.linux.do/paying?order_no=demo', reference: 'DEMO-1', amount: '1.00'}",
    {'state': 'paid'},
    permission: 'payments',
    apiVersion: 2,
    userAction: true,
  ),
  MetaverseApiExample('fetch', "'https://api.example.org/items'", {
    'status': 200,
    'headers': <String, Object?>{},
    'body': '{"items":[]}',
  }, permission: 'network'),
  MetaverseApiExample('storage.get', "'example'", {'value': 1}),
  MetaverseApiExample('storage.compareAndSet', "'example', {value: 1}, {value: 2}", true, apiVersion: 2),
  MetaverseApiExample('storage.set', "'example', {value: 1}", null),
  MetaverseApiExample('storage.remove', "'example'", null),
  MetaverseApiExample('user.get', '', {
    'username': 'example',
  }, permission: 'identity'),
  MetaverseApiExample(
    'navigate',
    "'detail', {id: 'example'}, {replace: false}",
    null,
    userAction: true,
  ),
  MetaverseApiExample(
    'prepareNavigation',
    "'detail', {replace: false}",
    1,
    userAction: true,
    afterCall:
        "await result({id: 'example'}); console.log('navigation opened');",
  ),
  MetaverseApiExample(
    'session.login',
    '',
    null,
    permission: 'webLogin',
    userAction: true,
  ),
  MetaverseApiExample(
    'session.open',
    "'/orders'",
    null,
    permission: 'webLogin',
    userAction: true,
  ),
  MetaverseApiExample(
    'openUrl',
    "'https://example.org'",
    null,
    userAction: true,
  ),
  MetaverseApiExample('toast', "'Example', 'info'", null),
  MetaverseApiExample(
    'browser.open',
    "'https://example.org'",
    null,
    userAction: true,
  ),
];

/// 开发中心的演示桥。界面回调由预览页提供，服务数据使用演示结果。
class MetaverseDocumentationBridge implements MetaversePluginBridge {
  MetaverseDocumentationBridge({
    required this.example,
    required this.failure,
    required this.onLog,
    this.onCall,
  });
  final MetaverseApiExample example;
  final bool failure;
  final void Function(String level, String message) onLog;
  final Future<Object?> Function(String method, Map<String, Object?> params)?
  onCall;

  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
    onLog('call', '$method $params');
    if (failure) {
      throw const MetaversePluginCallException('demo_permission_denied');
    }
    return onCall == null ? example.result : await onCall!(method, params);
  }

  @override
  void log(String level, String message) => onLog(level, message);
}
