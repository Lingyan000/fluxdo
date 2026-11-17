import 'dart:async';
import 'dart:convert';

import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

/// 仅在用户确认的开发会话中封装引擎；正式运行时不暴露开发协议。
class DevelopmentEngine extends MetaverseScriptEngine {
  DevelopmentEngine(
    this.inner, {
    required this.send,
    required this.reloadRequired,
    required this.diagnostic,
    required this.changed,
  }) {
    unawaited(_ready.future.catchError((Object _) {}));
  }
  final MetaverseScriptEngine inner;
  final void Function(Map<String, dynamic>) send;
  final void Function() reloadRequired;
  final void Function(String) diagnostic;
  final void Function() changed;
  final _ready = Completer<void>();
  bool _closed = false;
  bool updating = false;

  @override
  set onMessage(void Function(Object?)? handler) {
    inner.onMessage = (message) {
      if (_closed) {
        return;
      }
      if (message is! Map || message['t'] != 'dev') {
        handler?.call(message);
        return;
      }
      switch (message['kind']) {
        case 'evaluate':
          final code = message['code'],
              file = message['file'],
              id = message['id'];
          if (code is! String ||
              code.length > 1024 * 1024 ||
              file is! String ||
              file.length > 1024 ||
              id is! int) {
            return;
          }
          unawaited(
            inner.evaluate(code, name: file).catchError((Object error) async {
              if (_closed) return;
              await inner.evaluate(
                '__devModuleDone($id,false,${jsonEncode(error.toString())})',
              );
            }),
          );
        case 'transport':
          send({'type': 'vite', 'payload': message['payload']});
        case 'loaded':
          if (!_ready.isCompleted) {
            _ready.complete();
          }
        case 'import-error':
          if (!_ready.isCompleted) {
            _ready.completeError(StateError('${message['error']}'));
          }
          diagnostic('${message['error']}');
        case 'reload-required':
          updating = false;
          reloadRequired();
        case 'update':
          updating = message['phase'] == 'before';
          changed();
      }
    };
  }

  @override
  set onFatal(void Function(String)? handler) {
    inner.onFatal = handler;
  }

  @override
  Future<void> evaluate(String code, {String name = 'main.js'}) async {
    final ready = name == 'main.js'
        ? _ready.future.timeout(const Duration(seconds: 20))
        : null;
    if (ready != null) {
      unawaited(ready.catchError((Object _) {}));
    }
    await inner.evaluate(code, name: name);
    if (ready != null) {
      await ready;
    }
  }

  Future<void> receive(Object? payload) async {
    if (_closed) {
      return;
    }
    await inner.evaluate(
      '__devReceive(${jsonEncode(payload)})',
      name: 'fluxdo-dev-transport.js',
    );
  }

  static String bootstrap(String runner, String entry) =>
      '''
$nativeEvaluator
$runner
(function(){
  const post = message => sendMessage('fluxdoMetaverse', JSON.stringify({t:'dev', ...message}));
  const runner = FluxdoDev.createPluginModuleRunner({
    transport: {
      connect(handlers) {globalThis.__devReceive = payload => handlers.onMessage(payload);},
      disconnect() {globalThis.__devReceive = () => {};},
      send(payload) {post({kind:'transport', payload});}
    },
    onReloadRequired() {post({kind:'reload-required'});},
    onUpdate(phase) {post({kind:'update', phase});}
  });
  runner.import(${jsonEncode(entry)}).then(() => post({kind:'loaded'}), error => post({kind:'import-error', error:String(error)}));
})();
''';

  @override
  void dispose() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('development_closed'));
    }
    inner.dispose();
  }
}

/// 用命名脚本执行模块；QuickJS 堆栈由此保留文件位置，供 CLI 使用源码映射。
const nativeEvaluator = r'''
(function(){
  let seq = 0;
  const jobs = new Map();
  globalThis.__devModuleContext = id => jobs.get(id).context;
  globalThis.__devModuleDone = (id, ok, error) => {
    const job=jobs.get(id); if(!job)return; jobs.delete(id);
    if(ok)job.resolve();else job.reject(typeof error==='string'?new Error(error):error);
  };
  globalThis.__fluxdoEvaluateModule = (context, code, file) => new Promise((resolve,reject)=>{
    const id=++seq; jobs.set(id,{context,resolve,reject});
    const names=Object.keys(context);
    const prefix='(async function('+names.join(',')+'){"use strict";\n';
    const suffix='\n})('+names.map(name=>'__devModuleContext('+id+')['+JSON.stringify(name)+']').join(',')+
      ').then(()=>__devModuleDone('+id+',true),error=>__devModuleDone('+id+',false,error));';
    sendMessage('fluxdoMetaverse',JSON.stringify({t:'dev',kind:'evaluate',id,code:prefix+code+suffix,file}));
  });
})();
''';
