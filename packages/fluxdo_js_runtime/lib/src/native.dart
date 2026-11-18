import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:qjs/qjs.dart';

import '../fluxdo_js_runtime.dart';

typedef _Options = ({
  SendPort host,
  Duration timeout,
  int memory,
  int stack,
  String? channel,
});
typedef _Request = (int, String, String, bool);
typedef _Reply = ({int id, String? result, String? error});

Future<JsWorker> spawn(
  String debugName,
  String? channel,
  Duration timeout,
  int memoryLimit,
  int stackLimit,
) async {
  final events = ReceivePort('$debugName-host');
  final Isolate isolate;
  try {
    isolate = await Isolate.spawn<_Options>(
      _run,
      (
        host: events.sendPort,
        timeout: timeout,
        memory: memoryLimit,
        stack: stackLimit,
        channel: channel,
      ),
      debugName: debugName,
      onError: events.sendPort,
      onExit: events.sendPort,
    );
  } catch (error) {
    events.close();
    throw JsWorkerException('JS 引擎启动失败：$error');
  }
  final worker = _NativeWorker(isolate, events, timeout);
  events.listen(worker._receive);
  try {
    await worker._ready.future.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    worker._stop('JS 引擎启动超时');
    throw const JsWorkerException('JS 引擎启动超时');
  }
  return worker;
}

final class _NativeWorker implements JsWorker {
  _NativeWorker(this._isolate, this._events, this._timeout);

  final Isolate _isolate;
  final ReceivePort _events;
  final Duration _timeout;
  final _ready = Completer<void>();
  final _exit = Completer<void>();
  final _pending = <int, Completer<String?>>{};
  int _sequence = 0;
  SendPort? _commands;
  JSInterruptHandle? _interrupt;
  String? _stopped;
  Timer? _watchdog;
  Timer? _terminationGuard;

  @override
  void Function(Object?)? onMessage;
  @override
  void Function(String)? onFatal;
  @override
  Future<void> get terminated => _exit.future;

  @override
  Future<void> evaluate(String source, {String name = '<script>'}) async {
    await _send(source, name, false);
  }

  @override
  Future<String> evaluateString(
    String source, {
    String name = '<script>',
  }) async => (await _send(source, name, true))!;

  Future<String?> _send(String source, String name, bool returnString) {
    final reason = _stopped;
    if (reason != null) return Future.error(JsWorkerException(reason));
    final id = ++_sequence;
    final completer = _pending[id] = Completer<String?>();
    _commands!.send((id, source, name, returnString));
    _watchdog ??= _newWatchdog();
    return completer.future;
  }

  Timer _newWatchdog() =>
      Timer(_timeout + const Duration(seconds: 1), () => _stop('JS 执行超时'));

  void _receive(Object? event) {
    switch (event) {
      case null:
        _terminationGuard?.cancel();
        _exit.complete();
        _events.close();
        _stop('JS 引擎意外退出');
      case (final SendPort commands, final JSInterruptHandle interrupt):
        _commands = commands;
        _interrupt = interrupt;
        if (_stopped == null) {
          _ready.complete();
        } else {
          _requestExit();
        }
      case _ when _stopped != null:
        return;
      case final _Reply reply:
        final completer = _pending.remove(reply.id)!;
        _watchdog?.cancel();
        _watchdog = _pending.isEmpty ? null : _newWatchdog();
        if (reply.error case final String error) {
          completer.completeError(JsWorkerException(error));
        } else {
          completer.complete(reply.result);
        }
      case (message: final Object? message):
        onMessage?.call(message);
      case final String reason:
        _stop(reason);
      default:
        _stop('JS 工作 isolate 异常退出');
    }
  }

  void _requestExit() {
    _interrupt?.requestInterrupt();
    _commands?.send(null);
    _terminationGuard ??= Timer(
      const Duration(seconds: 2),
      () => _isolate.kill(priority: Isolate.immediate),
    );
  }

  void _stop(String reason) {
    if (_stopped != null) return;
    _stopped = reason;
    _watchdog?.cancel();
    final error = JsWorkerException(reason);
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final request in _pending.values) {
      request.completeError(error);
    }
    _pending.clear();
    if (!_exit.isCompleted) _requestExit();
    final notify = onFatal;
    onMessage = null;
    onFatal = null;
    notify?.call(reason);
  }

  @override
  void dispose() {
    onFatal = null;
    _stop('JS 引擎已释放');
  }
}

void _run(_Options options) {
  final host = options.host;
  JSRuntime? runtime;
  var messageChars = 0;
  var exceeded = false;
  try {
    final engine = runtime = JSRuntime.create(
      JSRuntimeConfig(
        memoryLimit: options.memory,
        maxStackSize: options.stack,
        microtaskQueue: true,
      ),
    );
    if (options.channel case final String channel) {
      final send = JSFunction.createFromHostFunction(
        engine,
        (engine, _, args) {
          if (args.length != 2 ||
              !args[0].isString ||
              !args[1].isString ||
              args[0].asDartString != channel) {
            return JSValue.undefined(engine);
          }
          final json = args[1].asDartString;
          messageChars += json.length;
          if (json.length > 2 * 1024 * 1024 ||
              messageChars > 16 * 1024 * 1024) {
            exceeded = true;
            throw JSNativeException('JS 消息超过传输上限');
          }
          host.send((message: jsonDecode(json)));
          return JSValue.undefined(engine);
        },
        name: 'sendMessage',
        length: 2,
      );
      try {
        engine.global['sendMessage'] = send.asValue;
      } finally {
        send.asValue.release();
      }
    }
  } catch (error) {
    host.send('JS 引擎启动失败：$error');
    runtime?.release();
    return;
  }
  final engine = runtime;
  final commands = ReceivePort();
  void close() {
    commands.close();
    engine.release();
  }

  commands.listen((Object? request) {
    if (request == null) {
      close();
      return;
    }
    final (id, source, name, returnString) = request as _Request;
    messageChars = 0;
    exceeded = false;
    final watch = Stopwatch()..start();
    engine.updateStackTop();
    engine.setDeadline(options.timeout);
    String? result;
    String? error;
    try {
      final value = engine.evaluateJavascript(source, sourceUrl: name);
      try {
        if (returnString) {
          if (!value.isString) throw StateError('JS 返回值不是字符串');
          result = value.asDartString;
        }
      } finally {
        value.release();
      }
      engine.drainMicrotasks();
    } catch (exception) {
      error = exception.toString();
      if (exception is JSException) exception.value.release();
    }
    final fatal = watch.elapsed >= options.timeout
        ? 'JS 执行超时'
        : exceeded
        ? 'JS 消息超过传输上限'
        : (error?.contains('out of memory') ?? false)
        ? 'JS 内存超过上限'
        : null;
    if (fatal != null) {
      host.send(fatal);
      close();
      return;
    }
    engine.clearDeadline();
    host.send((id: id, result: result, error: error));
  });
  host.send((commands.sendPort, engine.interruptHandle));
}
