import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';

/// 真实 JS 引擎的契约测试。
///
/// 原生库通过 Dart native assets 构建，缺失应使测试失败，不能静默跳过。
Future<void> main() async {
  group('IsolateScriptEngine', () {
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

    tearDown(() async {
      engine.dispose();
      await engine.terminated.timeout(const Duration(seconds: 3));
      await arrivals.close();
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
      await received(4);
      expect(messages[0], {'t': 'event', 'phase': 'start', 'id': 1});
      expect(messages[1], {'t': 'data', 's': 's1', 'k': 'count', 'v': 2});
      expect((messages[2] as Map)['t'], 'error');
      expect((messages[2] as Map)['message'], 'later');
      expect(messages[3], {'t': 'event', 'phase': 'end', 'id': 1});
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

    test('持续排入的 Promise 微任务由原生截止时间中断', () async {
      await expectLater(engine.evaluate('function again(){Promise.resolve().then(again)};again()'),
        throwsA(isA<MetaverseScriptException>()));
      await engine.terminated.timeout(const Duration(seconds: 3));
    });
    test('堆增长命中内存上限并释放运行时', () async {
      final limited = await IsolateScriptEngine.spawn(memoryLimit: 8 * 1024 * 1024);
      addTearDown(limited.dispose);
      await expectLater(limited.evaluate('var a=[];while(true){a.push(new Array(10000).fill(123));}'),
        throwsA(isA<MetaverseScriptException>().having((e)=>e.message,'reason',contains('内存'))));
      await limited.terminated.timeout(const Duration(seconds: 3));
    });
    test('释放直接中断长任务，无须等到任务截止时间', () async {
      final running = await IsolateScriptEngine.spawn(timeout: const Duration(seconds: 30));
      final result = expectLater(running.evaluate('while(true){}'), throwsA(isA<MetaverseScriptException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      running.dispose();
      await result;
      await running.terminated.timeout(const Duration(seconds: 2));
    });

    test('递归耗尽栈预算后仍可处理下一条命令', () async {
      await expectLater(engine.evaluate('function recurse(){return recurse()};recurse()'),
        throwsA(isA<MetaverseScriptException>().having((e) => e.message, 'reason', contains('stack'))));
      await engine.evaluate("console.log('recovered')");
      await received(1);
      expect((messages.single as Map)['message'], 'recovered');
    });

    test('重建引擎与多次跨事件执行保持独立的栈预算', () async {
      for (var index = 0; index < 16; index++) {
        final restarted = await IsolateScriptEngine.spawn();
        try {
          await restarted.evaluate(metaversePluginPrelude);
          for (var event = 0; event < 3; event++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            await restarted.evaluate('Promise.resolve(42).then(value => value + 1)');
          }
        } finally {
          restarted.dispose();
          await restarted.terminated.timeout(const Duration(seconds: 3));
        }
      }
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
