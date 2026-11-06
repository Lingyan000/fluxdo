import 'dart:async';
import 'dart:collection';

/// 单个浏览器资源的公平租约队列。共享任务可并发，切页任务必须独占。
/// 取消只撤销等待者；已开始的任务必须完成清理后释放租约。
class SharedBrowserResource<T> {
  SharedBrowserResource({
    required this.create,
    required this.destroy,
    this.idleTimeout = const Duration(minutes: 1),
  });

  final Future<T> Function() create;
  final Future<void> Function(T) destroy;
  final Duration idleTimeout;
  final _queue = Queue<_Waiter<T>>();
  T? _resource;
  int _active = 0;
  int _generation = 0;
  bool _exclusive = false;
  bool _pumping = false;
  bool _retired = false;
  bool _suspended = false;
  Completer<void>? _drained;
  Timer? _idleTimer;
  Object? _disposalError;

  int get activeCount => _active;
  int get waitingCount => _queue.length;

  Future<void> suspendAndDrain() {
    if (_suspended) return _drained!.future;
    _suspended = true;
    _drained = Completer<void>();
    invalidate();
    return _drained!.future;
  }

  void resume() {
    _suspended = false;
    _pump();
  }

  Future<BrowserResourceLease<T>> acquire({
    bool exclusive = false,
    Future<void>? cancelled,
  }) {
    final disposalError = _disposalError;
    if (disposalError != null) return Future.error(disposalError);
    _idleTimer?.cancel();
    final waiter = _Waiter<T>(exclusive, _generation);
    _queue.add(waiter);
    // 取消信号可能直到退出账号才完成，不能让它一直持有已交付的租约和实例。
    _Waiter<T>? cancellableWaiter = waiter;
    void cancelWaiter() {
      final pending = cancellableWaiter;
      if (pending != null && !pending.result.isCompleted) {
        pending.result.completeError(StateError('浏览器任务已取消'));
        _queue.remove(pending);
        _pump();
      }
    }

    waiter.result.future.then<void>(
      (_) => cancellableWaiter = null,
      onError: (Object _) => cancellableWaiter = null,
    );
    cancelled?.then(
      (_) => cancelWaiter(),
      onError: (Object _) => cancelWaiter(),
    );
    _pump();
    return waiter.result.future;
  }

  /// 会话变更或页面状态不再可信时弃用资源。等待在途清理完成再析构。
  void invalidate() {
    _generation++;
    _retired = true;
    _idleTimer?.cancel();
    for (final waiter in _queue) {
      if (!waiter.result.isCompleted) {
        waiter.result.completeError(StateError('浏览器会话已失效'));
      }
    }
    _queue.clear();
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      if (_active == 0 && _retired) {
        final old = _resource;
        _resource = null;
        if (old != null) {
          try {
            await destroy(old);
          } catch (error) {
            // 无法确认原生实例已销毁时禁止再创建，避免两个实例交叠。
            _disposalError = error;
            rethrow;
          }
        }
        _retired = false;
      }
      while (_queue.isNotEmpty && !_retired && !_exclusive && !_suspended) {
        final waiter = _queue.first;
        if (waiter.exclusive && _active > 0) break;
        if (_resource == null) {
          final generation = _generation;
          try {
            _resource = await create();
          } catch (error, stack) {
            if (_queue.remove(waiter) && !waiter.result.isCompleted) {
              waiter.result.completeError(error, stack);
            }
            continue;
          }
          if (generation != _generation) break;
          if (!_queue.contains(waiter)) continue;
        }
        _queue.removeFirst();
        if (waiter.result.isCompleted) continue;
        _active++;
        _exclusive = waiter.exclusive;
        waiter.result.complete(
          BrowserResourceLease<T>._(
            _resource as T,
            () => waiter.generation == _generation,
            () {
              _active--;
              if (waiter.exclusive) _exclusive = false;
              _pump();
            },
            invalidate,
          ),
        );
      }
    } catch (error, stack) {
      // 析构失败时失败关闭，不把未知状态的原生资源交给新调用方。
      for (final waiter in _queue) {
        if (!waiter.result.isCompleted) {
          waiter.result.completeError(error, stack);
        }
      }
      _queue.clear();
    } finally {
      _pumping = false;
      if (_active == 0) {
        if (_retired && _disposalError == null) {
          _pump();
        } else if (_queue.isEmpty && _resource != null) {
          _idleTimer?.cancel();
          _idleTimer = Timer(idleTimeout, invalidate);
        }
        if (_disposalError != null &&
            _drained != null &&
            !_drained!.isCompleted) {
          _drained!.completeError(_disposalError!);
        }
        if (_resource == null &&
            !_retired &&
            _drained != null &&
            !_drained!.isCompleted) {
          _drained!.complete();
        }
      }
    }
  }
}

class BrowserResourceLease<T> {
  BrowserResourceLease._(
    this.value,
    this._isCurrent,
    this._release,
    this._invalidate,
  );
  final T value;
  final bool Function() _isCurrent;
  final void Function() _release;
  final void Function() _invalidate;
  bool _released = false;

  bool get isCurrent => !_released && _isCurrent();

  void invalidate() {
    if (!_released) _invalidate();
  }

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _Waiter<T> {
  _Waiter(this.exclusive, this.generation);
  final bool exclusive;
  final int generation;
  final result = Completer<BrowserResourceLease<T>>();
}
