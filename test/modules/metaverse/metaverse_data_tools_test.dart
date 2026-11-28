import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

void main() {
  test('SDK 数据工具在真实 QuickJS 合并查询、拒绝迟到值并限制缓存', () async {
    final engine = await IsolateScriptEngine.spawn();
    addTearDown(() async {
      engine.dispose();
      await engine.terminated;
    });
    final done = Completer<Map>();
    engine.onMessage = (value) {
      if (value is Map && value['t'] == 'result') done.complete(value);
    };
    engine.onFatal = (reason) {
      if (!done.isCompleted) done.completeError(StateError(reason));
    };
    await engine.evaluate(metaversePluginPrelude);
    final helpers = File('test/fixtures/metaverse/sdk/data.mjs')
        .readAsStringSync()
        .replaceAll(RegExp(r'^export ', multiLine: true), '');
    await engine.evaluate('''
      $helpers
      (async()=>{
        const query=createQueryClient({maxEntries:32}),start=Date.now();let calls=0;
        await Promise.all(Array.from({length:100},()=>query.query('same',async()=>++calls,{ttl:1000})));
        let finish;const late=query.query('late',()=>new Promise(r=>finish=r));await Promise.resolve();
        const rejected=late.catch(error=>error.name);query.setIdentity(2);finish(99);
        const cancelled=await rejected;
        for(let i=0;i<1000;i++)await query.query(i,async()=>({id:i}));
        sendMessage('${MetaverseScriptEngine.channel}',JSON.stringify({t:'result',calls,cancelled,evicted:query.peek(0).data===undefined,elapsedMs:Date.now()-start}));
      })().catch(error=>sendMessage('${MetaverseScriptEngine.channel}',JSON.stringify({t:'result',error:String(error)})));
    ''');
    final result = await done.future.timeout(const Duration(seconds: 10));
    expect(result['error'], isNull);
    expect(result['calls'], 1);
    expect(result['cancelled'], 'QueryCancelledError');
    expect(result['evicted'], true);
    // 时间用于比较同一 runner 上的趋势，跨机器不设苛刻的帧率阈值。
    final output = File('build/plugin-performance.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode(result));
  });
}
