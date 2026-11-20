import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import 'metaverse_plugin_network.dart';

/// 插件实例共享预算，隐藏的订阅不占连接名额；每次重连重新校验权限和凭证。
class MetaverseStreamBudget {
  static int _global = 0;
  int _active = 0;
  final _starts = <DateTime>[];
  bool acquire() {
    final now = DateTime.now();
    _starts.removeWhere(
      (time) => now.difference(time) >= const Duration(minutes: 1),
    );
    if (_active >= 2 || _global >= 12 || _starts.length >= 30) return false;
    _starts.add(now);
    _active++;
    _global++;
    return true;
  }

  void release() {
    _active--;
    _global--;
  }
}

typedef MetaverseStreamConnector = Future<void> Function(
  CancelToken cancel,
  String lastEventId,
  Future<void> Function() onOpen,
  Future<void> Function(PluginServerEvent) onEvent,
  void Function(int) onRetry,
);

class MetaverseEventStream {
  MetaverseEventStream({
    required this.id,
    required this.credential,
    required this.budget,
    required this.connect,
    required this.emit,
    this.lastEventId = '',
  });
  final String id;
  final String? credential;
  final MetaverseStreamBudget budget;
  final MetaverseStreamConnector connect;
  final Future<void> Function(String name, Map<String, Object?> args) emit;
  String lastEventId;
  bool _wanted = false, _closed = false, _running = false;
  int _generation = 0, _attempt = 0, _serverRetry = 1000;
  CancelToken? _cancel;
  Timer? _timer;
  Completer<void>? _delivery;

  void _cancelDelivery() {
    final pending = _delivery;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const PluginOperationCancelled());
    }
  }

  void setActive(bool active) {
    if (_closed || active == _wanted) return;
    _wanted = active;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _cancel?.cancel();
    _cancelDelivery();
    if (active) _schedule(Duration.zero);
  }

  void close() {
    _closed = true;
    _wanted = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _cancel?.cancel();
    _cancelDelivery();
  }

  void _schedule(Duration delay) {
    if (!_wanted || _closed) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_run());
    });
  }

  Future<void> _emit(String name, Map<String, Object?> args) async {
    final done = Completer<void>();
    _delivery = done;
    // 每次交付单独释放等待者，不能在长寿命取消 Future 上累积回调。
    unawaited(
      Future.sync(() => emit(name, args)).then(
        (_) {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
      ),
    );
    try {
      await done.future;
    } finally {
      if (identical(_delivery, done)) _delivery = null;
    }
  }

  Future<void> _state(
    String state, {
    String? reason,
    int? status,
    int? retryInMs,
  }) => _emit('stream.state', {
    'id': id,
    'state': state,
    'reason': ?reason,
    'status': ?status,
    'retryInMs': ?retryInMs,
  });

  Future<void> _run() async {
    if (_running || !_wanted || _closed) return;
    _running = true;
    final generation = _generation;
    bool current() => !_closed && _wanted && generation == _generation;
    var acquired = false;
    final cancel = CancelToken();
    _cancel = cancel;
    var retry = true;
    var reason = 'stream_disconnected';
    int? status;
    var minimum = 0;
    final connected = Stopwatch();
    try {
      acquired = budget.acquire();
      if (!acquired) {
        minimum = 60000;
        reason = 'stream_connection_limit';
      } else {
        await _state('connecting');
        if (!current()) return;
        await connect(
          cancel,
          lastEventId,
          () async {
            if (!current()) return;
            connected.start();
            await _state('open');
          },
          (event) async {
            if (!current()) return;
            await _emit('stream.event', {
              'id': id,
              'event': event.event,
              'data': event.data,
              'lastEventId': event.lastEventId,
            });
            if (current()) lastEventId = event.lastEventId;
          },
          (ms) {
            _serverRetry = ms.clamp(1000, 60000);
          },
        );
      }
    } on MetaverseStreamException catch (error) {
      reason = error.message;
      status = error.status;
      retry = error.retryable;
      minimum = error.retryAfter?.inMilliseconds ?? 0;
    } on PluginOperationCancelled {
      retry = false;
      reason = 'stream_cancelled';
    } on MetaversePluginCallException catch (error) {
      // 网络异常可以重试，权限、凭证与慢消费者必须停止。
      retry = error.message.startsWith('网络请求失败') || error.message == '读取响应失败';
      reason = retry
          ? 'stream_network_error'
          : error.message == 'stream_consumer_timeout'
          ? error.message
          : 'stream_cancelled';
    } catch (_) {
      reason = 'stream_network_error';
    } finally {
      cancel.cancel();
      if (acquired) budget.release();
      _running = false;
      _cancel = null;
      if (current()) {
        if (connected.elapsed >= const Duration(seconds: 30)) _attempt = 0;
        final delay = max(
          minimum,
          max(
            _serverRetry,
            min(30000, 1000 * pow(2, min(_attempt++, 5)).toInt()),
          ),
        );
        if (!retry) _closed = true;
        try {
          await _state(
            retry ? 'retrying' : 'closed',
            reason: reason,
            status: status,
            retryInMs: retry ? delay : null,
          );
        } catch (_) {
          if (current()) _closed = true;
        }
        if (retry && current()) _schedule(Duration(milliseconds: delay));
      } else if (!_closed && _wanted) {
        _schedule(Duration.zero);
      }
    }
  }
}
