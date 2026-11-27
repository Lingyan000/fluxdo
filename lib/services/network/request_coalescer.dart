import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth_session.dart';
import 'flux_request_spec.dart';

enum _CoalescingTier { full, silent, noRecovery }

class _CoalescedFlight {
  _CoalescedFlight({
    required this.slotKey,
    required this.cancelToken,
    required this.future,
  });

  final String slotKey;
  final CancelToken cancelToken;
  final Future<Response<dynamic>> future;
  int activeWaiters = 0;
  bool completed = false;
}

/// 在途 GET 请求单飞合并器（Request Coalescing，显式 Opt-In + 写屏障）。
///
/// 挂在 [DeadlineDio.fetch] 外层：
/// - 默认关闭，仅当请求显式标注 [FluxRequestKeys.allowCoalescing] 为 `true` 时生效，
///   避免 MessageBus 实时刷新、手动下拉刷新等强实时接口搭车旧快照；
/// - 写屏障：同一 Dio 发起或完成任意非只读请求（POST/PUT/PATCH/DELETE 等）时，
///   立即把当前在途 GET 从合并表摘除（不取消原请求），确保写后读绝不复用写前快照；
/// - 仅合并**同时在途**的请求，请求结束立即移除，不做结果缓存；
/// - 共享请求使用独立的 [CancelToken]：仅当所有等待者（含发起者）都取消时才中止底层传输，
///   单个页面关闭不会误杀其他仍在等待同一响应的调用方；
/// - 领导者内部由恢复层/重定向/CF 拦截器发起的递归 `dio.fetch` 携带内部标记，直接绕过合并，
///   避免自死锁；
/// - 跟随者拿到独立克隆的 [Response] 与 JSON 数据结构，避免多方共享可变 Map/List 互相污染。
class RequestCoalescer {
  RequestCoalescer({int Function()? sessionGenerationProvider})
    : _sessionGenerationProvider =
          sessionGenerationProvider ?? (() => AuthSession().generation);

  /// 标记领导者及其递归子请求（重定向/重试/CF 复放），防止递归 fetch 命中自身在途条目死锁。
  static const String _leaderMarkerKey = '_coalescingLeader';

  /// 标记跟随者收到的响应来自在途合并，便于诊断与测试断言。
  static const String coalescedResponseExtraKey = 'coalesced';

  static const Set<String> _readOnlyMethods = {'GET', 'HEAD', 'OPTIONS'};

  final int Function() _sessionGenerationProvider;
  final Map<String, _CoalescedFlight> _inFlight = {};

  @visibleForTesting
  int get activeFlightCount => _inFlight.length;

  /// 将当前全部在途 GET 从合并表摘除（不取消已有请求），
  /// 保证后续新来的 GET 不会搭车到可能已过期的旧快照。
  void invalidateInFlight() {
    _inFlight.clear();
  }

  /// 判断请求是否满足在途合并条件。
  bool isEligible(
    RequestOptions options, {
    ValidateStatus? defaultValidateStatus,
  }) {
    if (options.method.toUpperCase() != 'GET') return false;
    final spec = options.spec;
    if (!spec.allowCoalescing) return false;
    if (options.data != null) return false;
    if (options.responseType == ResponseType.stream) return false;
    if (options.onReceiveProgress != null) return false;
    if (options.cancelToken?.isCancelled == true) return false;

    if (spec.skipRedirect ||
        spec.skipSessionStateSync ||
        spec.allowRedirectSetCookie ||
        spec.skipCfChallenge ||
        spec.skipCfBlock ||
        spec.callTimeout != null) {
      return false;
    }

    if (options.extra[_leaderMarkerKey] == true ||
        options.extra['_recoveryManaged'] == true ||
        options.extra['_redirectCount'] != null) {
      return false;
    }

    if (defaultValidateStatus != null &&
        options.validateStatus != defaultValidateStatus) {
      return false;
    }

    return true;
  }

  /// 执行或合并一次请求。
  Future<Response<T>> run<T>(
    RequestOptions requestOptions, {
    required Future<Response<dynamic>> Function(RequestOptions leaderOptions)
    execute,
    ValidateStatus? defaultValidateStatus,
  }) async {
    // 复刻 DioMixin.fetch<T> 的 responseType 归一化，确保 String 与 JSON
    // 产生不同的合并键，且底层以 dynamic 执行时仍按预期解码。
    normalizeResponseType<T>(requestOptions);

    // 写屏障：非只读请求发出前与完成后都摘除当前在途 GET，防止写后读复用写前旧快照。
    final method = requestOptions.method.toUpperCase();
    if (!_readOnlyMethods.contains(method)) {
      invalidateInFlight();
      try {
        final response = await execute(requestOptions);
        return _ensureTypedResponse<T>(response, response.requestOptions);
      } finally {
        invalidateInFlight();
      }
    }

    if (!isEligible(
      requestOptions,
      defaultValidateStatus: defaultValidateStatus,
    )) {
      final response = await execute(requestOptions);
      return _ensureTypedResponse<T>(response, response.requestOptions);
    }

    final baseKey = _buildBaseKey(requestOptions);
    final tier = _tierOf(requestOptions);
    final existing = _findMatchingFlight(baseKey, tier);
    if (existing != null) {
      debugPrint(
        '[Coalescer] 合并在途请求: GET ${requestOptions.uri} (tier=${tier.name})',
      );
      return _awaitFlight<T>(existing, requestOptions, isLeader: false);
    }

    final slotKey = _slotKey(baseKey, tier);
    final flightCancelToken = CancelToken();
    final leaderOptions = requestOptions.copyWith(
      cancelToken: flightCancelToken,
      extra: {...requestOptions.extra, _leaderMarkerKey: true},
    );
    flightCancelToken.requestOptions = leaderOptions;

    late final _CoalescedFlight flight;
    final future = execute(leaderOptions).whenComplete(() {
      flight.completed = true;
      _removeFlight(slotKey, flight);
    });
    // 若全部等待者提前取消，吞掉底层最终抛出的取消/错误，避免未捕获异常。
    unawaited(future.then<void>((_) {}, onError: (_, _) {}));

    flight = _CoalescedFlight(
      slotKey: slotKey,
      cancelToken: flightCancelToken,
      future: future,
    );
    _inFlight[slotKey] = flight;

    return _awaitFlight<T>(flight, requestOptions, isLeader: true);
  }

  /// 与 Dio 5.11 `DioMixin.fetch<T>` 保持一致的 responseType 推断规则。
  static void normalizeResponseType<T>(RequestOptions requestOptions) {
    if (T != dynamic &&
        !(requestOptions.responseType == ResponseType.bytes ||
            requestOptions.responseType == ResponseType.stream)) {
      if (T == String) {
        requestOptions.responseType = ResponseType.plain;
      } else {
        requestOptions.responseType = ResponseType.json;
      }
    }
  }

  Future<Response<T>> _awaitFlight<T>(
    _CoalescedFlight flight,
    RequestOptions callerOptions, {
    required bool isLeader,
  }) async {
    flight.activeWaiters++;
    final callerToken = callerOptions.cancelToken;
    try {
      final Response<dynamic> result;
      if (callerToken == null) {
        result = await flight.future;
      } else {
        callerToken.requestOptions ??= callerOptions;
        if (callerToken.isCancelled) {
          throw callerToken.cancelError!;
        }
        result = await Future.any<Response<dynamic>>([
          flight.future,
          callerToken.whenCancel.then<Response<dynamic>>((err) => throw err),
        ]);
      }

      if (isLeader) {
        return _ensureTypedResponse<T>(result, result.requestOptions);
      }
      return _cloneResponse<T>(result, callerOptions, markCoalesced: true);
    } on DioException catch (err) {
      if (callerToken?.isCancelled == true &&
          identical(err, callerToken!.cancelError)) {
        rethrow;
      }
      if (isLeader) {
        rethrow;
      }
      throw err.copyWith(
        requestOptions: callerOptions,
        response: err.response != null
            ? _cloneResponse<dynamic>(
                err.response!,
                callerOptions,
                markCoalesced: true,
              )
            : null,
      );
    } finally {
      flight.activeWaiters--;
      if (flight.activeWaiters == 0 && !flight.completed) {
        _removeFlight(flight.slotKey, flight);
        if (!flight.cancelToken.isCancelled) {
          flight.cancelToken.cancel('All coalesced callers cancelled');
        }
      }
    }
  }

  _CoalescingTier _tierOf(RequestOptions options) {
    if (options.extra[FluxRequestKeys.noRecovery] == true) {
      return _CoalescingTier.noRecovery;
    }
    if (options.spec.isSilent) {
      return _CoalescingTier.silent;
    }
    return _CoalescingTier.full;
  }

  _CoalescedFlight? _findMatchingFlight(String baseKey, _CoalescingTier tier) {
    switch (tier) {
      case _CoalescingTier.full:
        // 前台请求不降级搭车静默/无恢复通道，保证完整重试与交互过盾能力。
        return _activeFlight(_slotKey(baseKey, _CoalescingTier.full));
      case _CoalescingTier.silent:
        // 静默请求优先搭车已在途的前台请求，其次合并同类静默请求。
        return _activeFlight(_slotKey(baseKey, _CoalescingTier.full)) ??
            _activeFlight(_slotKey(baseKey, _CoalescingTier.silent));
      case _CoalescingTier.noRecovery:
        return _activeFlight(_slotKey(baseKey, _CoalescingTier.noRecovery));
    }
  }

  _CoalescedFlight? _activeFlight(String slotKey) {
    final flight = _inFlight[slotKey];
    if (flight == null || flight.completed || flight.cancelToken.isCancelled) {
      return null;
    }
    return flight;
  }

  void _removeFlight(String slotKey, _CoalescedFlight flight) {
    if (identical(_inFlight[slotKey], flight)) {
      _inFlight.remove(slotKey);
    }
  }

  String _slotKey(String baseKey, _CoalescingTier tier) =>
      '${tier.name}|$baseKey';

  String _buildBaseKey(RequestOptions options) {
    final gen = _sessionGenerationProvider();
    final canonicalUri = _canonicalizeUri(options.uri);
    final canonicalHeaders = _canonicalizeHeaders(options.headers);
    return '$gen|${options.responseType.name}|$canonicalUri|$canonicalHeaders';
  }

  static String _canonicalizeUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final hasNonDefaultPort =
        uri.hasPort &&
        !((scheme == 'https' && uri.port == 443) ||
            (scheme == 'http' && uri.port == 80));
    final portPart = hasNonDefaultPort ? ':${uri.port}' : '';
    final path = uri.path;

    if (!uri.hasQuery) {
      return '$scheme://$host$portPart$path';
    }

    final pairs = <MapEntry<String, String>>[];
    uri.queryParametersAll.forEach((key, values) {
      if (values.isEmpty) {
        pairs.add(MapEntry(key, ''));
      } else {
        for (final value in values) {
          pairs.add(MapEntry(key, value));
        }
      }
    });
    pairs.sort((a, b) {
      final keyCmp = a.key.compareTo(b.key);
      if (keyCmp != 0) return keyCmp;
      return a.value.compareTo(b.value);
    });

    final encodedQuery = pairs
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return '$scheme://$host$portPart$path?$encodedQuery';
  }

  static String _canonicalizeHeaders(Map<String, dynamic> headers) {
    if (headers.isEmpty) return '';
    final normalized = <String, String>{};
    headers.forEach((key, value) {
      if (value == null) return;
      final lowerKey = key.toLowerCase();
      if (value is Iterable) {
        normalized[lowerKey] = value.map((e) => e.toString()).join(',');
      } else {
        normalized[lowerKey] = value.toString();
      }
    });
    final keys = normalized.keys.toList()..sort();
    return keys.map((k) => '$k=${normalized[k]}').join('\n');
  }

  static Response<T> _ensureTypedResponse<T>(
    Response<dynamic> response,
    RequestOptions requestOptions,
  ) {
    if (response is Response<T> &&
        identical(response.requestOptions, requestOptions)) {
      return response;
    }
    return Response<T>(
      data: response.data as T?,
      headers: response.headers,
      requestOptions: requestOptions,
      isRedirect: response.isRedirect,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      redirects: response.redirects,
      extra: response.extra,
    );
  }

  static Response<T> _cloneResponse<T>(
    Response<dynamic> source,
    RequestOptions requestOptions, {
    bool markCoalesced = false,
  }) {
    final clonedHeaders = Headers.fromMap(
      source.headers.map.map((k, v) => MapEntry(k, List<String>.from(v))),
    );
    final clonedExtra = Map<String, dynamic>.from(source.extra);
    if (markCoalesced) {
      clonedExtra[coalescedResponseExtraKey] = true;
    }
    return Response<T>(
      data: _cloneResponseData(source.data) as T?,
      headers: clonedHeaders,
      requestOptions: requestOptions,
      isRedirect: source.isRedirect,
      statusCode: source.statusCode,
      statusMessage: source.statusMessage,
      redirects: List<RedirectRecord>.from(source.redirects),
      extra: clonedExtra,
    );
  }

  /// 对常见可变响应体做浅隔离深拷贝，防止领导者与跟随者互相修改同一对象。
  static dynamic _cloneResponseData(dynamic data) {
    if (data == null || data is String || data is num || data is bool) {
      return data;
    }
    if (data is Uint8List) {
      return Uint8List.fromList(data);
    }
    if (data is List<int>) {
      return List<int>.from(data);
    }
    if (data is Map<String, dynamic>) {
      return <String, dynamic>{
        for (final entry in data.entries)
          entry.key: _cloneResponseData(entry.value),
      };
    }
    if (data is Map) {
      return <dynamic, dynamic>{
        for (final entry in data.entries)
          entry.key: _cloneResponseData(entry.value),
      };
    }
    if (data is List) {
      return <dynamic>[for (final item in data) _cloneResponseData(item)];
    }
    return data;
  }
}
