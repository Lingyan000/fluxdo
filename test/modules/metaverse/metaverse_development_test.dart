import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_component_contract.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_ui_validator.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:fluxdo/modules/metaverse/developer/metaverse_development_page.dart';
import 'package:fluxdo/modules/metaverse/developer/session/development_connection.dart';
import 'package:fluxdo/modules/metaverse/developer/session/development_engine.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Delegate extends MetaversePluginHostDelegate {
  @override
  String? currentUsername() => null;
  @override
  void onSuspended(String id, String reason) {
    throw StateError(reason);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> get manifest => {
  'schema': 10,
  'apiVersion': 2,
  'id': 'example.development',
  'version': '1.0.0',
  'name': 'Development',
  'author': 'test',
  'ui': 'ui.rfwtxt',
  'script': 'main.js',
  'card': {'widget': 'Card'},
  'permissions': {'network': <String>[]},
};
void main() {
  test('更新交给 QuickJS 时即锁定预览，完成或投递失败后恢复', () async {
    final inner = await IsolateScriptEngine.spawn();
    final states = <bool>[];
    late final DevelopmentEngine engine;
    engine = DevelopmentEngine(
      inner,
      send: (_) {},
      reloadRequired: () {},
      diagnostic: fail,
      changed: () => states.add(engine.updating),
    )..onMessage = (_) {};
    addTearDown(() async {
      engine.dispose();
      await inner.terminated;
    });
    await inner.evaluate('''
globalThis.__devReceive = payload => {
  if (payload.fail) throw new Error('delivery failed');
  if (payload.phase) sendMessage('fluxdoMetaverse', JSON.stringify({
    t: 'dev', kind: 'update', phase: payload.phase
  }));
};
''');
    final delivery = engine.receive({'type': 'update', 'phase': 'before'});
    final lockedAtDispatch = engine.updating;
    await delivery;
    expect(lockedAtDispatch, isTrue, reason: '跨 isolate 投递时预览已经锁定');
    expect(states, [true]);
    await engine.receive({'type': 'custom', 'phase': 'after'});
    expect(states, [true, false]);

    await expectLater(
      engine.receive({'type': 'update', 'fail': true}),
      throwsA(isA<Exception>()),
    );
    expect(states, [true, false, true, false]);
  });

  test('组件参数契约与生产注册组件完全一致，验证士多界面', () {
    final registered = createMetaverseWidgetLibrary(
      loadImage: (_) async => throw StateError('unused'),
    ).widgets.keys.toSet();
    expect(metaverseComponentContract.keys.toSet(), registered);
    final source = File('test/fixtures/metaverse/ld-store/ui.rfwtxt')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(
      validatePluginUiContract(
        source,
        metaverseComponentContract,
      )['diagnostics'],
      isEmpty,
    );
  });
  test('配对只接受回环地址和完整随机令牌', () {
    final key = 'a' * 32;
    expect(
      DevelopmentConnection.parse('fluxdo-dev://127.0.0.1:5174?key=$key').port,
      5174,
    );
    for (final address in [
      'fluxdo-dev://192.168.1.2:5174?key=$key',
      'http://127.0.0.1:5174?key=$key',
      'fluxdo-dev://127.0.0.1:5174?key=short',
      'fluxdo-dev://127.0.0.1:5174/path?key=$key',
      'fluxdo-dev://user@127.0.0.1:5174?key=$key',
    ]) {
      expect(() => DevelopmentConnection.parse(address), throwsFormatException);
    }
  });

  test('开发存储和凭证不读取正式插件，清理不删除正式数据', () async {
    SharedPreferences.setMockInitialValues({
      MetaversePluginStore.indexKey: jsonEncode([
        {
          'manifest': manifest,
          'source': 'file:example.development',
          'enabled': true,
        },
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final root = await Directory.systemTemp.createTemp('dev-isolation-');
    addTearDown(() => root.delete(recursive: true));
    final production = MetaversePluginStore(
      preferences: prefs,
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => Directory('${root.path}/prod'),
    );
    final development = MetaversePluginStore(
      preferences: prefs,
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => Directory('${root.path}/dev'),
      isolated: true,
    );
    await production.writeToken('example.development', 'production-secret');
    await production.updateStorage('example.development', 'count', 5);
    expect(development.loadIndex(), isEmpty);
    expect(await development.readToken('example.development'), isNull);
    await development.updateStorage('example.development', 'count', 9);
    await development.deleteFiles('example.development');
    expect(await production.readStorage('example.development'), {'count': 5});
    expect(
      await production.readToken('example.development'),
      'production-secret',
    );
    await expectLater(development.saveIndex([]), throwsStateError);
    expect(production.loadIndex(), hasLength(1));
  });

  test('真实异步事件阻止替换，RFW 热更新不重放初始化', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('dev-host-');
    final network = MetaversePluginNetwork();
    final host = MetaversePluginHost(
      manifest: MetaversePluginManifest.parse(manifest),
      store: MetaversePluginStore(
        preferences: await SharedPreferences.getInstance(),
        secretStore: InMemorySecretStore(),
        rootDirectory: () async => root,
        isolated: true,
      ),
      network: network,
      engineFactory: () => IsolateScriptEngine.spawn(),
      delegate: _Delegate(),
      codeLoader: () async => (
        ui: 'import fluxdo; widget Card = Label(text: data.value);',
        script: '''fluxdo.on('card.load',async ctx=>{
        ctx.setData('value','first');
        await new Promise(resolve=>setTimeout(resolve,200));
        ctx.setData('value','ready');
      });''',
      ),
    );
    addTearDown(() async {
      host.shutdown();
      network.dispose();
      await root.delete(recursive: true);
    });
    final surface = await host.open(kind: 'card');
    await _until(() => surface.data['value'] == 'first');
    expect(host.canApplyDevelopmentUpdate, isFalse);
    await _until(
      () => surface.data['value'] == 'ready' && host.canApplyDevelopmentUpdate,
    );
    host.updateDevelopmentUi(
      'import fluxdo; widget Card = Label(text: "new");',
    );
    expect(surface.data['value'], 'ready');
    expect(host.isRunning, isTrue);
    expect(() => host.updateDevelopmentUi('broken'), throwsA(isA<Exception>()));
    expect(surface.data['value'], 'ready');
    host.close(surface);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('开发连接入口窄屏大字 ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final font = Platform.environment['PREVIEW_CJK_FONT'];
      if (font != null) {
        await tester.runAsync(() async {
          final bytes = await File(font).readAsBytes();
          final loader = FontLoader('PreviewCjk')
            ..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
        });
      }
      await tester.runAsync(() async {
        final icon = Symbols.link_rounded;
        final loader = FontLoader('packages/${icon.fontPackage}/${icon.fontFamily}')
          ..addFont(rootBundle.load('packages/${icon.fontPackage}/lib/fonts/MaterialSymbolsRounded.ttf'));
        try {await loader.load();} catch (_) {}
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          child: TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(
                brightness: brightness,
                fontFamily: font == null ? null : 'PreviewCjk',
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.4)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: const MetaverseDevelopmentPage(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
      if (Platform.environment['PLUGIN_DEV_SNAPSHOTS'] == '1') {
        await tester.runAsync(() async {
          final picture =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final png = await picture.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/plugin-dev-ui').create(recursive: true);
          await File('build/plugin-dev-ui/${brightness.name}.png')
              .writeAsBytes(png!.buffer.asUint8List());
          picture.dispose();
        });
      }
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待开发会话超时');
}
