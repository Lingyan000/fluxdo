import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_captcha_request.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_data_migration.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_files.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_captcha_sheet.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/widgets/common/captcha_panel.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'metaverse_navigation_forum_test.dart' show Engine;

Map<String, dynamic> declaration() => {
  'schema': 12,
  'apiVersion': 2,
  'id': 'example.attachments',
  'version': '1.0.0',
  'name': '附件',
  'author': 'tester',
  'ui': 'ui.rfwtxt',
  'script': 'main.js',
  'card': {'widget': 'Card'},
  'requiredFeatures': [
    'fileAttachments',
    'captchaChallenge',
    'manifestLocalization',
  ],
  'locales': {
    'en': {'name': 'Attachments'},
  },
  'permissions': {
    'network': ['service.example'],
    'credentials': {
      'account': {
        'requests': [
          {
            'origin': 'https://service.example',
            'pathPrefix': '/reports',
            'methods': ['GET', 'POST'],
          },
        ],
      },
    },
  },
};
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1WQAAAAASUVORK5CYII=',
);

class Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Uint8List>[];
  bool image = false;
  int status = 200;
  Completer<void>? hold;
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(request);
    final bytes = BytesBuilder();
    if (body != null) {
      await for (final chunk in body) {
        bytes.add(chunk);
      }
    }
    bodies.add(bytes.takeBytes());
    if (hold != null) {
      await Future.any([
        hold!.future,
        if (cancel != null) cancel.then((_) => throw StateError('cancelled')),
      ]);
    }
    return ResponseBody.fromBytes(
      image ? png : utf8.encode('{"success":true}'),
      status,
      headers: {
        'set-cookie': ['private=1'],
        'location': ['https://other.example/file'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class Delegate extends MetaversePluginHostDelegate {
  int? account = 7;
  Completer<MetaversePickedFile?>? pending;
  Future<void> Function(Future<Uint8List> Function(), Future<void>)? onPreview;
  @override
  int? currentAccountId() => account;
  @override
  String? currentUsername() => 'tester';
  @override
  Future<MetaversePickedFile?> pickFile(
    BuildContext context,
    MetaverseFileSelection selection,
  ) async => pending?.future ?? MetaversePickedFile('proof.png', png);
  @override
  Future<void> previewFile(
    BuildContext context,
    Future<Uint8List> Function() load,
    Future<void> revoked,
  ) async => onPreview?.call(load, revoked);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('临时文件句柄绑定页面，容量受限并在关闭时取消操作', () {
    final vault = MetaverseFileVault(),
        selection = MetaverseFileSelection.parse({
          'extensions': ['png'],
          'maxBytes': 1024,
        });
    final file = vault.keep(
      'one',
      MetaversePickedFile('proof.png', png),
      selection,
    );
    expect(file.keys, unorderedEquals(['handle', 'name', 'size', 'mimeType']));
    expect(
      () => vault.read('two', file['handle']),
      throwsA(isA<MetaversePluginCallException>()),
    );
    for (final name in ['../proof.png', 'proof.exe']) {
      expect(
        () => vault.keep('one', MetaversePickedFile(name, png), selection),
        throwsA(isA<MetaversePluginCallException>()),
      );
    }
    final cancel = vault.start('one', 'upload');
    vault.cancel('two', 'upload');
    expect(cancel.isCancelled, false);
    vault.close('one');
    expect(cancel.isCancelled, true);
    expect(
      () => vault.read('one', file['handle']),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(
      () => MetaverseFileSelection.parse({
        'extensions': ['*'],
      }),
      throwsA(isA<MetaversePluginCallException>()),
    );
  });
  test('附件上传复用权限出口，JSON 与 multipart 真正发送文件并过滤 Cookie', () async {
    final adapter = Adapter(),
        manifest = MetaversePluginManifest.parse(declaration());
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('1.1.1.1')],
    );
    addTearDown(network.dispose);
    for (final encoding in ['base64', 'multipart']) {
      final response = await network.uploadFile(
        manifest,
        request: {
          'url': 'https://service.example/reports/1',
          'credential': 'account',
          'encoding': encoding,
          'field': 'data',
          'fields': {'operationId': 'same-operation'},
        },
        file: MetaversePickedFile('proof.png', png),
        authToken: 'fixture-token',
        cancel: CancelToken(),
        checkActive: () {},
        onProgress: (_, _) {},
      );
      expect(response['status'], 200);
      expect((response['headers'] as Map).containsKey('set-cookie'), false);
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer fixture-token',
      );
      expect(adapter.requests.last.headers.containsKey('Cookie'), false);
      final body = utf8.decode(adapter.bodies.last, allowMalformed: true);
      if (encoding == 'base64') {
        expect(base64Decode(jsonDecode(body)['data']), png);
        expect(jsonDecode(body)['operationId'], 'same-operation');
      } else {
        expect(body, contains('filename="proof.png"'));
        expect(body, contains('same-operation'));
      }
    }
    await expectLater(
      network.uploadFile(
        manifest,
        request: {
          'url': 'https://service.example/outside',
          'credential': 'account',
          'encoding': 'base64',
        },
        file: MetaversePickedFile('proof.png', png),
        authToken: 'fixture-token',
        cancel: CancelToken(),
        checkActive: () {},
        onProgress: (_, _) {},
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(adapter.requests.length, 2);
  });
  test('私密图片不接受跳转或非图片，撤权后迟到结果丢弃', () async {
    final adapter = Adapter()..image = true,
        manifest = MetaversePluginManifest.parse(declaration());
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('1.1.1.1')],
    );
    addTearDown(network.dispose);
    var active = true;
    Future<Uint8List> load() => network.privateImage(
      manifest,
      request: {
        'url': 'https://service.example/reports/1/evidence',
        'credential': 'account',
      },
      authToken: 'fixture-token',
      cancel: CancelToken(),
      checkActive: () {
        if (!active) throw const PluginOperationCancelled();
      },
    );
    expect(await load(), png);
    adapter.status = 302;
    await expectLater(load(), throwsA(isA<MetaversePluginCallException>()));
    adapter.status = 200;
    adapter.image = false;
    await expectLater(load(), throwsA(isA<MetaversePluginCallException>()));
    adapter.image = true;
    adapter.hold = Completer();
    final pending = load();
    while (adapter.requests.length < 4) {
      await Future<void>.delayed(Duration.zero);
    }
    active = false;
    adapter.hold!.complete();
    await expectLater(pending, throwsA(isA<PluginOperationCancelled>()));
  });
  testWidgets('选择文件必须来自所属页面点击，账号切换丢弃晚到文件', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('attachments-'),
    ))!;
    final store = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => directory,
    );
    final delegate = Delegate();
    final network = MetaversePluginNetwork();
    final host = MetaversePluginHost(
      manifest: MetaversePluginManifest.parse(declaration()),
      store: store,
      network: network,
      engineFactory: () async => Engine(),
      delegate: delegate,
      codeLoader: () async =>
          (ui: 'import fluxdo; widget Card = Gap();', script: ''),
    );
    addTearDown(() async {
      host.shutdown();
      network.dispose();
      await directory.delete(recursive: true);
    });
    final surface = await host.open(kind: 'card');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            host.attachSurface(surface, context);
            return const SizedBox();
          },
        ),
      ),
    );
    Future<Object?> pick() =>
        PluginExecutionContext(
          pluginId: host.id,
          pluginVersion: '1.0.0',
          runtimeId: host.runtimeId,
          surfaceId: surface.id,
        ).run(
          () => host.call('files.pick', {
            'extensions': ['png'],
          }),
        );
    await expectLater(pick(), throwsA(isA<MetaversePluginCallException>()));
    host.dispatchUserEvent(surface, 'choose', {});
    final selected = await pick() as Map;
    expect(selected['name'], 'proof.png');
    final covered = Completer<void>();
    delegate.onPreview = (load, revoked) async {
      host.setSurfaceForeground(surface, false);
      expect(await load(), png);
      covered.complete();
      await revoked;
    };
    host.dispatchUserEvent(surface, 'preview', {});
    final preview = PluginExecutionContext(
      pluginId: host.id,
      pluginVersion: '1.0.0',
      runtimeId: host.runtimeId,
      surfaceId: surface.id,
    ).run(() => host.call('files.preview', {'handle': selected['handle']}));
    await covered.future;
    host.setSurfaceForeground(surface, false, appForeground: false);
    await preview;
    host.setSurfaceForeground(surface, true);
    await expectLater(
      PluginExecutionContext(
        pluginId: host.id,
        pluginVersion: '1.0.0',
        runtimeId: host.runtimeId,
        surfaceId: surface.id,
      ).run(() => host.call('files.release', {'handle': selected['handle']})),
      throwsA(isA<MetaversePluginCallException>()),
    );
    delegate.pending = Completer();
    host.dispatchUserEvent(surface, 'choose', {});
    final pending = pick();
    delegate.account = 8;
    delegate.pending!.complete(MetaversePickedFile('late.png', png));
    await expectLater(pending, throwsA(isA<PluginOperationCancelled>()));
  });
  test('清单本地化不修改权限与身份，未知字段拒绝', () {
    final raw = declaration(),
        manifest = MetaversePluginManifest.parse(declaration());
    expect(manifest.localizedName('en-US'), 'Attachments');
    expect(manifest.localizedName('fr'), '附件');
    final translated = MetaversePluginManifest.parse({
      ...raw,
      'locales': {
        'en': {'name': 'Other text'},
      },
    });
    expect(manifest.sameApprovalAs(translated), true);
    expect(
      () => MetaversePluginManifest.parse({
        ...raw,
        'locales': {
          'en': {'permissions.network': 'evil.example'},
        },
      }),
      throwsA(isA<MetaverseManifestException>()),
    );
    final data = {
      'submission:7': {'state': 'pending'},
      '@forum-account:9:key': 1,
    };
    expect(
      partitionMetaverseData(data, 7)['@forum-account:7:submission:7'],
      data['submission:7'],
    );
    expect(partitionMetaverseData(data, null), data);
  });
  test('验证码只能使用声明的 origin、官方提供方与安全 siteKey', () {
    final manifest = MetaversePluginManifest.parse(declaration());
    final args = {
      'provider': 'hcaptcha',
      'origin': 'https://service.example',
      'siteKey': 'public-site-key',
    };
    final request = MetaverseCaptchaRequest.parse(manifest, args);
    for (final change in [
      {'origin': 'https://linux.do'},
      {'origin': 'https://service.example/path'},
      {'siteKey': '</script>'},
      {'provider': 'custom'},
    ]) {
      expect(
        () => MetaverseCaptchaRequest.parse(manifest, {...args, ...change}),
        throwsA(isA<MetaversePluginCallException>()),
      );
    }
    final html = metaverseCaptchaHtml(
      request,
      background: '#ffffff',
      dark: false,
    );
    expect(html, contains('Content-Security-Policy'));
    expect(html, contains("form-action 'none'"));
    expect(html, contains('https://js.hcaptcha.com/1/api.js'));
    expect(html, contains('public-site-key'));
  });
  testWidgets('验证码取消与过期不返回令牌，重试后仅接受新挑战', (tester) async {
    late void Function(String, String) send;
    String? result;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showCaptchaSheet<String>(
                    context: context,
                    title: '验证',
                    builder: (_) => MetaverseCaptchaContent(
                      pluginName: '附件',
                      request: MetaverseCaptchaRequest(
                        MetaverseCaptchaProvider.hcaptcha,
                        Uri.parse('https://service.example'),
                        'public',
                      ),
                      checkActive: () {},
                      challengeBuilder: (context, event) {
                        send = event;
                        return const SizedBox();
                      },
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final old = send;
    send('error', 'expired');
    await tester.pumpAndSettle();
    old('token', 'stale');
    expect(result, isNull);
    await tester.tap(
      find.text(
        tester.element(find.byType(MetaverseCaptchaContent)).l10n.common_retry,
      ),
    );
    await tester.pump();
    old('token', 'stale');
    expect(result, isNull);
    send('challenge', '');
    await tester.pump();
    send('token', 'fresh');
    await tester.pumpAndSettle();
    expect(result, 'fresh');
    result = null;
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final dialogContext = tester.element(find.byType(MetaverseCaptchaContent));
    Navigator.of(dialogContext).pop();
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
