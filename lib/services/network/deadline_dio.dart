import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'flux_request_spec.dart';

/// 与 OkHttp callTimeout 一样，以逻辑调用而非单次传输为边界。
/// 放在 fetch 外层，才能涵盖拦截器排队、重定向和恢复层的递归 fetch。
class DeadlineDio extends DioForNative {
  DeadlineDio([super.options, this.defaultCallTimeout]);

  final Duration? defaultCallTimeout;

  static const _contextKey = '_logicalCallDeadline';
  static const _timingKey = '_logicalCallTiming';

  static int? elapsedMilliseconds(RequestOptions options) =>
      (options.extra[_timingKey] as _CallTiming?)?.watch.elapsedMilliseconds;

  static Duration? exceededDeadline(RequestOptions options) {
    final context = options.extra[_contextKey];
    return context is _CallDeadline && context.expired ? context.limit : null;
  }

  @override
  Future<Response<T>> fetch<T>(RequestOptions requestOptions) async {
    final previous = requestOptions.extra[_timingKey] as _CallTiming?;
    final ownsTiming = previous == null || previous.finished;
    final timing = ownsTiming ? _CallTiming() : previous;
    requestOptions.extra[_timingKey] = timing;
    try {
      final inherited = requestOptions.extra[_contextKey];
      if (inherited is _CallDeadline && !inherited.finished) {
        inherited.throwIfCancelled(requestOptions);
        return await super.fetch<T>(requestOptions);
      }
      final override = requestOptions.spec.callTimeout;
      final ordinaryRead = const {
        'GET',
        'HEAD',
        'OPTIONS',
      }.contains(requestOptions.method.toUpperCase());
      final limit =
          override ??
          (ordinaryRead &&
                  requestOptions.responseType != ResponseType.stream &&
                  !requestOptions.spec.recoveryDisabled
              ? defaultCallTimeout
              : null);
      if (limit == null || limit <= Duration.zero) {
        return await super.fetch<T>(requestOptions);
      }
      return await withDeadline(
        requestOptions,
        limit,
        (options) => super.fetch<T>(options),
      );
    } finally {
      if (ownsTiming) {
        timing.finished = true;
        timing.watch.stop();
      }
    }
  }

  /// 下载队列也可置于同一调用边界内；内部 fetch 继承上下文，不另起预算。
  static Future<T> withDeadline<T>(
    RequestOptions requestOptions,
    Duration limit,
    Future<T> Function(RequestOptions options) run,
  ) async {
    final inherited = requestOptions.extra[_contextKey];
    if (inherited is _CallDeadline && !inherited.finished) {
      inherited.throwIfCancelled(requestOptions);
      return run(requestOptions);
    }
    if (limit <= Duration.zero) return run(requestOptions);
    final context = _CallDeadline(limit, requestOptions.cancelToken);
    final options = requestOptions.copyWith(
      cancelToken: context.token,
      extra: {...requestOptions.extra, _contextKey: context},
    );
    context.token.requestOptions = options;
    var streamOwnsDeadline = false;
    try {
      context.throwIfCancelled(options);
      final result = await Future.any<T>([
        run(options),
        context.token.whenCancel.then((error) => throw error),
      ]);
      context.throwIfCancelled(options);
      final body = result is Response ? result.data : null;
      if (body is ResponseBody) {
        // 流式请求的显式预算延续到 EOF/取消，而不是收到响应头就结束。
        body.stream = _withDeadline(body.stream, context, options);
        streamOwnsDeadline = true;
      }
      return result;
    } catch (_) {
      if (context.expired) throw context.timeoutError(options);
      rethrow;
    } finally {
      if (!streamOwnsDeadline) context.finish();
    }
  }

  static Stream<Uint8List> _withDeadline(
    Stream<Uint8List> stream,
    _CallDeadline context,
    RequestOptions options,
  ) async* {
    var complete = false;
    try {
      context.throwIfCancelled(options);
      yield* stream;
      context.throwIfCancelled(options);
      complete = true;
    } on DioException {
      if (context.expired) throw context.timeoutError(options);
      rethrow;
    } finally {
      // Dio 的包装流取消不一定传递到适配器；提前放弃响应体时显式
      // 取消子 token，关闭底层读取，但不影响调用方共享的父 token。
      if (!complete && !context.token.isCancelled) {
        context.token.cancel('Response body abandoned');
      }
      context.finish();
    }
  }

  @override
  Dio clone({
    BaseOptions? options,
    Interceptors? interceptors,
    HttpClientAdapter? httpClientAdapter,
    Transformer? transformer,
  }) {
    final dio = DeadlineDio(options ?? this.options, defaultCallTimeout);
    dio.interceptors.removeImplyContentTypeInterceptor();
    dio.interceptors.addAll(interceptors ?? this.interceptors);
    dio.httpClientAdapter = httpClientAdapter ?? this.httpClientAdapter;
    dio.transformer = transformer ?? this.transformer;
    return dio;
  }
}

/// 总时限不同于 connect/receiveTimeout，不应再次进入瞬态重试。
class CallDeadlineExceeded implements Exception {
  const CallDeadlineExceeded(this.limit);
  final Duration limit;

  @override
  String toString() => 'Call deadline exceeded (${limit.inMilliseconds}ms)';
}

class _CallDeadline {
  _CallDeadline(this.limit, CancelToken? parent) {
    if (parent?.isCancelled == true) {
      token.cancel(parent!.cancelError?.error);
    } else if (parent != null) {
      // 调用方可以长期共享 token，不能让其未完成 Future 强引用所有历史调用。
      final weak = WeakReference(this);
      parent.whenCancel.then((error) {
        final current = weak.target;
        if (current != null &&
            !current.finished &&
            !current.token.isCancelled) {
          current.token.cancel(error.error);
        }
      });
    }
    _timer = Timer(limit, () {
      expired = true;
      if (!token.isCancelled) token.cancel(CallDeadlineExceeded(limit));
    });
  }

  final Duration limit;
  final CancelToken token = CancelToken();
  late final Timer _timer;
  bool expired = false;
  bool finished = false;

  void throwIfCancelled(RequestOptions options) {
    if (expired) throw timeoutError(options);
    if (token.isCancelled) throw token.cancelError!;
  }

  DioException timeoutError(RequestOptions options) => DioException(
    requestOptions: options,
    error: CallDeadlineExceeded(limit),
    message: '逻辑请求总时限已耗尽',
  );

  void finish() {
    finished = true;
    _timer.cancel();
  }
}

class _CallTiming {
  final Stopwatch watch = Stopwatch()..start();
  bool finished = false;
}
