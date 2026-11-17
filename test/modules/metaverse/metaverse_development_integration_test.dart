import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/developer/session/development_session.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    '真实 CLI 与 App 会话完成配对、JS/RFW 更新、错误恢复和重新授权',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'plugin-device-integration-',
      );
      final project = await Directory('${root.path}/project').create();
      await Directory('${project.path}/src').create();
      final manifest = {
        'schema': 10,
        'apiVersion': 2,
        'id': 'example.device',
        'name': 'Device',
        'version': '1.0.0',
        'author': 'test',
        'ui': 'ui.rfwtxt',
        'script': 'main.js',
        'card': {'widget': 'Card'},
        'permissions': {'network': <String>[]},
      };
      await File('${project.path}/plugin.json')
          .writeAsString(jsonEncode(manifest));
      await File('${project.path}/package.json')
          .writeAsString('{"type":"module"}');
      final ui = File('${project.path}/ui.rfwtxt');
      await ui.writeAsString(
        'import fluxdo; widget Card = Label(text:data.caption);',
      );
      const script =
          '''fluxdo.on('card.load',ctx=>ctx.setData('caption','initial'));
fluxdo.on('change',ctx=>ctx.setData('caption','v1'));
fluxdo.on('hold',async ctx=>{await new Promise(r=>setTimeout(r,1000));ctx.setData('released',true);});
if(import.meta.hot)import.meta.hot.accept();''';
      final entry = File('${project.path}/src/main.ts');
      await entry.writeAsString(script);
      final process = await Process.start('node', [
        'tool/plugin_tools/device_peer.mjs',
        project.path,
      ], runInShell: false);
      final errors = <String>[];
      process.stderr.transform(utf8.decoder).listen(errors.add);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      await lines.moveNext().timeout(const Duration(seconds: 15));
      final pairing = lines.current;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final network = MetaversePluginNetwork();
      final sessionProvider = Provider<DevelopmentSession>(
        (ref) => DevelopmentSession(ref, temporaryDirectory: () async => root),
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          metaversePluginNetworkProvider.overrideWithValue(network),
        ],
      );
      final session = container.read(sessionProvider);
      addTearDown(() async {
        session.dispose();
        container.dispose();
        network.dispose();
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 10));
        await lines.cancel();
        if (await root.exists()) await root.delete(recursive: true);
      });
      await session.connect(pairing);
      await _until(() => session.pendingProject != null);
      expect(session.host, isNull, reason: '审阅之前不能执行脚本');
      await session.start(session.pendingProject!);
      final host = session.host!;
      final surface = await host.open(kind: 'card');
      await _until(() => surface.data['caption'] == 'initial');
      host.dispatchUserEvent(surface, 'change', {});
      await _until(() => surface.data['caption'] == 'v1');
      host.dispatchUserEvent(surface, 'hold', {});
      await _until(() => !host.canApplyDevelopmentUpdate);
      await entry.writeAsString(script.replaceAll("'v1'", "'v2'"));
      await _until(() => session.waiting);
      expect(surface.data['released'], isNull, reason: '事件完成前暂缓模块替换');
      await _until(
        () =>
            surface.data['released'] == true &&
            !session.waiting &&
            !session.updating,
      );
      host.dispatchUserEvent(surface, 'change', {});
      await _until(() => surface.data['caption'] == 'v2');
      await ui.writeAsString(
        'import fluxdo; widget Card = Label(text:data.caption, bold:true);',
      );
      await _until(() => session.revision == 2);
      expect(surface.data['caption'], 'v2');
      await ui.writeAsString('import fluxdo; widget Card = Label(typo:true);');
      await _until(() => session.diagnostics.isNotEmpty);
      expect(session.revision, 2);
      await ui.writeAsString(
        'import fluxdo; widget Card = Label(text:data.caption);',
      );
      await _until(() => session.revision == 3);
      await File('${project.path}/plugin.json')
          .writeAsString(jsonEncode({...manifest, 'version': '1.0.1'}));
      await _until(() => session.pendingProject != null);
      expect(identical(session.host, host), isTrue);
      expect(session.restartRequired, isTrue);
      expect(session.pendingProject!.manifest.version, '1.0.1');
      expect(errors, isEmpty);
    },
    skip: Platform.environment['FLUXDO_PLUGIN_TOOLS'] == null
        ? '需要已构建的 FLUXDO_PLUGIN_TOOLS'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 1000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待真实开发连接超时');
}
