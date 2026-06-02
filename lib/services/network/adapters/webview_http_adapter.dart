import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../constants.dart';
import '../../auth_session.dart';
import '../cookie/app_cookie_manager.dart';
import '../cookie/boundary_sync_service.dart';
import '../cookie/cookie_jar_service.dart';
import '../cookie/session_cookie_sentinel.dart';
import '../cookie/webview_cookie_priming.dart';
import '../../webview_settings.dart';
import '../../windows_webview_environment_service.dart';
import 'adapter_log_metadata.dart';

/// WebView HTTP 适配器
///
/// 使用 InAppWebView 的 JS fetch() 发起 HTTP 请求。
/// 请求经过真正的 Chrome/WebKit 内核，TLS 指纹与浏览器完全一致，
/// 可绕过 Cloudflare Bot Management 等基于指纹的检测。
///
/// 全平台支持：Android (Chrome WebView)、iOS/macOS (WKWebView)、
/// Windows (WebView2)、Linux (WebKitGTK)。
class WebViewHttpAdapter implements HttpClientAdapter {
  static const Set<String> _forbiddenBrowserHeaders = {
    'accept-charset',
    'accept-encoding',
    'access-control-request-headers',
    'access-control-request-method',
    'connection',
    'content-length',
    'cookie',
    'cookie2',
    'date',
    'dnt',
    'expect',
    'host',
    'keep-alive',
    'origin',
    'referer',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'user-agent',
      'via',
  };
  @visibleForTesting
  static const String fetchCacheModeExtraKey = 'webViewFetchCacheMode';
  static const Set<String> _supportedFetchCacheModes = {
    'default',
    'no-store',
    'reload',
    'no-cache',
    'force-cache',
    'only-if-cached',
  };
  @visibleForTesting
  static const String defaultApiFetchCacheMode = 'no-store';
  HeadlessInAppWebView? _headlessWebView;
  InAppWebViewController? _controller;
  bool _isInitialized = false;
  Completer<void>? _initCompleter;
  Future<void>? _activeCriticalCookieSync;
  DateTime? _lastCriticalCookieSyncAt;

  final Map<String, Completer<String>> _pendingRequests = {};
  int _requestId = 0;

  /// 初始化 WebView
  Future<void> initialize() async {
    if (_isInitialized && _controller != null) return;
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      await _initCompleter!.future;
      return;
    }

    final initCompleter = Completer<void>();
    _initCompleter = initCompleter;

    try {
      _headlessWebView = HeadlessInAppWebView(
        // Windows 需要 WebView2 环境，其他平台传 null
        webViewEnvironment: Platform.isWindows
            ? WindowsWebViewEnvironmentService.instance.environment
            : null,
        // 加载主站页面（而非 about:blank），确保 cookie store 已初始化
        initialUrlRequest: URLRequest(url: WebUri(AppConstants.baseUrl)),
        initialSettings: WebViewSettings.headless,
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onWebViewCreated: (controller) {
          _controller = controller;

          controller.addJavaScriptHandler(
            handlerName: 'fetchResult',
            callback: (args) {
              if (args.isNotEmpty && args[0] is Map) {
                final data = args[0] as Map;
                final requestId = data['requestId']?.toString();
                final result = data['result']?.toString() ?? '';

                if (requestId != null &&
                    _pendingRequests.containsKey(requestId)) {
                  _pendingRequests[requestId]!.complete(result);
                  _pendingRequests.remove(requestId);
                }
              }
            },
          );

          debugPrint('[WebViewAdapter] Controller created');
        },
        onLoadStop: (controller, url) {
          debugPrint('[WebViewAdapter] Page loaded: $url');
          if (!initCompleter.isCompleted) {
            initCompleter.complete();
          }
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame != false && !initCompleter.isCompleted) {
            initCompleter.completeError(
              StateError(
                'WebView init failed: ${error.type} ${error.description}',
              ),
            );
          }
        },
      );

      await _headlessWebView!.run();

      await initCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('WebView init timeout');
        },
      );

      _isInitialized = true;
      debugPrint('[WebViewAdapter] Initialized');
    } catch (e) {
      debugPrint('[WebViewAdapter] Init failed: $e');
      close(force: true);
      rethrow;
    } finally {
      if (identical(_initCompleter, initCompleter) && !_isInitialized) {
        _initCompleter = null;
      }
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    setRequestAdapterLogName(options, 'webview');

    if (!_isInitialized || _controller == null) {
      await initialize();
    }

    if (_controller == null) {
      throw DioException(
        requestOptions: options,
        error: 'WebView controller not available',
        type: DioExceptionType.unknown,
      );
    }

    final url = options.uri.toString();
    final method = options.method.toUpperCase();
    final requestId = (++_requestId).toString();
    final requestUri = Uri.parse(url);
    final baseUri = Uri.parse(AppConstants.baseUrl);
    final shouldSyncAppCookies = _shouldSyncAppCookies(requestUri, baseUri);

    if (shouldSyncAppCookies) {
      // v0.4.0: 取代 RawSetCookieQueue.flush + _repair + _syncCookiesFromJar
      // 1. Priming: 确保 WV 中 jar 的 critical cookies 已就绪
      // 2. sweepAll: 清理 critical cookies 的多变体 (兜底)
      // 3. mark as path B: 让 onResponse 走路径 B 处理 (跳过 jar 写入,
      //    sweep 反向同步)
      try {
        await WebViewCookiePriming.instance.prime(url);
      } catch (e) {
        debugPrint('[WebViewAdapter] priming failed (continuing): $e');
      }
      await SessionCookieSentinel.instance.sweepAll(url);
      AppCookieManager.markAsWebViewAdapter(options);
    }

    // 非应用站点的备选路径：通过 CookieManager 写入 cookie
    final cookieHeader = options.headers['Cookie']?.toString();
    if (!shouldSyncAppCookies &&
        cookieHeader != null &&
        cookieHeader.isNotEmpty) {
      await _syncCookiesViaCookieManager(url, cookieHeader);
    }

    // 构建 headers（移除 Cookie，由 WebView 自动处理）
    final headersMap = _buildBrowserSafeHeaders(options.headers);
    final fetchCacheMode = resolveFetchCacheMode(options);
    if (fetchCacheMode != null) {
      final currentFields = options.extra['_networkLogFields'];
      if (currentFields is Map<String, dynamic>) {
        currentFields['webViewCacheMode'] = fetchCacheMode;
      } else {
        final mergedFields = <String, dynamic>{};
        if (currentFields is Map) {
          currentFields.forEach((key, value) {
            if (key is String) {
              mergedFields[key] = value;
            }
          });
        }
        mergedFields['webViewCacheMode'] = fetchCacheMode;
        options.extra['_networkLogFields'] = mergedFields;
      }
    }

    // 构建 body
    final bodyPlan = await _buildRequestBodyPlan(
      options,
      requestStream,
      method: method,
      requestId: requestId,
      requestUri: requestUri,
    );
    final bodyScript = bodyPlan.script;

    final completer = Completer<String>();
    _pendingRequests[requestId] = completer;

    final isBinary = options.responseType == ResponseType.bytes;

    final script = '''
      (async function() {
        try {
          const fetchOptions = {
            method: '$method',
            headers: ${jsonEncode(headersMap)},
            credentials: 'include'${fetchCacheMode != null ? ",\n            cache: ${jsonEncode(fetchCacheMode)}" : ''}
          };
          $bodyScript

          const response = await fetch('$url', fetchOptions);

          let bodyData;
          let isBase64 = false;

          if ($isBinary) {
            const buffer = await response.arrayBuffer();
            let binary = '';
            const bytes = new Uint8Array(buffer);
            const len = bytes.byteLength;
            for (let i = 0; i < len; i++) {
              binary += String.fromCharCode(bytes[i]);
            }
            bodyData = window.btoa(binary);
            isBase64 = true;
          } else {
            bodyData = await response.text();
          }

          const headersObj = {};
          response.headers.forEach((v, k) => headersObj[k] = v);

          const result = JSON.stringify({
            ok: true,
            status: response.status,
            statusText: response.statusText,
            headers: headersObj,
            body: bodyData,
            isBase64: isBase64
          });

          window.flutter_inappwebview.callHandler('fetchResult', {
            requestId: '$requestId',
            result: result
          });
        } catch (e) {
          window.flutter_inappwebview.callHandler('fetchResult', {
            requestId: '$requestId',
            result: JSON.stringify({ok: false, error: e.toString()})
          });
        }
      })();
    ''';

    debugPrint(
      '[WebViewAdapter] Fetching: $method $url (id: $requestId, binary: $isBinary)',
    );

    await _controller!.evaluateJavascript(source: script);

    // 超时从 RequestOptions 读取，默认 30 秒
    final timeout =
        options.receiveTimeout ??
        options.connectTimeout ??
        const Duration(seconds: 30);

    final resultStr = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingRequests.remove(requestId);
        throw DioException(
          requestOptions: options,
          error: 'WebView request timeout',
          type: DioExceptionType.receiveTimeout,
        );
      },
    );

    final responseData = jsonDecode(resultStr) as Map<String, dynamic>;

    if (responseData['ok'] != true) {
      throw DioException(
        requestOptions: options,
        error: responseData['error']?.toString() ?? 'Unknown error',
        type: DioExceptionType.unknown,
      );
    }

    final statusCode = responseData['status'] as int? ?? 200;
    final bodyContent = responseData['body'] as String? ?? '';
    final isBase64 = responseData['isBase64'] as bool? ?? false;

    final responseHeaders = <String, List<String>>{};

    if (responseData['headers'] is Map) {
      (responseData['headers'] as Map).forEach((key, value) {
        responseHeaders[key.toString()] = [value.toString()];
      });
    }

    _throwIfSessionExpired(options);

    if (shouldSyncAppCookies) {
      await _syncCriticalCookiesBackToJar(
        url,
        force: method != 'GET' && method != 'HEAD',
        requestGeneration: options.extra['_sessionGeneration'] as int?,
      );
    }

    _throwIfSessionExpired(options);

    debugPrint('[WebViewAdapter] Response: $statusCode (binary: $isBase64)');

    if (isBase64) {
      final bytes = base64Decode(bodyContent);
      return ResponseBody.fromBytes(
        bytes,
        statusCode,
        headers: responseHeaders,
      );
    } else {
      return ResponseBody.fromString(
        bodyContent,
        statusCode,
        headers: responseHeaders,
      );
    }
  }

  @override
  void close({bool force = false}) {
    _headlessWebView?.dispose();
    _headlessWebView = null;
    _controller = null;
    _isInitialized = false;
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      _initCompleter!.completeError(StateError('WebView adapter closed'));
    }
    _initCompleter = null;
    _activeCriticalCookieSync = null;
    _lastCriticalCookieSyncAt = null;
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError('WebView adapter closed');
      }
    }
    _pendingRequests.clear();
  }

  bool _shouldSyncAppCookies(Uri requestUri, Uri baseUri) {
    final requestHost = requestUri.host;
    final baseHost = baseUri.host;
    if (requestHost.isEmpty || baseHost.isEmpty) {
      return false;
    }
    return requestHost == baseHost || requestHost.endsWith('.$baseHost');
  }

  /// 通过全平台 CookieManager API 写入 cookie
  Future<void> _syncCookiesViaCookieManager(
    String url,
    String cookieHeader,
  ) async {
    try {
      final cookieManager = _resolveCookieManager();
      final webUri = WebUri(url);
      final cookies = cookieHeader.split('; ');
      for (final cookie in cookies) {
        final parts = cookie.split('=');
        if (parts.length >= 2) {
          final name = parts[0].trim();
          final value = parts.sublist(1).join('=').trim();
          await cookieManager.setCookie(
            url: webUri,
            name: name,
            value: value,
          );
        }
      }
    } catch (e) {
      debugPrint('[WebViewAdapter] Failed to sync cookies: $e');
    }
  }

  Future<_RequestBodyPlan> _buildRequestBodyPlan(
    RequestOptions options,
    Stream<Uint8List>? requestStream, {
    required String method,
    required String requestId,
    required Uri requestUri,
  }) async {
    if (method == 'GET' || method == 'HEAD') {
      return const _RequestBodyPlan(script: '');
    }

    final directBodyScript = await _buildDirectBodyScript(options);
    if (directBodyScript != null) {
      return _RequestBodyPlan(script: directBodyScript);
    }

    final streamedBodyScript = await _buildStreamedBodyScript(
      requestStream,
      requestId: requestId,
      requestUri: requestUri,
    );
    if (streamedBodyScript != null) {
      return _RequestBodyPlan(script: streamedBodyScript);
    }

    final requestBytes = await _readRequestBytes(requestStream);
    if (requestBytes != null && requestBytes.isNotEmpty) {
      final bodyBase64 = base64Encode(requestBytes);
      return _RequestBodyPlan(
        script: '''
          const bodyBytes = Uint8Array.from(
            atob(${jsonEncode(bodyBase64)}),
            (char) => char.charCodeAt(0)
          );
          const contentTypeHeader = Object.entries(fetchOptions.headers).find(
            ([key]) => key.toLowerCase() === 'content-type'
          );
          const contentType = contentTypeHeader ? String(contentTypeHeader[1] ?? '') : '';
          if (
            /application\\/x-www-form-urlencoded/i.test(contentType) ||
            /application\\/json/i.test(contentType) ||
            /^text\\//i.test(contentType)
          ) {
            fetchOptions.body = new TextDecoder().decode(bodyBytes);
          } else {
            fetchOptions.body = contentType
              ? new Blob([bodyBytes], { type: contentType })
              : new Blob([bodyBytes]);
          }
      ''',
      );
    }

    if (options.data == null) {
      return const _RequestBodyPlan(script: '');
    }

    return _RequestBodyPlan(
      script: "fetchOptions.body = ${jsonEncode(options.data.toString())};",
    );
  }

  Future<String?> _buildStreamedBodyScript(
    Stream<Uint8List>? requestStream, {
    required String requestId,
    required Uri requestUri,
  }) async {
    if (requestStream == null) {
      return null;
    }

    final controller = _controller;
    if (controller == null) {
      return null;
    }

    WebMessageChannel? channel;
    var transferStarted = false;

    try {
      await _installRequestBodyBridge(controller);

      channel = await controller.createWebMessageChannel();
      if (channel == null) {
        return null;
      }

      final port = channel.port1;
      final readyCompleter = Completer<void>();
      final completeCompleter = Completer<void>();
      final errorCompleter = Completer<String>();

      await port.setWebMessageCallback((message) async {
        final payload = message?.data;
        if (payload is! String || payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map) return;
          final kind = decoded['kind']?.toString();
          if (kind == 'ready' && !readyCompleter.isCompleted) {
            readyCompleter.complete();
          } else if (kind == 'complete' && !completeCompleter.isCompleted) {
            completeCompleter.complete();
          } else if (kind == 'error' && !errorCompleter.isCompleted) {
            errorCompleter.complete(decoded['error']?.toString() ?? 'unknown');
          }
        } catch (_) {}
      });

      final origin = requestUri.origin;
      await controller.postWebMessage(
        message: WebMessage(
          data: '__fluxdo:body:$requestId',
          ports: [channel.port2],
        ),
        targetOrigin: WebUri(origin),
      );

      await _awaitRequestBodyPortReady(
        readyCompleter,
        errorCompleter,
        requestId: requestId,
      );

      transferStarted = true;
      await _pipeRequestStreamToPort(requestStream, port);

      await _postRequestBodyControlMessage(port, {
        'kind': 'complete',
        'requestId': requestId,
      });

      await _awaitRequestBodyTransferComplete(
        completeCompleter,
        errorCompleter,
        requestId: requestId,
      );

      return 'fetchOptions.body = window.__fluxdoTakeRequestBody(${jsonEncode(requestId)});';
    } catch (e) {
      if (!transferStarted) {
        debugPrint('[WebViewAdapter] Stream bridge unavailable, fallback to base64: $e');
        return null;
      }
      rethrow;
    } finally {
      channel?.dispose();
    }
  }

  Future<String?> _buildDirectBodyScript(RequestOptions options) async {
    final data = options.data;
    if (data == null || data is FormData) {
      return null;
    }
    if (data is Uint8List || data is List<int>) {
      return null;
    }

    final bodyText = await Transformer.defaultTransformRequest(
      options,
      (object) => jsonEncode(object),
    );
    return "fetchOptions.body = ${jsonEncode(bodyText)};";
  }

  Future<void> _installRequestBodyBridge(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source: '''
        (function() {
          if (window.__fluxdoRequestBodyBridgeInstalled) return;
          window.__fluxdoRequestBodyBridgeInstalled = true;
          window.__fluxdoRequestBodyTransfers = new Map();

          function ensureState(requestId) {
            var state = window.__fluxdoRequestBodyTransfers.get(requestId);
            if (!state) {
              state = {
                chunks: [],
                body: null
              };
              window.__fluxdoRequestBodyTransfers.set(requestId, state);
            }
            return state;
          }

          window.__fluxdoTakeRequestBody = function(requestId) {
            var state = window.__fluxdoRequestBodyTransfers.get(requestId);
            if (!state || state.body === null) {
              throw new Error('Request body not ready for request ' + requestId);
            }
            var body = state.body;
            window.__fluxdoRequestBodyTransfers.delete(requestId);
            return body;
          };

          window.addEventListener('message', function(event) {
            if (typeof event.data !== 'string' || !event.data.startsWith('__fluxdo:body:')) {
              return;
            }

            var requestId = event.data.substring('__fluxdo:body:'.length);
            var port = event.ports && event.ports[0];
            if (!port) return;

            var state = ensureState(requestId);
            state.chunks = [];
            state.body = null;

            port.onmessage = function(portEvent) {
              try {
                var payload = portEvent.data;
                if (typeof payload === 'string') {
                  var message = JSON.parse(payload);
                  switch (message.kind) {
                    case 'complete':
                      state.body = new Blob(state.chunks);
                      state.chunks = [];
                      port.postMessage(JSON.stringify({ kind: 'complete', requestId: requestId }));
                      break;
                  }
                  return;
                }

                if (payload instanceof ArrayBuffer) {
                  state.chunks.push(payload);
                  return;
                }

                if (ArrayBuffer.isView(payload)) {
                  state.chunks.push(payload.buffer.slice(
                    payload.byteOffset,
                    payload.byteOffset + payload.byteLength
                  ));
                }
              } catch (error) {
                port.postMessage(JSON.stringify({
                  kind: 'error',
                  requestId: requestId,
                  error: String(error)
                }));
              }
            };

            if (port.start) {
              port.start();
            }
            port.postMessage(JSON.stringify({ kind: 'ready', requestId: requestId }));
          });
        })();
      ''',
    );
  }

  Future<void> _postRequestBodyControlMessage(
    WebMessagePort port,
    Map<String, dynamic> payload,
  ) {
    return port.postMessage(WebMessage(data: jsonEncode(payload)));
  }

  Future<void> _awaitRequestBodyPortReady(
    Completer<void> readyCompleter,
    Completer<String> errorCompleter, {
    required String requestId,
  }) async {
    await Future.any([
      readyCompleter.future,
      errorCompleter.future.then<void>((error) {
        throw StateError(
          'Request body port setup failed for request $requestId: $error',
        );
      }),
    ]).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Request body port setup timeout for request $requestId',
      ),
    );
  }

  Future<void> _awaitRequestBodyTransferComplete(
    Completer<void> completeCompleter,
    Completer<String> errorCompleter, {
    required String requestId,
  }) async {
    await Future.any([
      completeCompleter.future,
      errorCompleter.future.then<void>((error) {
        throw StateError(
          'Request body transfer failed for request $requestId: $error',
        );
      }),
    ]).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'Request body transfer timeout for request $requestId',
      ),
    );
  }

  Future<void> _pipeRequestStreamToPort(
    Stream<Uint8List> requestStream,
    WebMessagePort port,
  ) async {
    const targetChunkBytes = 64 * 1024;

    var bufferedLength = 0;
    var builder = BytesBuilder(copy: false);

    Future<void> flush() async {
      if (bufferedLength == 0) {
        return;
      }
      final bytes = builder.takeBytes();
      builder = BytesBuilder(copy: false);
      bufferedLength = 0;
      await port.postMessage(
        WebMessage(
          data: bytes,
          type: WebMessageType.ARRAY_BUFFER,
        ),
      );
    }

    await for (final chunk in requestStream) {
      if (chunk.isEmpty) {
        continue;
      }
      if (chunk.length >= targetChunkBytes) {
        await flush();
        await port.postMessage(
          WebMessage(
            data: chunk,
            type: WebMessageType.ARRAY_BUFFER,
          ),
        );
        continue;
      }

      if (bufferedLength + chunk.length > targetChunkBytes &&
          bufferedLength > 0) {
        await flush();
      }

      builder.add(chunk);
      bufferedLength += chunk.length;

      if (bufferedLength >= targetChunkBytes) {
        await flush();
      }
    }

    await flush();
  }

  @visibleForTesting
  static String? resolveFetchCacheMode(RequestOptions options) {
    final requestedMode =
        options.extra[fetchCacheModeExtraKey]?.toString().trim().toLowerCase();
    if (requestedMode != null && requestedMode.isNotEmpty) {
      if (_supportedFetchCacheModes.contains(requestedMode)) {
        return requestedMode;
      }
      debugPrint(
        '[WebViewAdapter] Ignore unsupported fetch cache mode: $requestedMode',
      );
    }

    final method = options.method.toUpperCase();
    if (method == 'GET' || method == 'HEAD') {
      return defaultApiFetchCacheMode;
    }
    return null;
  }

  Future<Uint8List?> _readRequestBytes(Stream<Uint8List>? requestStream) async {
    if (requestStream == null) return null;

    final builder = BytesBuilder(copy: false);
    await for (final chunk in requestStream) {
      if (chunk.isNotEmpty) {
        builder.add(chunk);
      }
    }
    return builder.isEmpty ? null : builder.takeBytes();
  }

  Map<String, String> _buildBrowserSafeHeaders(Map<String, dynamic> headers) {
    final headersMap = <String, String>{};
    final droppedHeaders = <String>[];

    headers.forEach((key, value) {
      if (value == null) return;
      if (_isForbiddenBrowserHeader(key)) {
        droppedHeaders.add(key);
        return;
      }
      headersMap[key] = value.toString();
    });

    if (droppedHeaders.isNotEmpty) {
      debugPrint(
        '[WebViewAdapter] Dropped browser-managed headers: '
        '${droppedHeaders.join(', ')}',
      );
    }

    return headersMap;
  }

  bool _isForbiddenBrowserHeader(String key) {
    final normalized = key.trim().toLowerCase();
    if (_forbiddenBrowserHeaders.contains(normalized)) {
      return true;
    }
    return normalized.startsWith('sec-') || normalized.startsWith('proxy-');
  }

  CookieManager _resolveCookieManager() {
    return Platform.isWindows
        ? WindowsWebViewEnvironmentService.instance.cookieManager
        : CookieManager.instance();
  }


  void _throwIfSessionExpired(RequestOptions options) {
    final requestGeneration = options.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        error:
            '会话已过期 (gen=$requestGeneration, current=${AuthSession().generation})',
      );
    }
  }

  Future<void> _syncCriticalCookiesBackToJar(
    String currentUrl, {
    bool force = false,
    int? requestGeneration,
  }) async {
    final controller = _controller;
    if (controller == null) return;

    if (!force) {
      final lastSyncAt = _lastCriticalCookieSyncAt;
      if (lastSyncAt != null &&
          DateTime.now().difference(lastSyncAt) <
              const Duration(milliseconds: 800)) {
        final active = _activeCriticalCookieSync;
        if (active != null) {
          await active;
        }
        return;
      }
    }

    final active = _activeCriticalCookieSync;
    if (active != null) {
      await active;
      return;
    }

    final future = BoundarySyncService.instance.syncFromWebView(
      currentUrl: currentUrl,
      controller: controller,
      cookieNames: CookieJarService.criticalCookieNames,
      requestGeneration: requestGeneration,
    );

    _activeCriticalCookieSync = future.whenComplete(() {
      _lastCriticalCookieSyncAt = DateTime.now();
      _activeCriticalCookieSync = null;
    });

    await _activeCriticalCookieSync!;
  }
}

class _RequestBodyPlan {
  const _RequestBodyPlan({required this.script});

  final String script;
}
