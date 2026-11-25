import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:qjs/qjs.dart';

Future<MetaverseScriptEngine> createMetaverseScriptEngine() =>
    IsolateScriptEngine.spawn();

/// 每插件独立 isolate 与 QuickJS 运行时，原生层限制执行时间和 JS 堆。
/// 宿主可跨 isolate 中断原生执行，随后由工作 isolate 释放上下文并退出。
class IsolateScriptEngine implements MetaverseScriptEngine {
  IsolateScriptEngine._(this._isolate, this._events, this._timeout);

  static const defaultMemoryLimit = 64 * 1024 * 1024;

  static Future<IsolateScriptEngine> spawn({
    Duration timeout = const Duration(seconds: 5),
    int memoryLimit = defaultMemoryLimit,
  }) async {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    if (memoryLimit <= 0) throw ArgumentError.value(memoryLimit, 'memoryLimit');
    final events = ReceivePort('metaverse-plugin-host');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _engineMain,
        (events.sendPort, timeout, memoryLimit),
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
      await engine._ready.future.timeout(const Duration(seconds: 5));
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
  final _terminated = Completer<void>();
  final _pending = <int, Completer<void>>{};
  SendPort? _commands;
  JSInterruptHandle? _interrupt;
  Timer? _watchdog;
  Timer? _terminationGuard;
  int _sequence = 0;
  String? _dead;

  /// 原生上下文释放且工作 isolate 退出后完成。
  Future<void> get terminated => _terminated.future;

  @override
  void Function(Object? message)? onMessage;
  @override
  void Function(String reason)? onFatal;

  @override
  Future<void> evaluate(String code, {String name = '<plugin>'}) {
    final dead = _dead;
    if (dead != null) return Future.error(MetaverseScriptException(dead));
    final sequence = ++_sequence;
    final completer = Completer<void>();
    _pending[sequence] = completer;
    _commands!.send([sequence, code, name]);
    _watchdog ??= _newWatchdog();
    return completer.future;
  }

  Timer _newWatchdog() => Timer(_timeout + const Duration(seconds: 1), () {
    _fail('脚本执行超时');
  });

  @override
  void dispose() {
    if (_dead != null) return;
    _dead = '脚本引擎已释放';
    onMessage = null;
    onFatal = null;
    _watchdog?.cancel();
    _rejectPending();
    _stopEngine();
  }

  void _stopEngine() {
    _interrupt?.requestInterrupt();
    _commands?.send(null);
    _terminationGuard ??= Timer(const Duration(seconds: 2), () {
      _isolate.kill(priority: Isolate.immediate);
    });
  }

  void _onEvent(Object? event) {
    if (event == null) {
      _terminationGuard?.cancel();
      if (!_terminated.isCompleted) _terminated.complete();
      _events.close();
      if (_dead == null) _fail('脚本引擎意外退出');
      return;
    }
    if (event is! List || event.isEmpty) return;
    if (event[0] == 'ready') {
      _commands = event[1] as SendPort;
      _interrupt = event[2] as JSInterruptHandle;
      if (_dead != null) {
        _stopEngine();
      } else {
        _ready.complete();
      }
      return;
    }
    if (_dead != null) return;
    switch (event[0]) {
      case 'boot-error':
        _fail('脚本引擎启动失败: ${event[1]}');
      case 'fatal':
        _fail(event[1] as String);
      case 'msg':
        try {
          onMessage?.call(event[1]);
        } catch (_) {
          // 单条消息的宿主处理异常由调用方记录，后续消息继续分发。
        }
      case 'done':
        final completer = _pending.remove(event[1]);
        _watchdog?.cancel();
        _watchdog = _pending.isEmpty ? null : _newWatchdog();
        final error = event[2] as String?;
        if (error == null) {
          completer?.complete();
        } else {
          completer?.completeError(MetaverseScriptException(error));
        }
      default:
        _fail('脚本引擎崩溃: ${event[0]}');
    }
  }

  void _fail(String reason) {
    if (_dead != null) return;
    _dead = reason;
    _watchdog?.cancel();
    if (!_ready.isCompleted) _ready.completeError(MetaverseScriptException(reason));
    _rejectPending();
    if (!_terminated.isCompleted) _stopEngine();
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

/// 主机只接收解码后的 JSON，所有网络、定时器及存储继续由插件协议提供。
void _engineMain((SendPort, Duration, int) options) {
  final (host, timeout, memoryLimit) = options;
  JSRuntime? runtime;
  var bridgeCharacters = 0;
  var bridgeLimitReached = false;
  try {
    final engine = runtime = JSRuntime.create(JSRuntimeConfig(
      memoryLimit: memoryLimit,
      maxStackSize: 512 * 1024,
      microtaskQueue: true,
    ));
    final send = JSFunction.createFromHostFunction(engine, (engine, _, args) {
      if (args.length != 2 || !args[0].isString || !args[1].isString ||
          args[0].asDartString != MetaverseScriptEngine.channel) {
        return JSValue.undefined(engine);
      }
      final encoded = args[1].asDartString;
      bridgeCharacters += encoded.length;
      if (encoded.length > 2 * 1024 * 1024 || bridgeCharacters > 16 * 1024 * 1024) {
        bridgeLimitReached = true;
        throw JSNativeException('插件消息超过传输上限');
      }
      host.send(['msg', jsonDecode(encoded)]);
      return JSValue.undefined(engine);
    }, name: 'sendMessage', length: 2);
    engine.global['sendMessage'] = send.asValue;
    send.asValue.release();
  } catch (error) {
    runtime?.release();
    host.send(['boot-error', error.toString()]);
    return;
  }
  final engine = runtime;
  final commands = ReceivePort('metaverse-plugin-engine');
  void close() {
    commands.close();
    engine.release();
  }
  commands.listen((Object? command) {
    if (command == null) {
      close();
      return;
    }
    final [sequence as int, code as String, name as String] = command as List;
    bridgeCharacters = 0;
    bridgeLimitReached = false;
    final watch = Stopwatch()..start();
    String? error;
    engine.updateStackTop();
    engine.setDeadline(timeout);
    try {
      engine.evaluateJavascript(code, sourceUrl: name).release();
      engine.drainMicrotasks();
    } catch (exception) {
      error = exception.toString();
      if (exception is JSException) exception.value.release();
    }
    final String? fatal;
    // 原生计时与 Dart Stopwatch 在不同平台的精度不同，不能靠二次计时猜测中断。
    if (engine.deadlineExceeded || watch.elapsed >= timeout) {
      fatal = '脚本执行超时';
    } else if (bridgeLimitReached) {
      fatal = '插件消息超过传输上限';
    } else if (error?.contains('out of memory') == true) {
      fatal = '脚本内存超过上限';
    } else {
      fatal = null;
    }
    if (fatal != null) {
      host.send(['fatal', fatal]);
      close();
      return;
    }
    engine.clearDeadline();
    host.send(['done', sequence, error]);
  });
  host.send(['ready', commands.sendPort, engine.interruptHandle]);
}
