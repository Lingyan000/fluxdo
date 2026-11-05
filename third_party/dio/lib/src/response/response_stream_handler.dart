import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../adapter.dart';
import '../dio_exception.dart';
import '../options.dart';

/// 为所有适配器保留响应流的按需订阅、背压、取消和接收超时语义。
Stream<Uint8List> handleResponseStream(
  RequestOptions options,
  ResponseBody response, {
  @visibleForTesting void Function()? onReceiveTimeoutWatchCancelled,
}) {
  final source = response.stream;
  StreamSubscription<Uint8List>? subscription;
  late final StreamController<Uint8List> sink;
  final timeout = options.receiveTimeout ?? Duration.zero;
  final elapsed = Stopwatch();
  Timer? timer;
  final cancellation =
      options.cancelToken == null ? null : _ResponseCancellation();
  var finished = false;
  var received = 0;
  final total = options.onReceiveProgress == null ? -1 : response.contentLength;

  void stopTimer() {
    timer?.cancel();
    timer = null;
    elapsed.stop();
    onReceiveTimeoutWatchCancelled?.call();
  }

  void fail(Object error, [StackTrace? stack]) {
    if (finished) return;
    finished = true;
    cancellation?.callback = null;
    stopTimer();
    response.close();
    subscription?.cancel();
    sink.addError(error, stack);
    sink.close();
  }

  void watch() {
    if (finished || sink.isPaused || timeout <= Duration.zero) return;
    timer?.cancel();
    final remaining = timeout - elapsed.elapsed;
    elapsed.start();
    timer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      fail(DioException.receiveTimeout(
          timeout: timeout, requestOptions: options));
    });
  }

  sink = StreamController<Uint8List>(
    onListen: () {
      // 取消可能早于消费方订阅；此时只投递已排队的取消错误。
      if (finished) return;
      watch();
      subscription = source.listen(
        (data) {
          if (finished) return;
          elapsed
            ..stop()
            ..reset();
          watch();
          try {
            options.onReceiveProgress?.call(received += data.length, total);
            sink.add(data);
          } catch (error, stack) {
            fail(error, stack);
          }
        },
        onError: (Object error, StackTrace stack) => fail(error, stack),
        onDone: () {
          if (finished) return;
          finished = true;
          cancellation?.callback = null;
          stopTimer();
          sink.close();
        },
        cancelOnError: true,
      );
    },
    onPause: () {
      stopTimer();
      subscription?.pause();
    },
    onResume: () {
      watch();
      subscription?.resume();
    },
    onCancel: () {
      // 正常 EOF 或 fail 已结束源；不能在 onDone 内再次等待源取消。
      if (finished) return null;
      finished = true;
      cancellation?.callback = null;
      stopTimer();
      response.close();
      return subscription?.cancel();
    },
  );

  if (cancellation != null) {
    cancellation.callback = fail;
    options.cancelToken!.whenCancel.then(cancellation.cancel);
  }
  return sink.stream;
}

// 独立对象避免长寿命共享 CancelToken 留住已完成响应的流、闭包和缓冲。
class _ResponseCancellation {
  void Function(DioException)? callback;
  void cancel(DioException error) => callback?.call(error);
}
