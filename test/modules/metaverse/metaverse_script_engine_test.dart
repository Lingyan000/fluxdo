import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';

/// 真实 JS 引擎的契约测试。
///
/// 宿主测试环境默认加载不到 `quickjs_c_bridge.dll`，那时整组跳过；本机验证
/// 时把构建产物目录加进 PATH 再跑：
/// `PATH="build/windows/x64/runner/Debug:$PATH" flutter test <本文件>`
Future<void> main() async {
  String? skip;
  try {
    (await IsolateScriptEngine.spawn()).dispose();
  } on MetaverseScriptException catch (error) {
    skip = '脚本引擎原生库不可用: $error';
  }

  group('IsolateScriptEngine', skip: skip, () {
    late IsolateScriptEngine engine;
    late List<Object?> messages;
    late StreamController<Object?> arrivals;

    /// 等到脚本发来第 [count] 条消息。
    Future<void> received(int count) async {
      while (messages.length < count) {
        await arrivals.stream.first.timeout(const Duration(seconds: 5));
      }
    }

    setUp(() async {
      engine = await IsolateScriptEngine.spawn(
        timeout: const Duration(milliseconds: 600),
      );
      messages = [];
      arrivals = StreamController.broadcast();
      engine.onMessage = (message) {
        messages.add(message);
        arrivals.add(message);
      };
      await engine.evaluate(metaversePluginPrelude, name: 'prelude');
    });

    tearDown(() {
      engine.dispose();
      arrivals.close();
    });

    test('脚本经通道投递的消息以解码后的对象到达宿主', () async {
      await engine.evaluate(
        "sendMessage('${MetaverseScriptEngine.channel}', "
        "JSON.stringify({t: 'x', n: 1}))",
      );
      await received(1);
      expect(messages, [
        {'t': 'x', 'n': 1},
      ]);
    });

    test('脚本抛错转成 MetaverseScriptException，引擎仍可用', () async {
      await expectLater(
        engine.evaluate('throw new Error("boom")'),
        throwsA(
          isA<MetaverseScriptException>().having(
            (e) => e.message,
            'message',
            contains('boom'),
          ),
        ),
      );
      await engine.evaluate("console.log('alive')");
      await received(1);
      expect((messages.single as Map)['message'], 'alive');
    });

    test('前导脚本不留下可直接联网的全局对象', () async {
      await engine.evaluate(
        'console.log(typeof fetch, typeof XMLHttpRequest, typeof require)',
      );
      await received(1);
      expect(
        (messages.single as Map)['message'],
        'undefined undefined undefined',
      );
    });

    test('宿主回填后 Promise 续跑', () async {
      await engine.evaluate(
        "fluxdo.storage.get('k').then(v => console.log('got', v))",
      );
      await received(1);
      final call = messages.single as Map;
      expect(call['t'], 'call');
      expect(call['m'], 'storage.get');

      await engine.evaluate(
        '__fluxdoMetaverse.settle(${call['id']}, true, "42")',
      );
      await received(2);
      expect(messages[1], {'t': 'log', 'level': 'info', 'message': 'got 42'});
    });

    test('事件分发把上下文与参数交给处理器，异步处理器的拒绝会上报', () async {
      await engine.evaluate('''
        fluxdo.on('tap', async (ctx, args) => {
          ctx.setData('count', args.n + 1);
          throw new Error('later');
        });
      ''');
      await engine.evaluate(
        "__fluxdoMetaverse.dispatch('tap', "
        "'{\"surface\":\"s1\",\"kind\":\"card\"}', '{\"n\":1}')",
      );
      await received(2);
      expect(messages[0], {'t': 'data', 's': 's1', 'k': 'count', 'v': 2});
      expect((messages[1] as Map)['t'], 'error');
      expect((messages[1] as Map)['message'], 'later');
    });

    test('死循环不阻塞宿主：看门狗判定失效并回调 onFatal', () async {
      final fatal = Completer<String>();
      engine.onFatal = fatal.complete;
      final stopwatch = Stopwatch()..start();
      final running = engine.evaluate('while (true) {}');
      unawaited(running.then((_) {}, onError: (_) {}));

      // 引擎在死循环期间，宿主 isolate 的事件循环照常运转。
      var ticks = 0;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => ticks++,
      );
      final reason = await fatal.future.timeout(const Duration(seconds: 5));
      ticker.cancel();

      expect(reason, contains('超时'));
      expect(ticks, greaterThan(5));
      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
      await expectLater(running, throwsA(isA<MetaverseScriptException>()));
      await expectLater(
        engine.evaluate('1'),
        throwsA(isA<MetaverseScriptException>()),
      );
    });

    test('空闲再久也不会被看门狗误杀', () async {
      var fatal = false;
      engine.onFatal = (_) => fatal = true;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await engine.evaluate("console.log('still running')");
      await received(1);
      expect(fatal, isFalse);
    });

    test('释放后拒绝执行', () async {
      final disposed = await IsolateScriptEngine.spawn()
        ..dispose();
      await expectLater(
        disposed.evaluate('1'),
        throwsA(isA<MetaverseScriptException>()),
      );
    });
  });
}
