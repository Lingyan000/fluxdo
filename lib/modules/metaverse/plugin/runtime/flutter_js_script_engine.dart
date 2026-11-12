/// flutter_js 引擎实现。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_js/flutter_js.dart';

import 'metaverse_script_engine.dart';

Future<MetaverseScriptEngine> createMetaverseScriptEngine() =>
    IsolateScriptEngine.spawn();

/// 每个插件一个独立 isolate 里的 JS 引擎
/// （Android/Windows/Linux = QuickJS，iOS/macOS = JavaScriptCore）。
///
/// 不能像 cook 那样直接在主 isolate 上同步跑：第三方脚本一旦死循环，FFI 调用
/// 不返回，整个应用就冻住了。flutter_js 0.8.7 的 `timeout` / `memoryLimit`
/// 参数靠不住——实测随附的原生库既不按超时打断执行，也没有导出
/// `jsSetMemoryLimit`。所以改由主 isolate 看门狗兜底：一条指令超过
/// [timeout] 没有返回，就判定引擎失效并回调 `onFatal`。
///
/// 已知代价：卡在原生循环里的 isolate 杀不掉（`Isolate.kill` 只在 Dart 代码的
/// 安全点生效），那条线程会空转到应用退出。界面不受影响，宿主应同时把该插件
/// 挂起，避免下次再启动它。
///
/// 独立 isolate 还顺带规避了 flutter_js 的 JavaScriptCore 封装把消息回调存在
/// 静态变量里、同一 isolate 内多个引擎互相覆盖的问题。
class IsolateScriptEngine implements MetaverseScriptEngine {
  IsolateScriptEngine._(this._isolate, this._events, this._timeout);

  static Future<IsolateScriptEngine> spawn({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final events = ReceivePort('metaverse-plugin-host');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _engineMain,
        events.sendPort,
        debugName: 'metaverse-plugin',
        errorsAreFatal: true,
        onExit: events.sendPort,
        onError: events.sendPort,
      );
    } catch (error) {
      events.close();
      throw MetaverseScriptException('脚本引擎启动失败: $error');
    }
    final engine = IsolateScriptEngine._(isolate, events, timeout);
    events.listen(engine._onEvent);
    try {
      await engine._ready.future.timeout(timeout);
    } on TimeoutException {
      engine._fail('脚本引擎启动超时');
      throw const MetaverseScriptException('脚本引擎启动超时');
    }
    return engine;
  }

  final Isolate _isolate;
  final ReceivePort _events;
  final Duration _timeout;

  final _ready = Completer<void>();
  final _pending = <int, Completer<void>>{};
  SendPort? _commands;
  Timer? _watchdog;
  int _seq = 0;
  String? _dead;

  @override
  void Function(Object? message)? onMessage;

  @override
  void Function(String reason)? onFatal;

  @override
  Future<void> evaluate(String code, {String name = '<plugin>'}) {
    final dead = _dead;
    if (dead != null) return Future.error(MetaverseScriptException(dead));
    final seq = ++_seq;
    final completer = Completer<void>();
    _pending[seq] = completer;
    _commands!.send([seq, code, name]);
    // 指令按序执行；看门狗盯的是"距上一次完成过去了多久"。
    _watchdog ??= Timer(_timeout, _onTimeout);
    return completer.future;
  }

  @override
  void dispose() {
    if (_dead != null) return;
    _dead = '脚本引擎已释放';
    onMessage = null;
    onFatal = null;
    _watchdog?.cancel();
    // 先请它自己释放原生引擎再退出；忙着或卡住时由下面的 kill 兜底。
    _commands?.send(null);
    _events.close();
    _rejectPending();
    final isolate = _isolate;
    Timer(const Duration(seconds: 2), () {
      isolate.kill(priority: Isolate.immediate);
    });
  }

  void _onEvent(Object? event) {
    if (_dead != null) return;
    // onExit 发来 null；onError 发来 [错误, 堆栈] 两个字符串。
    if (event == null) return _fail('脚本引擎意外退出');
    if (event is! List || event.isEmpty) return;
    switch (event[0]) {
      case 'ready':
        _commands = event[1] as SendPort;
        _ready.complete();
      case 'boot-error':
        final error = MetaverseScriptException('脚本引擎启动失败: ${event[1]}');
        _fail(error.message);
        if (!_ready.isCompleted) _ready.completeError(error);
      case 'msg':
        try {
          onMessage?.call(event[1]);
        } catch (_) {
          // 宿主处理一条消息出错不应中断后续消息。
        }
      case 'done':
        final completer = _pending.remove(event[1]);
        _watchdog?.cancel();
        _watchdog = _pending.isEmpty ? null : Timer(_timeout, _onTimeout);
        final error = event[2] as String?;
        if (error == null) {
          completer?.complete();
        } else {
          completer?.completeError(MetaverseScriptException(error));
        }
      default:
        // 未捕获的 isolate 错误。
        _fail('脚本引擎崩溃: ${event[0]}');
    }
  }

  void _onTimeout() => _fail('脚本执行超时（${_timeout.inSeconds} 秒未返回）');

  void _fail(String reason) {
    if (_dead != null) return;
    _dead = reason;
    _watchdog?.cancel();
    _events.close();
    _isolate.kill(priority: Isolate.immediate);
    _rejectPending();
    final handler = onFatal;
    onMessage = null;
    onFatal = null;
    handler?.call(reason);
  }

  void _rejectPending() {
    final error = MetaverseScriptException(_dead!);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }
}

/// 引擎 isolate 入口。与宿主的往来：
/// 宿主 → 引擎：`[seq, code, name]` 执行脚本；`null` 释放并退出。
/// 引擎 → 宿主：`['ready', SendPort]`、`['boot-error', 描述]`、
/// `['msg', 消息]`、`['done', seq, 错误或 null]`。
void _engineMain(SendPort host) {
  final JavascriptRuntime runtime;
  try {
    // xhr: false —— 不注入 fetch/XMLHttpRequest，脚本联网只能走宿主的白名单接口。
    runtime = getJavascriptRuntime(xhr: false);
    runtime.onMessage(MetaverseScriptEngine.channel, (dynamic message) {
      host.send(['msg', message]);
    });
  } catch (error) {
    host.send(['boot-error', error.toString()]);
    return;
  }

  final commands = ReceivePort('metaverse-plugin-engine');
  commands.listen((Object? command) {
    if (command == null) {
      commands.close();
      try {
        runtime.dispose();
      } catch (_) {
        // flutter_js 释放时遇到引用泄漏会抛错，这里已经要退出了。
      }
      return;
    }
    final [seq as int, code as String, name as String] = command as List;
    String? error;
    try {
      final result = runtime.evaluate(code, sourceUrl: name);
      runtime.executePendingJob();
      if (result.isError) error = result.stringResult;
    } catch (e) {
      error = e.toString();
    }
    host.send(['done', seq, error]);
  });
  host.send(['ready', commands.sendPort]);
}
