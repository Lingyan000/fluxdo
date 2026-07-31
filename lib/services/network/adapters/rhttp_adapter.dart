import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

import '../doh/network_settings_service.dart';
import '../proxy/proxy_settings_service.dart';
import '../rhttp/rhttp_settings_service.dart';
import '../system_proxy_service.dart';

/// 基于 rhttp (Rust reqwest) 的 Dio 适配器
///
/// 支持 HTTP/2 多路复用、DOH DNS 解析（请求前静态注入）、
/// 原生 HTTP/SOCKS5 代理、以及通过本地 Rust 代理中转 SS 连接。
class RhttpAdapter implements HttpClientAdapter {
  RhttpAdapter(this._networkSettings, this._proxySettings);

  final NetworkSettingsService _networkSettings;
  final ProxySettingsService _proxySettings;

  final Map<String, _RhttpDelegate> _delegates = {};
  final Map<String, Future<_RhttpDelegate>> _delegateBuilds = {};
  final Map<String, String> _delegateBuildFingerprints = {};
  final Map<String, String> _clientFingerprints = {};
  final Map<String, int> _hostBuildTokens = {};
  final Map<String, rhttp.RhttpClient> _clients = {};
  int _buildEpoch = 0;
  int _settingsVersion = -1;
  int _proxyVersion = -1;
  int _rhttpVersion = -1;
  int _systemProxyVersion = -1;
  bool _closed = false;

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
    final host = options.uri.host;
    final config = await _prepareClientConfig(host);
    final delegate = await _ensureDelegate(config);
    try {
      final response = await delegate.fetch(
        options,
        requestStream,
        cancelFuture,
      );
      _markConfigSuccess(config, response.remoteIp);
      return response.responseBody;
    } catch (error) {
      if (!_canRetryWithAlternateIp(options, requestStream, config, error)) {
        rethrow;
      }

      final attemptedIp = config.dnsOverrides.isNotEmpty
          ? config.dnsOverrides.first
          : null;
      _networkSettings.reportHostConnectionFailure(config.host, attemptedIp);
      final retryConfig = await _prepareClientConfig(host);
      if (retryConfig.clientFingerprint == config.clientFingerprint) {
        rethrow;
      }

      debugPrint(
        '[DIO] RhttpAdapter 切换 IP 重试 ${config.host} '
        '(${attemptedIp ?? "system"} -> '
        '${retryConfig.dnsOverrides.isEmpty ? "system" : retryConfig.dnsOverrides.join(", ")})',
      );
      final retryDelegate = await _ensureDelegate(retryConfig);
      final response = await retryDelegate.fetch(
        options,
        requestStream,
        cancelFuture,
      );
      _markConfigSuccess(retryConfig, response.remoteIp);
      return response.responseBody;
    }
  }

  Future<_RhttpDelegate> _ensureDelegate(_PreparedClientConfig config) {
    final settingsVersion = _networkSettings.version;
    final proxyVersion = _proxySettings.version;
    final rhttpVersion = RhttpSettingsService.instance.version;
    final systemProxyVersion = SystemProxyService.instance.version.value;

    final configChanged =
        _settingsVersion != settingsVersion ||
        _proxyVersion != proxyVersion ||
        _rhttpVersion != rhttpVersion ||
        _systemProxyVersion != systemProxyVersion;
    if (configChanged) {
      _disposeAllClients();
      _settingsVersion = settingsVersion;
      _proxyVersion = proxyVersion;
      _rhttpVersion = rhttpVersion;
      _systemProxyVersion = systemProxyVersion;
    }

    final hostKey = config.hostKey;
    final fingerprint = config.clientFingerprint;
    final delegate = _delegates[hostKey];
    if (delegate != null && _clientFingerprints[hostKey] == fingerprint) {
      return Future.value(delegate);
    }

    final building = _delegateBuilds[hostKey];
    if (building != null &&
        _delegateBuildFingerprints[hostKey] == fingerprint) {
      return building;
    }

    final hostBuildToken = (_hostBuildTokens[hostKey] ?? 0) + 1;
    _hostBuildTokens[hostKey] = hostBuildToken;

    final future = _rebuildDelegate(config, _buildEpoch, hostBuildToken);
    _delegateBuilds[hostKey] = future;
    _delegateBuildFingerprints[hostKey] = fingerprint;
    return future.whenComplete(() {
      if (identical(_delegateBuilds[hostKey], future)) {
        _delegateBuilds.remove(hostKey);
        _delegateBuildFingerprints.remove(hostKey);
      }
    });
  }

  Future<_RhttpDelegate> _rebuildDelegate(
    _PreparedClientConfig config,
    int buildEpoch,
    int hostBuildToken,
  ) async {
    final client = await _createClient(config);
    final hostKey = config.hostKey;
    final stillCurrent =
        !_closed &&
        buildEpoch == _buildEpoch &&
        _hostBuildTokens[hostKey] == hostBuildToken;
    if (!stillCurrent) {
      client.dispose(cancelRunningRequests: true);
      final existing = _delegates[hostKey];
      if (existing != null) {
        return existing;
      }
      return _ensureDelegate(config);
    }

    final delegate = _RhttpDelegate(client);

    _clients.remove(hostKey)?.dispose(cancelRunningRequests: true);
    _clients[hostKey] = client;
    _delegates[hostKey] = delegate;
    _clientFingerprints[hostKey] = config.clientFingerprint;
    debugPrint(
      '[DIO] RhttpAdapter 重建完成 ${config.host} '
      '(DNS: ${config.dnsOverrides.isEmpty ? "system" : config.dnsOverrides.join(", ")}'
      '${config.stickyIp != null ? " [sticky]" : ""}, '
      'ECH: ${config.echConfig == null ? "off" : "on"})',
    );
    return delegate;
  }

  Future<_PreparedClientConfig> _prepareClientConfig(String host) async {
    final normalizedHost = host.trim().toLowerCase();
    final ns = _networkSettings.current;
    final resolvedHost = await _networkSettings.resolveHostForRequest(
      normalizedHost,
    );

    return _PreparedClientConfig(
      host: normalizedHost,
      hostKey: normalizedHost.isEmpty ? '__default__' : normalizedHost,
      dnsOverrides: resolvedHost.dnsOverrides,
      stickyIp: resolvedHost.preferredIp,
      echConfig: resolvedHost.echConfig,
      dohEnabled: ns.dohEnabled,
    );
  }

  bool _canRetryWithAlternateIp(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    _PreparedClientConfig config,
    Object error,
  ) {
    if (requestStream != null) {
      return false;
    }

    final method = options.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') {
      return false;
    }

    if (config.host.isEmpty || config.dnsOverrides.isEmpty) {
      return false;
    }

    return _isRetryableConnectionFailure(error);
  }

  bool _isRetryableConnectionFailure(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return true;
        case DioExceptionType.badCertificate:
        case DioExceptionType.badResponse:
        case DioExceptionType.cancel:
          return false;
        case DioExceptionType.unknown:
          final inner = error.error;
          if (inner != null && !identical(inner, error)) {
            return _isRetryableConnectionFailure(inner);
          }
          break;
        default:
          // 其余枚举值(如 5.11 新增 transformTimeout)不视为可重试的连接失败
          break;
      }
    }

    if (error is SocketException) {
      return true;
    }

    final text = error.toString().toLowerCase();
    return text.contains('rhttpconnectionexception') ||
        text.contains('rhttptimeoutexception') ||
        text.contains('connection reset by peer') ||
        text.contains('connection error') ||
        text.contains('timed out') ||
        text.contains('timeout') ||
        text.contains('broken pipe') ||
        text.contains('connection aborted') ||
        text.contains('connection refused') ||
        text.contains('network is unreachable') ||
        text.contains('no route to host') ||
        text.contains('eof');
  }

  void _markConfigSuccess(_PreparedClientConfig config, String? remoteIp) {
    if (config.host.isEmpty) {
      return;
    }
    final successIp =
        _normalizeIp(remoteIp) ??
        (config.dnsOverrides.length == 1
            ? _normalizeIp(config.dnsOverrides.first)
            : null);
    if (successIp == null) {
      return;
    }
    _networkSettings.reportHostConnectionSuccess(config.host, successIp);
  }

  Future<rhttp.RhttpClient> _createClient(_PreparedClientConfig config) async {
    final ns = _networkSettings.current;
    final ps = _proxySettings.current;

    return rhttp.RhttpClient.create(
      settings: rhttp.ClientSettings(
        // 用 ALPN 协商 HTTP/2，避免 https 场景误用 prior knowledge 造成超时。
        httpVersionPref: rhttp.HttpVersionPref.all,

        // Dio 自己根据状态码处理，不让 rhttp 提前抛状态码异常。
        throwOnStatusCode: false,

        // DNS：请求前在 Dart 层完成解析，避免连接阶段再从 Rust 回调 Dart。
        dnsSettings: config.toDnsSettings(),

        // TLS：始终传入 TlsSettings 以确保 cipher suite 重排生效（对齐 Chrome 指纹）
        // ECH 配置可用时额外启用 ECH
        tlsSettings: rhttp.TlsSettings(echConfigList: config.echConfig),

        // 代理配置
        proxySettings: _buildProxySettings(ns, ps),

        // Cookie/重定向交给 Dio 拦截器
        cookieSettings: const rhttp.CookieSettings(storeCookies: false),
        redirectSettings: const rhttp.RedirectSettings.none(),

        timeoutSettings: const rhttp.TimeoutSettings(
          connectTimeout: Duration(seconds: 30),
          // client 级 timeout 仅作进程兜底,真正的 per-request 超时由 Dio 的
          // RequestOptions.receiveTimeout / connectTimeout 在上层控制。
          // 这里若写死成 30s,会硬截断所有需要 >30s 的请求(如 MessageBus 长轮询
          // 服务端 hold 25s),导致请求被 rhttp 提前 abort 抛 RhttpTimeoutException。
          timeout: Duration(minutes: 10),
          keepAliveTimeout: Duration(seconds: 60),
        ),
      ),
    );
  }

  String? _normalizeIp(String? raw) {
    if (raw == null) {
      return null;
    }
    return InternetAddress.tryParse(raw.trim())?.address;
  }

  rhttp.ProxySettings _buildProxySettings(
    NetworkSettings ns,
    ProxySettings ps,
  ) {
    if (!ps.isValid) {
      // 未配置上游代理时,Windows 下跟随注册表系统代理,与 WebView2
      // (默认走系统代理)保持同一出口。出口不一致时验证 WebView 铸出的
      // cf_clearance 绑定代理节点 IP,对直连的 Dio 无效,会造成 CF 验证
      // 无限循环。
      final systemProxy = SystemProxyService.instance.effectiveProxyUrl;
      if (systemProxy != null) {
        return rhttp.ProxySettings.proxy(systemProxy);
      }
      return const rhttp.ProxySettings.noProxy();
    }

    if (ps.isShadowsocks) {
      // SS：经本地 Rust 代理（tunnel 模式）
      final port = ns.proxyPort;
      if (port == null) return const rhttp.ProxySettings.noProxy();
      return rhttp.ProxySettings.proxy('http://127.0.0.1:$port');
    }

    // HTTP/SOCKS5：reqwest 原生支持
    final scheme = ps.protocol == UpstreamProxyProtocol.socks5
        ? 'socks5'
        : 'http';
    if (ps.username != null && ps.username!.isNotEmpty) {
      return rhttp.ProxySettings.proxy(
        '$scheme://${ps.username}:${ps.password ?? ""}@${ps.host}:${ps.port}',
      );
    }
    return rhttp.ProxySettings.proxy('$scheme://${ps.host}:${ps.port}');
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _disposeAllClients(force: force);
  }

  void _disposeAllClients({bool force = false}) {
    _buildEpoch++;
    _delegateBuilds.clear();
    _delegateBuildFingerprints.clear();
    _clientFingerprints.clear();
    _hostBuildTokens.clear();
    for (final client in _clients.values) {
      client.dispose(cancelRunningRequests: force);
    }
    _clients.clear();
    _delegates.clear();
  }
}

class _RhttpFetchResult {
  const _RhttpFetchResult({required this.responseBody, required this.remoteIp});

  final ResponseBody responseBody;
  final String? remoteIp;
}

class _RhttpDelegate {
  const _RhttpDelegate(this.client);

  final rhttp.RhttpClient client;

  Future<_RhttpFetchResult> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cancelToken = rhttp.CancelToken();
    cancelFuture?.whenComplete(cancelToken.cancel);

    try {
      final response = await client.requestStream(
        method: rhttp.HttpMethod(options.method.toUpperCase()),
        url: options.uri.toString(),
        headers: _buildHeaders(options),
        body: _buildBody(options, requestStream),
        cancelToken: cancelToken,
      );

      return _RhttpFetchResult(
        responseBody: ResponseBody(
          response.body.cast<Uint8List>().handleError(
            // flutter_rust_bridge STREAM_CANCEL_ERROR：
            // Dart 端取消了流（页面销毁/请求取消），Rust 端写入已关闭的 StreamSink。
            // 等价于流正常结束，静默吞掉避免 SIGABRT 崩溃。
            (error) {},
            test: (error) => error.toString().contains('STREAM_CANCEL_ERROR'),
          ),
          response.statusCode,
          headers: response.headerMapList,
          isRedirect: false,
        )..extra['remote_ip'] = response.remoteIp,
        remoteIp: response.remoteIp,
      );
    } on rhttp.RhttpException catch (error) {
      throw _mapRhttpException(options, error);
    }
  }

  rhttp.HttpHeaders? _buildHeaders(RequestOptions options) {
    if (options.headers.isEmpty) {
      return null;
    }

    final headers = <String, String>{};
    options.headers.forEach((key, value) {
      if (value == null) {
        return;
      }
      final headerValue = switch (value) {
        Iterable<Object?> values =>
          values
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .join(', '),
        _ => value.toString().trim(),
      };
      if (headerValue.isNotEmpty) {
        headers[key] = headerValue;
      }
    });
    if (headers.isEmpty) {
      return null;
    }
    return rhttp.HttpHeaders.rawMap(headers);
  }

  rhttp.HttpBody? _buildBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) {
    if (requestStream != null) {
      final contentLength = int.tryParse(
        options.headers['content-length']?.toString() ?? '',
      );
      return rhttp.HttpBody.stream(
        requestStream,
        length: contentLength != null && contentLength >= 0
            ? contentLength
            : null,
      );
    }

    final data = options.data;
    if (data == null) {
      return null;
    }
    if (data is Uint8List) {
      return rhttp.HttpBody.bytes(data);
    }
    if (data is List<int>) {
      return rhttp.HttpBody.bytes(Uint8List.fromList(data));
    }
    if (data is String) {
      return rhttp.HttpBody.text(data);
    }
    if (data is Map<String, String>) {
      return rhttp.HttpBody.form(data);
    }
    return rhttp.HttpBody.json(data);
  }

  DioException _mapRhttpException(
    RequestOptions options,
    rhttp.RhttpException error,
  ) {
    if (error is rhttp.RhttpCancelException) {
      return DioException(
        requestOptions: options,
        error: error,
        type: DioExceptionType.cancel,
        message: error.toString(),
      );
    }
    if (error is rhttp.RhttpTimeoutException) {
      return DioException.connectionTimeout(
        requestOptions: options,
        timeout:
            options.connectTimeout ?? options.receiveTimeout ?? Duration.zero,
        error: error,
      );
    }
    if (error is rhttp.RhttpInvalidCertificateException) {
      return DioException.badCertificate(requestOptions: options, error: error);
    }
    if (error is rhttp.RhttpConnectionException) {
      return DioException.connectionError(
        requestOptions: options,
        reason: error.message,
        error: error,
      );
    }
    if (error is rhttp.RhttpStatusCodeException) {
      return DioException.badResponse(
        statusCode: error.statusCode,
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: error.statusCode,
          headers: Headers.fromMap(error.headerMapList),
          data: error.body,
        ),
      );
    }
    return DioException(
      requestOptions: options,
      error: error,
      type: DioExceptionType.unknown,
    );
  }
}

class _PreparedClientConfig {
  const _PreparedClientConfig({
    required this.host,
    required this.hostKey,
    required this.dnsOverrides,
    required this.stickyIp,
    required this.echConfig,
    required this.dohEnabled,
  });

  final String host;
  final String hostKey;
  final List<String> dnsOverrides;
  final String? stickyIp;
  final Uint8List? echConfig;
  final bool dohEnabled;

  String get clientFingerprint {
    final dnsPart = dnsOverrides.isEmpty ? 'system' : dnsOverrides.join(',');
    final echPart = echConfig == null || echConfig!.isEmpty
        ? 'no-ech'
        : '${echConfig!.length}:${Object.hashAll(echConfig!)}';
    return '$dohEnabled|$dnsPart|$echPart';
  }

  rhttp.DnsSettings? toDnsSettings() {
    if (host.isEmpty || dnsOverrides.isEmpty) {
      return null;
    }
    return rhttp.DnsSettings.static(overrides: {host: dnsOverrides});
  }
}
