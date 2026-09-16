import 'dart:async';

/// 为一次桥操作共享截止时间；迟到的原生结果不会继续推进已终止操作。
class WebViewOperationGuard {
  WebViewOperationGuard({
    required Duration timeout,
    required Object timeoutError,
    Future<void>? cancel,
    required Object cancelError,
  }) {
    _timer = Timer(timeout, () => stop(timeoutError));
    cancel?.then(
      (_) => stop(cancelError),
      onError: (Object _) => stop(cancelError),
    );
  }

  final _stopped = Completer<Object>();
  late final Timer _timer;
  Object? _error;
  bool _disposed = false;

  bool get isStopped => _error != null;

  void stop(Object error) {
    if (_disposed || _error != null) return;
    _error = error;
    _stopped.complete(error);
  }

  Future<T> run<T>(Future<T> Function() action) async {
    if (_error != null) throw _error!;
    final value = await Future.any<T>([
      Future<T>.sync(action),
      _stopped.future.then<T>((error) => throw error),
    ]);
    if (_error != null) throw _error!;
    return value;
  }

  void dispose() {
    _disposed = true;
    _timer.cancel();
  }
}
