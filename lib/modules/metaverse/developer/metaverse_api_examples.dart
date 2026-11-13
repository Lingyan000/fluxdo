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
    'storage.get' => l.metaverse_apiStorageGet,
    'storage.set' => l.metaverse_apiStorageSet,
    'storage.setMany' => l.metaverse_apiStorageSetMany,
    'storage.remove' => l.metaverse_apiStorageRemove,
    'crypto.sha256' => l.metaverse_apiSha256,
    'crypto.pkce' => l.metaverse_apiPkce,
    'crypto.uuid' => l.metaverse_apiUuid,
    'credentials.status' => l.metaverse_apiCredentialStatus,
    'credentials.capture' => l.metaverse_apiCredentialCapture,
    'credentials.remove' => l.metaverse_apiCredentialRemove,
    'credentials.request' => l.metaverse_apiCredentialRequest,
    'connect.authorize' => l.metaverse_apiConnect,
    'payments.request' => l.metaverse_apiPayment,
    'fetch' => l.metaverse_apiFetch,
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
    "'account'",
    {'authorized': true, 'expiresAt': 2000000000},
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
  MetaverseApiExample('storage.set', "'example', {value: 1}", null),
  MetaverseApiExample('storage.remove', "'example'", null),
  MetaverseApiExample('user.get', '', {
    'username': 'example',
  }, permission: 'identity'),
  MetaverseApiExample(
    'navigate',
    "'detail', {id: 'example'}",
    null,
    userAction: true,
  ),
  MetaverseApiExample(
    'prepareNavigation',
    "'detail'",
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
