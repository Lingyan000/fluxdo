import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../../network_logger.dart';
import '../../log/log_policy.dart';
import 'net_core_bindings.dart';
import '../cookie/csrf_session_trace.dart';
import '../flux_request_spec.dart';
import 'network_health_monitor.dart';
import 'core_request_log_context.dart';

/// [Response.extra] 里网络核心附带的连接信息：
/// `reused` / `tlsResumed` / `connectMs` / `ttfbMs`。
const String netCoreConnectionExtraKey = 'netCoreConnection';

/// 把 dio 的请求交给网络核心，响应经事件回调流式回传。
///
/// 相比旧的本地网关少一跳回环 socket，也不再需要系统网络栈：
/// 核心按 WebView 的指纹直接出站。
class NetCoreHttpAdapter implements HttpClientAdapter {
  NetCoreHttpAdapter({
    NetCoreBindings? bindings,
    this.pinnedOnly = false,
    this.pluginRequests = false,
  }) : assert(!pinnedOnly || !pluginRequests),
       _bindings = bindings ?? NetCoreBindings.instance;

  final NetCoreBindings _bindings;
  final bool pinnedOnly;
  final bool pluginRequests;

  /// 在途请求：核心的事件按 id 投递到这里。
  static final Map<int, _PendingRequest> _pending = {};
  static NativeCallable<NetCoreEventCallback>? _callback;

  /// 请求体缓冲满时的退避区间（核心用非阻塞写，满了由这里重试）。
  /// 建连期间缓冲会一直满着，指数退避避免空转。
  static const _writeRetryMin = Duration(milliseconds: 2);
  static const _writeRetryMax = Duration(milliseconds: 50);
  // 核心队列按块计数（8 块），宿主限制块大小，避免单块大数据放大原生缓冲。
  static const _uploadChunkSize = 64 * 1024;

  final Set<int> _ownedRequests = {};
  bool _closed = false;

  /// 每个 isolate 注册一次；原生宿主必须在热重启前解除旧回调。
  static void _ensureCallback(NetCoreBindings bindings) {
    if (_callback != null) return;
    final callback = Zone.root.run(
      () => NativeCallable<NetCoreEventCallback>.listener(_onEvent),
    );
    bindings.setEventCallback(callback.nativeFunction);
    _callback = callback;
  }

  static void _onEvent(int id, int kindCode, Pointer<Uint8> ptr, int length) {
    final pending = _pending[id];
    final kind = NetCoreEventKind.fromCode(kindCode);
    if (pending == null || kind == null) {
      // 请求已被取消：载荷仍要归还，否则泄漏
      if (ptr != nullptr) NetCoreBindings.instance.bufferFree(ptr, length);
      return;
    }
    pending.zone.run(() {
      switch (kind) {
        case NetCoreEventKind.head:
          pending.onHead(_takeString(ptr, length));
        case NetCoreEventKind.data:
          pending.onData(_takeBytes(ptr, length));
        case NetCoreEventKind.done:
          pending.onDone();
        case NetCoreEventKind.error:
          pending.onError(_takeString(ptr, length));
      }
    });
  }

  /// 读走载荷并归还核心分配的缓冲区。
  static String _takeString(Pointer<Uint8> ptr, int length) {
    if (ptr == nullptr || length == 0) return '';
    try {
      return utf8.decode(ptr.cast<Uint8>().asTypedList(length));
    } finally {
      NetCoreBindings.instance.bufferFree(ptr, length);
    }
  }

  /// 读走响应体分块并立即归还缓冲区。
  ///
  /// 这里拷贝一次而不是挂 [NativeFinalizer]：finalizer 只接受单参数函数，
  /// 而归还需要长度；一次内存拷贝相对网络开销可以忽略，换来确定的释放时机。
  static Uint8List _takeBytes(Pointer<Uint8> ptr, int length) {
    if (ptr == nullptr || length == 0) return Uint8List(0);
    try {
      return Uint8List.fromList(ptr.asTypedList(length));
    } finally {
      NetCoreBindings.instance.bufferFree(ptr, length);
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) {
      throw StateError(
        "Can't establish connection after the adapter was closed.",
      );
    }
    if (!_bindings.isAvailable) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: _bindings.lastInitError ?? '网络核心不可用',
      );
    }
    _ensureCallback(_bindings);

    options.extra.putIfAbsent('traceId', LogPolicy.newTraceId);
    options.extra.putIfAbsent('attemptId', LogPolicy.newTraceId);
    final trace = pinnedOnly || pluginRequests
        ? null
        : CsrfSessionTrace.captureDispatch(options);
    if (trace != null) {
      trace['sentBodyBytes'] = 0;
      trace['sentBodyChunks'] = 0;
      trace['sentBodyComplete'] = requestStream == null;
      trace['bodyCountStage'] = 'core-input';
    }
    final meta = jsonEncode({
      'method': options.method.toUpperCase(),
      if (pinnedOnly || pluginRequests)
        'pinned_addresses': options.extra['pinnedAddresses'],
      'url': options.uri.toString(),
      'headers': _headerPairs(options.headers),
      'has_body': requestStream != null,
      'defer_response_body': true,
      // 超时在核心里分段计：建连只算建连，接收只算等响应与块间间隔
      'connect_timeout_ms': ?options.connectTimeout?.inMilliseconds,
      'receive_timeout_ms': ?options.receiveTimeout?.inMilliseconds,
      'send_timeout_ms': ?options.sendTimeout?.inMilliseconds,
    });
    final id = pluginRequests
        ? _bindings.pluginRequestStart(meta)
        : pinnedOnly
        ? _bindings.pinnedRequestStart(meta)
        : _bindings.requestStart(meta);
    options.extra['coreRequestId'] = id;
    if (id == 0) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: '网络核心未就绪',
      );
    }

    CoreRequestLogContext.instance.register(id, {
      ...?PluginExecutionContext.current?.fields,
      'traceId': options.extra['traceId'].toString(),
      'attemptId': options.extra['attemptId'].toString(),
    });

    final pending = _PendingRequest(
      options,
      onPause: () => _bindings.requestPause(id),
      onResume: () => _bindings.requestResume(id),
      // 消费方不要响应体了：连同上游请求一起中止，放掉连接上的流
      onAbandon: () => _bindings.requestCancel(id),
      onFinished: () {
        CoreRequestLogContext.instance.complete(id);
        _pending.remove(id);
        _ownedRequests.remove(id);
      },
    );
    _pending[id] = pending;
    _ownedRequests.add(id);

    // 取消贯通到核心：连接与上游请求一起中止
    cancelFuture?.whenComplete(() {
      final active = _pending[id];
      if (active != null) {
        active.stopUpload();
        _bindings.requestCancel(id);
      }
    });

    if (requestStream != null) {
      unawaited(_pumpRequestBody(id, requestStream, pending, trace));
    }
    return pending.head;
  }

  /// 把 dio 的请求体流泵给核心。核心的写入不阻塞，缓冲满时在这里退避重试。
  Future<void> _pumpRequestBody(
    int id,
    Stream<Uint8List> stream,
    _PendingRequest pending,
    Map<String, dynamic>? trace,
  ) async {
    final options = pending.options;
    final iterator = StreamIterator(stream);
    // cancel 会使尚未完成的 moveNext 返回 false，不用等源流再发出数据。
    unawaited(
      pending.uploadStopped.then((_) async {
        try {
          await iterator.cancel();
        } catch (e) {
          NetworkLogger.log('[Core] 上传数据源取消失败: $e', level: 'warning');
        }
      }),
    );
    try {
      while (await iterator.moveNext()) {
        if (pending.isUploadStopped) return;
        final chunk = iterator.current;
        for (
          var offset = 0;
          offset < chunk.length;
          offset += _uploadChunkSize
        ) {
          final length = (chunk.length - offset).clamp(0, _uploadChunkSize);
          final buffer = calloc<Uint8>(length);
          try {
            buffer.asTypedList(length).setRange(0, length, chunk, offset);
            var delay = _writeRetryMin;
            while (true) {
              if (pending.isUploadStopped) return;
              final result = _bindings.requestWrite(id, buffer, length);
              if (result == 0) {
                if (trace != null) {
                  trace['sentBodyBytes'] =
                      (trace['sentBodyBytes'] as int? ?? 0) + length;
                  trace['sentBodyChunks'] =
                      (trace['sentBodyChunks'] as int? ?? 0) + 1;
                }
                break;
              }
              if (result != NetCoreBindings.writeWouldBlock) return;
              await Future<void>.delayed(delay);
              final next = delay * 2;
              delay = next > _writeRetryMax ? _writeRetryMax : next;
            }
          } finally {
            calloc.free(buffer);
          }
        }
      }
      if (!pending.isUploadStopped) {
        _bindings.requestFinish(id);
        if (trace != null) trace['sentBodyComplete'] = true;
      }
    } catch (e) {
      NetworkLogger.log(
        '[Core] 请求体写入失败 ${options.method} ${options.uri.path}: $e',
        level: 'warning',
      );
      _bindings.requestCancel(id);
    } finally {
      // 提前拒绝时不伪造上传 EOF：Content-Length 未写满会使 HTTP/1 关闭连接，
      // 连带丢失正在读取的错误响应。写入端由核心请求终态统一释放。
      pending.stopUpload();
    }
  }

  static List<List<String>> _headerPairs(Map<String, dynamic> headers) {
    final pairs = <List<String>>[];
    headers.forEach((name, value) {
      if (value == null) return;
      if (value is Iterable) {
        for (final item in value) {
          if (item != null) pairs.add([name, item.toString()]);
        }
      } else {
        pairs.add([name, value.toString()]);
      }
    });
    return pairs;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    if (!force) return;
    for (final id in _ownedRequests.toList()) {
      _pending[id]?.stopUpload();
      _bindings.requestCancel(id);
    }
  }
}

/// 一个在途请求的 Dart 侧状态：把事件序列拼成 dio 的 [ResponseBody]。
class _PendingRequest {
  _PendingRequest(
    this.options, {
    required VoidCallback onPause,
    required VoidCallback onResume,
    required this.onAbandon,
    required this.onFinished,
  }) {
    observation = NetworkHealthMonitor.instance.begin(
      options.uri,
      traceId: options.extra['traceId']?.toString(),
      requestId: options.extra['coreRequestId'] as int?,
    );
    // 订阅、暂停、恢复转给核心；异步回调在途的数据另由 Rust 字节预算约束。
    _body = StreamController<Uint8List>(
      onListen: onResume,
      onPause: onPause,
      onResume: onResume,
      onCancel: abandon,
    );
  }

  final RequestOptions options;
  final Zone zone = Zone.current;
  late final CoreRequestObservation observation;

  /// 终态（完成、出错、被放弃）时调用一次，用于移出在途表。
  final VoidCallback onFinished;
  final VoidCallback onAbandon;
  final Completer<ResponseBody> _head = Completer<ResponseBody>();
  final Completer<void> _uploadStopped = Completer<void>();
  late final StreamController<Uint8List> _body;
  bool _bodyCancelled = false;
  bool _finished = false;
  bool _released = false;

  Future<ResponseBody> get head => _head.future;

  bool get isDone => _finished || _bodyCancelled;
  bool get isUploadStopped => _uploadStopped.isCompleted;
  Future<void> get uploadStopped => _uploadStopped.future;

  void stopUpload() {
    if (!_uploadStopped.isCompleted) _uploadStopped.complete();
  }

  void abandon() {
    if (_bodyCancelled || _finished) return;
    _bodyCancelled = true;
    onAbandon();
    _finish();
    if (!_body.isClosed) unawaited(_body.close());
  }

  /// 只在终态事件里移出在途表，不挂在 StreamController.done 上——
  /// 响应头前就出错时流不会被订阅，done 永远不完成。
  void _finish() {
    if (_released) return;
    _released = true;
    stopUpload();
    onFinished();
  }

  void onHead(String json) {
    if (_head.isCompleted) return;
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    NetworkHealthMonitor.instance.headers(
      observation,
      statusCode: decoded['status'] as int,
      protocol: decoded['http_version'] as String?,
      connectMs: decoded['connect_ms'] as int?,
      ttfbMs: decoded['ttfb_ms'] as int?,
    );
    if ((decoded['status'] as int) >= 400) stopUpload();
    final trace = options.extra[CsrfSessionTrace.extraKey];
    if (trace is Map && decoded['request_trace'] is Map) {
      trace['corePreparedRequest'] = decoded['request_trace'];
    }
    final headers = <String, List<String>>{};
    for (final pair in (decoded['headers'] as List<dynamic>? ?? [])) {
      final entry = (pair as List<dynamic>).cast<String>();
      headers.putIfAbsent(entry[0].toLowerCase(), () => []).add(entry[1]);
    }
    final body = ResponseBody(
      _body.stream,
      decoded['status'] as int,
      headers: headers,
      isRedirect: false,
      statusMessage: null,
      onClose: abandon,
    );
    // 连接信息随 Response.extra 透出，请求日志据此记录协议、是否复用与耗时
    final httpVersion = decoded['http_version'] as String?;
    if (httpVersion != null) {
      body.extra[HttpClientAdapter.extraKeyHttpVersion] = httpVersion;
    }
    body.extra[netCoreConnectionExtraKey] = {
      'connectionId': decoded['connection_id'],
      'reused': decoded['reused'],
      'tlsResumed': decoded['tls_resumed'],
      'echApplied': decoded['ech_applied'],
      'echAccepted': decoded['ech_accepted'],
      'connectMs': decoded['connect_ms'],
      'ttfbMs': decoded['ttfb_ms'],
    };
    _head.complete(body);
  }

  void onData(Uint8List chunk) {
    if (isDone || _body.isClosed) return;
    _body.add(chunk);
  }

  void onDone() {
    if (_finished) return;
    NetworkHealthMonitor.instance.completed(observation);
    _finished = true;
    _finish();
    if (!_body.isClosed) _body.close();
  }

  void onError(String json) {
    if (_finished) return;
    _finished = true;
    _finish();
    final error = _toDioException(json);
    // 用户取消和长轮询的正常等待截止不作为连通性故障。
    if (error.type != DioExceptionType.cancel &&
        !(options.spec.isSilent &&
            error.type == DioExceptionType.receiveTimeout)) {
      NetworkHealthMonitor.instance.failed(observation, kind: error.type.name);
    }
    if (!_head.isCompleted) {
      _head.completeError(error);
      // 头都没拿到，响应体流不会被订阅，直接关掉避免悬挂
      if (!_body.isClosed) _body.close();
      return;
    }
    if (!_body.isClosed) {
      _body
        ..addError(error)
        ..close();
    }
  }

  /// 核心的错误分类 → dio 异常类型，不靠解析错误文本。
  DioException _toDioException(String json) {
    String kind = 'unknown';
    String message = json;
    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      kind = decoded['kind'] as String? ?? kind;
      message = decoded['message'] as String? ?? message;
    } catch (_) {
      // 载荷不是预期 JSON 时按未知错误处理，保留原文便于排查
    }
    return switch (kind) {
      'timeout' => DioException.connectionTimeout(
        timeout: options.connectTimeout ?? Duration.zero,
        requestOptions: options,
        error: message,
      ),
      'send_timeout' => DioException.sendTimeout(
        timeout: options.sendTimeout ?? Duration.zero,
        requestOptions: options,
      ),
      'receive_timeout' => DioException.receiveTimeout(
        timeout: options.receiveTimeout ?? Duration.zero,
        requestOptions: options,
        error: message,
      ),
      'cancelled' => DioException.requestCancelled(
        requestOptions: options,
        reason: message,
      ),
      'certificate' => DioException.badCertificate(
        requestOptions: options,
        error: message,
      ),
      _ => DioException.connectionError(
        requestOptions: options,
        reason: message,
      ),
    };
  }
}
