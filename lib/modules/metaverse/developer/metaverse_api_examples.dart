import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

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
  String get script =>
      '''fluxdo.on('${userAction ? 'action' : 'card.load'}', async (ctx) => {
  try {
    const result = await ctx.api.$name($arguments);
    $afterCall
  } catch (error) {
    console.error(error.message);
  }
});''';
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
];

/// 开发中心始终注入这个演示桥，独立于已安装插件、账号、网络和支付服务。
class MetaverseDocumentationBridge implements MetaversePluginBridge {
  MetaverseDocumentationBridge({
    required this.example,
    required this.failure,
    required this.onLog,
  });
  final MetaverseApiExample example;
  final bool failure;
  final void Function(String level, String message) onLog;

  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
    onLog('call', '$method $params');
    if (failure) {
      throw const MetaversePluginCallException('demo_permission_denied');
    }
    return example.result;
  }

  @override
  void log(String level, String message) => onLog(level, message);
}
