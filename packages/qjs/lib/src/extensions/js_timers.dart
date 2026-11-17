import 'dart:async';

import 'package:qjs/qjs.dart';

enum _JSTimerType { timeout, interval }

/// Bridge between JavaScript timer APIs and Dart [Timer].
///
/// Implements `setTimeout`, `setInterval`, `setImmediate`,
/// `clearTimeout`, and `clearInterval`.
class JSTimers {
  /// Injects timer functions into the global scope of [rt].
  JSTimers.install(JSRuntime rt) : _rt = rt {
    _setTimeout = _createTimerJSFn(.timeout);
    _setInterval = _createTimerJSFn(.interval);

    _removeTimer = _createRemoveTimerJSFn();

    rt.global
      ..defineProperty('setImmediate', value: _setTimeout.asValue)
      ..defineProperty('setTimeout', value: _setTimeout.asValue)
      ..defineProperty('setInterval', value: _setInterval.asValue)
      ..defineProperty('clearTimeout', value: _removeTimer.asValue)
      ..defineProperty('clearInterval', value: _removeTimer.asValue);
  }

  final JSRuntime _rt;
  final _timers = <int, _JSTimerState>{};

  late final JSFunction _setTimeout;
  late final JSFunction _setInterval;
  late final JSFunction _removeTimer;

  var _nextTimerId = 1;
  Completer<void>? _resolved;

  /// Whether there are any active timers.
  bool get hasPendingTimers => _timers.isNotEmpty;

  /// Future that completes when all pending timers are finished.
  Future<void> get resolved => (_resolved ??= Completer()).future;

  void _maybeDrain() {
    if (_resolved == null || _timers.isNotEmpty || _resolved!.isCompleted) {
      return;
    }

    _resolved!.complete();
    _resolved = null;
  }

  JSFunction _createTimerJSFn(_JSTimerType type) {
    return JSFunction.createFromHostFunction(
      _rt,
      (rt, _, args) {
        final jsCallback = args.elementAtOrNull(0);
        final jsDuration = args.elementAtOrNull(1);

        if (jsCallback == null ||
            !jsCallback.isObject ||
            jsCallback.asFunctionOrNull == null) {
          throw JSException(
            JSError.typeError(
              rt,
              '${switch (type) {
                .timeout => 'setTimeout',
                .interval => 'setInterval',
              }} expects a function',
            ),
          );
        }

        var duration = Duration.zero;
        if (jsDuration != null && jsDuration.isNumber) {
          duration = Duration(milliseconds: jsDuration.asNumber.toInt());
        }

        final jsCallbackRetained = jsCallback.retain();
        final jsCallbackArgs = args.length > 2
            ? args.skip(2).map((value) => value.retain()).toList()
            : <JSValue>[];

        final timerId = _nextTimerId++;
        late final _JSTimerState timerState;

        void callback() {
          try {
            jsCallbackRetained.asFunctionUnsafe(jsCallbackArgs);
          } on JSException catch (error) {
            // Runs from a Dart timer: there is no caller to throw to.
            _rt.onUncaughtError?.call(error);
          } finally {
            if (type == .timeout) {
              _timers.remove(timerId);
              timerState.release();
            }
            _maybeDrain();
          }
        }

        final timer = switch (type) {
          .timeout => Timer(duration, callback),
          .interval => Timer.periodic(duration, (_) => callback()),
        };

        timerState = _JSTimerState(timer, jsCallbackRetained, jsCallbackArgs);
        _timers[timerId] = timerState;

        return .number(rt, timerId.toDouble());
      },
    );
  }

  JSFunction _createRemoveTimerJSFn() => JSFunction.createFromHostFunction(
    _rt,
    (rt, _, args) {
      final timerId = args.elementAtOrNull(0);

      if (timerId == null || !timerId.isNumber) {
        return .undefined(rt);
      }

      _timers.remove(timerId.asNumber.toInt())?.cancel();
      _maybeDrain();

      return .undefined(rt);
    },
  );

  /// Cancels all pending timers and disposes JS function handles.
  void release() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}

class _JSTimerState {
  _JSTimerState(this.timer, this.jsCallback, this.args);
  final Timer timer;
  final JSValue jsCallback;
  final List<JSValue> args;

  void release() {
    jsCallback.release();
    for (final arg in args) {
      arg.release();
    }
  }

  void cancel() {
    timer.cancel();
    release();
  }
}
