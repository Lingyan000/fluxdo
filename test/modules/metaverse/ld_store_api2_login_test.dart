import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_connect_capability.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../fixtures/metaverse/ld_store_oauth.dart';

class _Delegate extends MetaversePluginHostDelegate {
  _Delegate(this.manifest, this.client);
  final MetaversePluginManifest manifest;
  final Dio client;
  @override
  int currentAccountId() => 42;
  @override
  String currentUsername() => 'tester';
  @override
  Future<String?> authorizeConnect(BuildContext context, Uri authorization) =>
      MetaverseConnectCapability(client)
          .authorize(manifest, authorization, isActive: () => context.mounted);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main() async {
  String? unavailable;
  try {
    (await IsolateScriptEngine.spawn()).dispose();
  } on MetaverseScriptException catch (error) {
    unavailable = '脚本引擎原生库不可用 $error';
  }
  final manifest = MetaversePluginManifest.parse(
    jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
  );
  final script = File('plugins/ld-store/main.js').readAsStringSync();
  final ui = File('plugins/ld-store/ui.rfwtxt').readAsStringSync();

  void loginTest(
    String name,
    void Function(LdStoreOAuthAdapter) configure, {
    bool succeeds = true,
    int? exchanges,
  }) {
    testWidgets(name, (tester) async {
      SharedPreferences.setMockInitialValues({});
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ld-store-api2-'),
      ))!;
      final store = MetaversePluginStore(
        preferences: await SharedPreferences.getInstance(),
        secretStore: InMemorySecretStore(),
        rootDirectory: () async => root,
      );
      final adapter = LdStoreOAuthAdapter();
      configure(adapter);
      final client = Dio()..httpClientAdapter = adapter;
      final network = MetaversePluginNetwork(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = adapter,
        lookup: (_) async => [InternetAddress('198.18.0.6')],
      );
      final host = MetaversePluginHost(
        manifest: manifest,
        store: store,
        network: network,
        engineFactory: createMetaverseScriptEngine,
        delegate: _Delegate(manifest, client),
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      try {
        await tester.runAsync(() async {
          await store.writeCode(manifest.id, (
            ui: ui,
            script: '''$script
fluxdo.on('fixture.login', async ctx => {
  try { ctx.setData('result', await ldStore.login(ctx.api)); }
  catch (error) { ctx.setData('failure', error.message); }
  ctx.setData('finished', true);
});''',
          ));
          final surface = await host.open(kind: 'card');
          host.attachSurface(surface, context);
          host.dispatchUserEvent(surface, 'fixture.login', const {});
          for (var i = 0; i < 400 && surface.data['finished'] != true; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(surface.data['finished'], true, reason: '${surface.data}');
          expect(
            surface.data['result'] == true,
            succeeds,
            reason: '${surface.data}',
          );
          final credential = await store.readCredential(manifest.id, 'account');
          expect(credential != null, succeeds);
          if (succeeds) {
            expect(credential!.accountId, 42);
            expect(credential.secret, adapter.token);
            expect(surface.data['failure'], isNull);
          } else {
            expect(surface.data['failure'], contains('登录在「'));
          }
          expect(jsonEncode(surface.data), isNot(contains(adapter.token)));
          expect(
            adapter.requests.where((r) => r.uri.path.endsWith('/exchange')),
            hasLength(exchanges ?? (succeeds ? 1 : 0)),
          );
          expect(
            adapter.requests.any((r) => r.uri.host == 'ldcstore.com'),
            false,
          );
          expect(
            adapter.requests.any((r) => r.uri.host == 'untrusted.example'),
            false,
          );
        });
      } finally {
        await tester.runAsync(() async {
          host.shutdown();
          network.dispose();
          client.close(force: true);
          await root.delete(recursive: true);
        });
      }
    }, skip: unavailable != null);
  }

  for (final encoding in ['standard', 'escaped', 'percentJson', 'url']) {
    for (final query in [true, false]) {
      loginTest('API 2 士多脚本完成 PKCE 与凭证核验 $encoding query=$query', (api) {
        api.handoffEncoding = encoding;
        api.queryHandoff = query;
      });
    }
  }
  final html = <String, String Function(String)>{
    'meta': (url) => '<meta http-equiv="refresh" content="0;url=$url">',
    'entity': (url) => '<a href="${url.replaceAll('&', '&amp;')}">继续</a>',
    'script': (url) => '<script>location.replace(${jsonEncode(url)});</script>',
    'single': (url) => "<script>location.href = '$url';</script>",
    'template': (url) => '<script>location.href = `$url`;</script>',
    'escaped': (url) =>
        '<script>location.assign('
        '${jsonEncode(url).replaceAll('/', r'\/').replaceAll('&', r'\u0026')}'
        ');</script>',
    'duplicate': (url) =>
        '<a href="$url">继续</a>'
        '<script>const target=${jsonEncode(url)};setTimeout(()=>location.replace(target),500);</script>',
  };
  for (final entry in html.entries) {
    loginTest('API 2 士多 HTML ${entry.key} 仅请求一次回调', (api) {
      api.callbackStatus = 200;
      api.queryHandoff = true;
      api.handoffEncoding = 'standard';
      api.callbackDocument = () =>
          entry.value('${api.callbackUrl}&redirect=%2F');
    });
  }
  for (final issue in [
    'host',
    'path',
    'http',
    'userinfo',
    'ambiguous',
    'comment',
    'externalScript',
    'json',
    'errorStatus',
    'state',
    'identity',
    'verify',
    'exchange',
  ]) {
    loginTest(
      'API 2 士多拒绝 $issue 并清理未验证凭证',
      (api) {
        api.callbackStatus = issue == 'errorStatus' ? 403 : 200;
        api.callbackType = issue == 'json' ? 'application/json' : 'text/html';
        api.wrongState = issue == 'state';
        api.wrongIdentity = issue == 'identity';
        api.verifyFailed = issue == 'verify';
        api.exchangeTimeout = issue == 'exchange';
        api.callbackDocument = () {
          final url = switch (issue) {
            'host' => api.callbackUrl.replaceFirst(
              'ldcstore.com',
              'untrusted.example',
            ),
            'path' => api.callbackUrl.replaceFirst('/auth/callback', '/other'),
            'http' => api.callbackUrl.replaceFirst('https:', 'http:'),
            'userinfo' => api.callbackUrl.replaceFirst(
              'https://',
              'https://injected@',
            ),
            _ => api.callbackUrl,
          };
          return switch (issue) {
            'ambiguous' => '<a href="$url">继续</a><a href="${url}other">继续</a>',
            'comment' =>
              '<script>/* location.href=${jsonEncode(url)}; */</script>',
            'externalScript' =>
              '<script src="https://untrusted.example/script">'
                  'location.href=${jsonEncode(url)};</script>',
            _ => '<script>location.href=${jsonEncode(url)};</script>',
          };
        };
      },
      succeeds: false,
      exchanges: ['identity', 'verify', 'exchange'].contains(issue) ? 1 : 0,
    );
  }
}
