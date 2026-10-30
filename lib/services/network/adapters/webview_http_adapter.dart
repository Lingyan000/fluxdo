import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../constants.dart';
import '../../../utils/frame_jank_monitor.dart';
import '../../auth_session.dart';
import '../cookie/app_cookie_manager.dart';
import '../cookie/boundary_sync_service.dart';
import '../cookie/cookie_jar_service.dart';
import '../cookie/session_cookie_sentinel.dart';
import '../cookie/webview_cookie_priming.dart';
import '../../webview_settings.dart';
import '../../windows_webview_environment_service.dart';
import 'adapter_log_metadata.dart';
import 'webview_response_codec.dart';
import 'webview_request_codec.dart';
import 'webview_operation_guard.dart';

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
  static const String resourceKindExtraKey = 'webViewResourceKind';
  static const String cookieModeExtraKey = 'webViewCookieMode';
  static const String resourceKindImage = 'image';
  static const String resourceKindUpload = 'upload';
  static const String cookieModeReadOnly = 'readOnly';
  static const String cookieModeNone = 'none';
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
  final _responseTransport = WebViewResponseTransport(
    isAndroid: Platform.isAndroid,
    supportsArrayBuffer: () => WebViewFeature.isFeatureSupported(
      WebViewFeature.WEB_MESSAGE_ARRAY_BUFFER,
    ),
  );
  HeadlessInAppWebView? _headlessWebView;
  InAppWebViewController? _controller;
  bool _isInitialized = false;
  Completer<void>? _initCompleter;
  Future<void>? _activeCriticalCookieSync;
  DateTime? _lastCriticalCookieSyncAt;

  final Map<String, Completer<String>> _pendingRequests = {};
  int _requestId = 0;
  int _activeFetches = 0;
  bool _disposeWhenIdle = false;

  /// 初始化 WebView
  Future<void> initialize() async {
    if (_isInitialized && _controller != null) return;
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      await _initCompleter!.future;
      return;
    }

    final initCompleter = Completer<void>();
    _initCompleter = initCompleter;
    var pageLoadCompleter = Completer<void>();
    final initWatch = Stopwatch()..start();

    try {
      _headlessWebView = HeadlessInAppWebView(
        // Windows 需要 WebView2 环境，其他平台传 null
        webViewEnvironment: Platform.isWindows
            ? WindowsWebViewEnvironmentService.instance.environment
            : null,
        initialSettings: WebViewSettings.headless,
        initialUserScripts: WebViewSettings.compatPolyfillScripts,
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onWebViewCreated: (controller) {
          _controller = controller;
          WebViewSettings.applyWindowsHeadlessMemoryTarget(controller);
          WebViewSettings.registerJsErrorReporter(controller);

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
          if (!pageLoadCompleter.isCompleted) {
            pageLoadCompleter.complete();
          }
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame != false &&
              !pageLoadCompleter.isCompleted) {
            pageLoadCompleter.completeError(
              StateError(
                'WebView init failed: ${error.type} ${error.description}',
              ),
            );
          }
        },
      );

      await _headlessWebView!.run();
      final controller = _headlessWebView!.webViewController;
      if (controller == null) {
        throw StateError('Headless WebView controller is null');
      }

      pageLoadCompleter = Completer<void>();
      if (Platform.isWindows) {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(_windowsBootstrapUrl)),
        );
      } else {
        await controller.loadData(
          data: _bootstrapHtml,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }

      await pageLoadCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('WebView init timeout');
        },
      );

      if (Platform.isWindows) {
        await _writeBootstrapHtml(controller);
      }

      _isInitialized = true;
      if (!initCompleter.isCompleted) {
        initCompleter.complete();
      }
      initWatch.stop();
      debugPrint(
        '[WebViewAdapter] Initialized (${initWatch.elapsedMilliseconds}ms)',
      );
      // WebView 创建占用平台主线程,与掉帧时间轴对齐归因
      FrameJankMonitor.logEvent(
        'WEBVIEW',
        'HttpAdapter init ${initWatch.elapsedMilliseconds}ms',
      );
    } catch (e) {
      debugPrint('[WebViewAdapter] Init failed: $e');
      if (!initCompleter.isCompleted) {
        initCompleter.completeError(e);
      }
      close(force: true);
      rethrow;
    } finally {
      if (identical(_initCompleter, initCompleter) && !_isInitialized) {
        _initCompleter = null;
      }
    }
  }

  Future<void> _writeBootstrapHtml(InAppWebViewController controller) async {
    final html = jsonEncode(_bootstrapHtml);
    await controller.evaluateJavascript(
      source:
          '''
document.open();
document.write($html);
document.close();
''',
    );
  }

  String get _windowsBootstrapUrl => '${AppConstants.baseUrl}/robots.txt';

  String get _bootstrapHtml =>
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body></body></html>';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    setRequestAdapterLogName(options, 'webview');
    _activeFetches++;

    final totalWatch = Stopwatch()..start();
    Duration? cookiePrepElapsed;
    Duration? jsEvalElapsed;
    Duration? browserWaitElapsed;
    Duration? cookieBackSyncElapsed;
    String? bodyRequestId;

    try {
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
      bodyRequestId = requestId;
      final requestUri = Uri.parse(url);
      final baseUri = Uri.parse(AppConstants.baseUrl);
      final shouldSyncAppCookies = _shouldSyncAppCookies(requestUri, baseUri);
      final cookieMode = _resolveCookieMode(options, shouldSyncAppCookies);
      final syncAppCookies = cookieMode == _WebViewCookieMode.sync;
      final prepareAppCookies = cookieMode != _WebViewCookieMode.none;
      final wantsBinaryStream =
          options.responseType == ResponseType.stream ||
          options.responseType == ResponseType.bytes;

      if (prepareAppCookies) {
        // v0.4.0: 取代 RawSetCookieQueue.flush + _repair + _syncCookiesFromJar
        // 1. Priming: 确保 WV 中 jar 的 critical cookies 已就绪
        // 2. sweepAll: 清理 critical cookies 的多变体 (兜底)
        // 3. mark as path B: 让 onResponse 走路径 B 处理 (跳过 jar 写入,
        //    sweep 反向同步)
        final cookiePrepWatch = Stopwatch()..start();
        try {
          await WebViewCookiePriming.instance.prime(url);
        } catch (e) {
          debugPrint('[WebViewAdapter] priming failed (continuing): $e');
        }
        if (syncAppCookies) {
          await SessionCookieSentinel.instance.sweepAll(url);
        }
        cookiePrepWatch.stop();
        cookiePrepElapsed = cookiePrepWatch.elapsed;
        if (syncAppCookies) {
          AppCookieManager.markAsWebViewAdapter(options);
        }
      }

      // 非应用站点的备选路径：通过 CookieManager 写入 cookie
      final cookieHeader = options.headers['Cookie']?.toString();
      if (cookieMode == _WebViewCookieMode.none &&
          cookieHeader != null &&
          cookieHeader.isNotEmpty) {
        await _syncCookiesViaCookieManager(url, cookieHeader);
      }

      // 构建 headers（移除 Cookie，由 WebView 自动处理）
      final headersMap = _buildBrowserSafeHeaders(options.headers);
      final fetchCacheMode = resolveFetchCacheMode(options);
      if (fetchCacheMode != null) {
        _setNetworkLogField(options, 'webViewCacheMode', fetchCacheMode);
      }

      // 构建 body
      final bodyGuard = WebViewOperationGuard(
        timeout:
            options.sendTimeout ??
            options.receiveTimeout ??
            const Duration(seconds: 30),
        timeoutError: DioException(
          requestOptions: options,
          type: DioExceptionType.sendTimeout,
          error: '上传准备超时',
        ),
        cancel: cancelFuture,
        cancelError: DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          error: '上传已取消',
        ),
      );
      late final _RequestBodyPlan bodyPlan;
      try {
        bodyPlan = await bodyGuard.run(
          () => _buildRequestBodyPlan(
            options,
            requestStream,
            method: method,
            requestId: requestId,
            requestUri: requestUri,
            guard: bodyGuard,
          ),
        );
      } finally {
        bodyGuard.dispose();
      }
      final bodyScript = bodyPlan.script;

      if (wantsBinaryStream) {
        final response = await _fetchBinaryStreamResponse(
          options,
          requestId: requestId,
          method: method,
          url: url,
          headersMap: headersMap,
          bodyScript: bodyScript,
          fetchCacheMode: fetchCacheMode,
          cancelFuture: cancelFuture,
          totalWatch: totalWatch,
          cookiePrepElapsed: cookiePrepElapsed,
        );
        return response;
      }

      final completer = Completer<String>();
      _pendingRequests[requestId] = completer;
      final traceUpload =
          options.extra[resourceKindExtraKey] == resourceKindUpload;
      final uploadDiagnosticsScript = traceUpload
          ? buildUploadDiagnosticsScript(requestId)
          : 'const uploadTrace = function() {};';

      final script =
          '''
      (async function() {
        const requestId = ${jsonEncode(requestId)};
        $uploadDiagnosticsScript
        try {
          window.__fluxdoFetchAborters = window.__fluxdoFetchAborters || {};
          window.__fluxdoAbortFetch = window.__fluxdoAbortFetch || function(id) {
            const controller = window.__fluxdoFetchAborters && window.__fluxdoFetchAborters[id];
            if (controller) {
              controller.abort();
              delete window.__fluxdoFetchAborters[id];
            }
          };

          const controller = new AbortController();
          window.__fluxdoFetchAborters[requestId] = controller;

          const fetchOptions = {
            method: ${jsonEncode(method)},
            headers: ${jsonEncode(headersMap)},
            credentials: 'include',
            signal: controller.signal${fetchCacheMode != null ? ",\n            cache: ${jsonEncode(fetchCacheMode)}" : ''}
          };
          $bodyScript

          uploadTrace('fetch_started', fetchOptions.body ? fetchOptions.body.size : null);
          const response = await fetch(${jsonEncode(url)}, fetchOptions);
          uploadTrace('response_headers', response.status);

          const bodyData = await response.text();
          uploadTrace('response_body');

          const headersObj = {};
          response.headers.forEach((v, k) => headersObj[k] = v);

          const result = JSON.stringify({
            ok: true,
            status: response.status,
            statusText: response.statusText,
            headers: headersObj,
            body: bodyData,
            isBase64: false
          });

          uploadTrace('result_dispatch');
          await window.flutter_inappwebview.callHandler('fetchResult', {
            requestId: requestId,
            result: result
          });
        } catch (e) {
          uploadTrace('javascript_error');
          try {
            await window.flutter_inappwebview.callHandler('fetchResult', {
              requestId: requestId,
              result: JSON.stringify({ok: false, error: e.toString()})
            });
          } catch (_) {
            uploadTrace('result_bridge_error');
          }
        } finally {
          if (window.__fluxdoFetchAborters) {
            delete window.__fluxdoFetchAborters[requestId];
          }
        }
      })();
    ''';

      debugPrint('[WebViewAdapter] Fetching: $method $url (id: $requestId)');

      final cancelFutureForRequest = cancelFuture;
      if (cancelFutureForRequest != null) {
        unawaited(
          cancelFutureForRequest.then<void>((_) async {
            final pending = _pendingRequests.remove(requestId);
            if (pending != null && !pending.isCompleted) {
              pending.completeError(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.cancel,
                  error: 'WebView request canceled',
                ),
              );
            }
            await _abortWebViewFetch(requestId);
          }, onError: (_) {}),
        );
      }

      try {
        final jsEvalWatch = Stopwatch()..start();
        await _controller!.evaluateJavascript(source: script);
        jsEvalWatch.stop();
        jsEvalElapsed = jsEvalWatch.elapsed;
      } catch (_) {
        _pendingRequests.remove(requestId);
        rethrow;
      }

      // 超时从 RequestOptions 读取，默认 30 秒
      final timeout =
          options.receiveTimeout ??
          options.connectTimeout ??
          const Duration(seconds: 30);

      final browserWaitWatch = Stopwatch()..start();
      final resultStr = await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRequests.remove(requestId);
          unawaited(_abortWebViewFetch(requestId));
          throw DioException(
            requestOptions: options,
            error: 'WebView request timeout',
            type: DioExceptionType.receiveTimeout,
          );
        },
      );
      browserWaitWatch.stop();
      browserWaitElapsed = browserWaitWatch.elapsed;

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

      final responseHeaders = <String, List<String>>{};

      if (responseData['headers'] is Map) {
        (responseData['headers'] as Map).forEach((key, value) {
          responseHeaders[key.toString()] = [value.toString()];
        });
      }

      _throwIfSessionExpired(options);

      if (syncAppCookies) {
        final trustsWebViewSession = _trustsWebViewSessionFromResponse(
          options,
          statusCode,
          responseHeaders,
        );
        // 成功的 WebView 登录态请求本身就是服务端认可 session 的证明。
        // 失败/登出信号路径仍只同步非登录态 cookie，避免旧 _t 回灌。
        final cookieBackSyncWatch = Stopwatch()..start();
        await _syncCriticalCookiesBackToJar(
          url,
          force: trustsWebViewSession || (method != 'GET' && method != 'HEAD'),
          requestGeneration: options.extra['_sessionGeneration'] as int?,
          excludeCookieNames: trustsWebViewSession
              ? null
              : CookieJarService.authCookieNames,
        );
        cookieBackSyncWatch.stop();
        cookieBackSyncElapsed = cookieBackSyncWatch.elapsed;
      }

      _throwIfSessionExpired(options);

      totalWatch.stop();
      _recordTimings(
        options,
        total: totalWatch.elapsed,
        cookiePrep: cookiePrepElapsed,
        jsEval: jsEvalElapsed,
        browserWait: browserWaitElapsed,
        cookieBackSync: cookieBackSyncElapsed,
      );

      debugPrint(
        '[WebViewAdapter] Response: $statusCode ('
        'total=${totalWatch.elapsedMilliseconds}ms, '
        'browser=${browserWaitElapsed.inMilliseconds}ms)',
      );

      return ResponseBody.fromString(
        bodyContent,
        statusCode,
        headers: responseHeaders,
      );
    } catch (error) {
      // 失败也保留已完成阶段，不记录文件名、正文、Cookie 或 JS 错误原文。
      _setNetworkLogField(
        options,
        'webViewErrorType',
        error is DioException ? error.type.name : error.runtimeType.toString(),
      );
      if (bodyRequestId != null &&
          options.extra[resourceKindExtraKey] == resourceKindUpload) {
        await _collectUploadDiagnostics(options, bodyRequestId);
      }
      _recordTimings(
        options,
        total: totalWatch.elapsed,
        cookiePrep: cookiePrepElapsed,
        jsEval: jsEvalElapsed,
        browserWait: browserWaitElapsed,
        cookieBackSync: cookieBackSyncElapsed,
      );
      rethrow;
    } finally {
      if (bodyRequestId != null) {
        unawaited(_clearRequestBody(bodyRequestId));
      }
      _activeFetches--;
      if (_activeFetches == 0 && _disposeWhenIdle) {
        close(force: false);
      }
    }
  }

  void disposeWhenIdle() {
    _disposeWhenIdle = true;
    if (_activeFetches == 0) {
      close(force: false);
    }
  }

  Future<ResponseBody> _fetchBinaryStreamResponse(
    RequestOptions options, {
    required String requestId,
    required String method,
    required String url,
    required Map<String, String> headersMap,
    required String bodyScript,
    required String? fetchCacheMode,
    required Future<void>? cancelFuture,
    required Stopwatch totalWatch,
    required Duration? cookiePrepElapsed,
  }) async {
    // 与 AndroidX 接收消息时使用同一能力判断，在建立传输前决定编码。
    final useBase64 = await _responseTransport.usesBase64();
    final bridge = await _createBinaryResponseBridge(
      options,
      requestId: requestId,
    );
    _setNetworkLogField(
      options,
      'webViewBinaryTransport',
      useBase64 ? 'base64' : 'arrayBuffer',
    );
    final senderScript = WebViewResponseCodec.buildSenderScript(
      useBase64: useBase64,
    );
    final script =
        '''
      (async function() {
        const requestId = ${jsonEncode(requestId)};
        let responsePort = null;
        try {
          responsePort = await window.__fluxdoTakeBinaryResponsePort(requestId);

          window.__fluxdoFetchAborters = window.__fluxdoFetchAborters || {};
          window.__fluxdoAbortFetch = window.__fluxdoAbortFetch || function(id) {
            const controller = window.__fluxdoFetchAborters && window.__fluxdoFetchAborters[id];
            if (controller) {
              controller.abort();
              delete window.__fluxdoFetchAborters[id];
            }
          };

          const controller = new AbortController();
          window.__fluxdoFetchAborters[requestId] = controller;

          const fetchOptions = {
            method: ${jsonEncode(method)},
            headers: ${jsonEncode(headersMap)},
            credentials: 'include',
            signal: controller.signal${fetchCacheMode != null ? ",\n            cache: ${jsonEncode(fetchCacheMode)}" : ''}
          };
          $bodyScript

          const response = await fetch(${jsonEncode(url)}, fetchOptions);
          const headersObj = {};
          response.headers.forEach((v, k) => headersObj[k] = v);

          responsePort.postMessage(JSON.stringify({
            kind: 'headers',
            requestId: requestId,
            status: response.status,
            statusText: response.statusText,
            headers: headersObj
          }));

          $senderScript

          if (response.body && response.body.getReader) {
            const reader = response.body.getReader();
            while (true) {
              const chunk = await reader.read();
              if (chunk.done) break;
              const value = chunk.value;
              if (!value || value.byteLength === 0) continue;
              let buffer = value.buffer;
              if (value.byteOffset !== 0 || value.byteLength !== buffer.byteLength) {
                buffer = value.slice().buffer;
              } else {
                buffer = buffer.slice(0);
              }
              sendBuffer(buffer);
            }
          } else {
            sendBuffer(await response.arrayBuffer());
          }

          responsePort.postMessage(JSON.stringify({
            kind: 'complete',
            requestId: requestId
          }));
        } catch (e) {
          const payload = JSON.stringify({
            kind: 'error',
            requestId: requestId,
            error: e && e.name === 'AbortError'
              ? 'WebView request canceled'
              : String(e)
          });
          if (responsePort) {
            responsePort.postMessage(payload);
          } else {
            window.flutter_inappwebview.callHandler('fetchResult', {
              requestId: requestId,
              result: JSON.stringify({ok: false, error: String(e)})
            });
          }
        } finally {
          if (window.__fluxdoFetchAborters) {
            delete window.__fluxdoFetchAborters[requestId];
          }
        }
      })();
    ''';

    debugPrint(
      '[WebViewAdapter] Fetching binary stream: $method $url (id: $requestId)',
    );

    final cancelFutureForRequest = cancelFuture;
    if (cancelFutureForRequest != null) {
      unawaited(
        cancelFutureForRequest.then<void>((_) async {
          bridge.completeError(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
              error: 'WebView request canceled',
            ),
          );
          await _abortWebViewFetch(requestId);
        }, onError: (_) {}),
      );
    }

    final headerWatch = Stopwatch()..start();
    Duration? jsEvalElapsed;
    try {
      final jsEvalWatch = Stopwatch()..start();
      await _controller!.evaluateJavascript(source: script);
      jsEvalWatch.stop();
      jsEvalElapsed = jsEvalWatch.elapsed;
    } catch (e) {
      bridge.completeError(e);
      rethrow;
    }

    final timeout =
        options.receiveTimeout ??
        options.connectTimeout ??
        const Duration(seconds: 30);
    final headers = await bridge.headersCompleter.future.timeout(
      timeout,
      onTimeout: () {
        unawaited(_abortWebViewFetch(requestId));
        final error = DioException(
          requestOptions: options,
          error: 'WebView binary response header timeout',
          type: DioExceptionType.receiveTimeout,
        );
        bridge.completeError(error);
        throw error;
      },
    );
    headerWatch.stop();
    totalWatch.stop();

    _recordTimings(
      options,
      total: totalWatch.elapsed,
      cookiePrep: cookiePrepElapsed,
      jsEval: jsEvalElapsed,
      browserWait: headerWatch.elapsed,
    );
    _setNetworkLogField(options, 'webViewBinaryStream', true);

    bridge.done.whenComplete(() {
      _setNetworkLogField(options, 'webViewBinaryBytes', bridge.bytesReceived);
      _setNetworkLogField(
        options,
        'webViewBinaryChunks',
        bridge.chunksReceived,
      );
      debugPrint(
        '[WebViewAdapter] Binary stream complete: '
        '$method $url (id: $requestId, status=${headers.statusCode}, '
        'bytes=${bridge.bytesReceived}, chunks=${bridge.chunksReceived})',
      );
    });

    return ResponseBody(
      bridge.stream,
      headers.statusCode,
      headers: headers.headers,
      statusMessage: headers.statusMessage,
    );
  }

  Future<WebViewBinaryResponseBridge> _createBinaryResponseBridge(
    RequestOptions options, {
    required String requestId,
  }) async {
    final controller = _controller;
    if (controller == null) {
      throw DioException(
        requestOptions: options,
        error: 'WebView controller not available',
        type: DioExceptionType.unknown,
      );
    }

    await _installBinaryResponseBridge(controller);

    final channel = await controller.createWebMessageChannel();
    if (channel == null) {
      throw DioException(
        requestOptions: options,
        error: 'WebView binary response channel unavailable',
        type: DioExceptionType.unknown,
      );
    }

    late final WebViewBinaryResponseBridge bridge;
    bridge = WebViewBinaryResponseBridge(
      requestOptions: options,
      channel: channel,
      onCancel: () async {
        await _abortWebViewFetch(requestId);
      },
    );

    final readyCompleter = Completer<void>();
    try {
      final port = channel.port1;
      await port.setWebMessageCallback((message) async {
        final payload = message?.data;
        final bytes = _binaryMessageBytes(payload);
        if (bytes != null) {
          bridge.addBytes(bytes);
          return;
        }

        if (payload is! String || payload.isEmpty) {
          return;
        }
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map) return;
          final kind = decoded['kind']?.toString();
          if (kind == 'chunk') {
            bridge.addBytes(WebViewResponseCodec.decodeChunk(decoded)!);
          } else if (kind == 'ready') {
            if (!readyCompleter.isCompleted) readyCompleter.complete();
          } else if (kind == 'headers') {
            bridge.completeHeaders(
              WebViewBinaryResponseHeaders.fromJson(decoded),
            );
          } else if (kind == 'complete') {
            bridge.complete();
          } else if (kind == 'error') {
            bridge.completeError(
              DioException(
                requestOptions: options,
                type: DioExceptionType.unknown,
                error: decoded['error']?.toString() ?? 'WebView binary error',
              ),
            );
          }
        } catch (e) {
          bridge.completeError(e);
        }
      });

      await controller.postWebMessage(
        message: WebMessage(
          data: '__fluxdo:binary-response:$requestId',
          ports: [channel.port2],
        ),
        targetOrigin: WebUri(Uri.parse(AppConstants.baseUrl).origin),
      );

      await readyCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          bridge.completeError(
            TimeoutException(
              'WebView binary response port setup timeout for $requestId',
            ),
          );
          throw TimeoutException(
            'WebView binary response port setup timeout for $requestId',
          );
        },
      );

      return bridge;
    } catch (e) {
      bridge.completeError(e);
      rethrow;
    }
  }

  Future<void> _installBinaryResponseBridge(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source: '''
        (function() {
          if (window.__fluxdoBinaryResponseBridgeInstalled) return;
          window.__fluxdoBinaryResponseBridgeInstalled = true;
          window.__fluxdoBinaryResponsePorts = new Map();
          window.__fluxdoBinaryResponseWaiters = new Map();

          window.__fluxdoTakeBinaryResponsePort = function(requestId) {
            var existing = window.__fluxdoBinaryResponsePorts.get(requestId);
            if (existing) {
              window.__fluxdoBinaryResponsePorts.delete(requestId);
              return Promise.resolve(existing);
            }
            return new Promise(function(resolve, reject) {
              var timer = setTimeout(function() {
                window.__fluxdoBinaryResponseWaiters.delete(requestId);
                reject(new Error('Binary response port timeout for ' + requestId));
              }, 5000);
              window.__fluxdoBinaryResponseWaiters.set(requestId, function(port) {
                clearTimeout(timer);
                resolve(port);
              });
            });
          };

          window.addEventListener('message', function(event) {
            if (typeof event.data !== 'string' ||
                !event.data.startsWith('__fluxdo:binary-response:')) {
              return;
            }

            var requestId = event.data.substring('__fluxdo:binary-response:'.length);
            var port = event.ports && event.ports[0];
            if (!port) return;
            if (port.start) port.start();

            var waiter = window.__fluxdoBinaryResponseWaiters.get(requestId);
            if (waiter) {
              window.__fluxdoBinaryResponseWaiters.delete(requestId);
              waiter(port);
            } else {
              window.__fluxdoBinaryResponsePorts.set(requestId, port);
            }
            port.postMessage(JSON.stringify({ kind: 'ready', requestId: requestId }));
          });
        })();
      ''',
    );
  }

  Uint8List? _binaryMessageBytes(Object? payload) {
    if (payload is Uint8List) {
      return payload;
    }
    if (payload is ByteBuffer) {
      return payload.asUint8List();
    }
    if (payload is List<int>) {
      return Uint8List.fromList(payload);
    }
    return null;
  }

  void _recordTimings(
    RequestOptions options, {
    required Duration total,
    Duration? cookiePrep,
    Duration? jsEval,
    Duration? browserWait,
    Duration? cookieBackSync,
  }) {
    _setNetworkLogField(options, 'webViewTotalMs', total.inMilliseconds);
    if (cookiePrep != null) {
      _setNetworkLogField(
        options,
        'webViewCookiePrepMs',
        cookiePrep.inMilliseconds,
      );
    }
    if (jsEval != null) {
      _setNetworkLogField(options, 'webViewJsEvalMs', jsEval.inMilliseconds);
    }
    if (browserWait != null) {
      _setNetworkLogField(
        options,
        'webViewBrowserWaitMs',
        browserWait.inMilliseconds,
      );
    }
    if (cookieBackSync != null) {
      _setNetworkLogField(
        options,
        'webViewCookieBackSyncMs',
        cookieBackSync.inMilliseconds,
      );
    }
  }

  @override
  void close({bool force = false}) {
    if (!force && _activeFetches > 0) {
      _disposeWhenIdle = true;
      return;
    }
    if (_headlessWebView != null) {
      FrameJankMonitor.logEvent('WEBVIEW', 'HttpAdapter dispose');
    }
    _headlessWebView?.dispose();
    _headlessWebView = null;
    _controller = null;
    _isInitialized = false;
    _disposeWhenIdle = false;
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      _initCompleter!.completeError(StateError('WebView adapter closed'));
    }
    _initCompleter = null;
    _activeCriticalCookieSync = null;
    _lastCriticalCookieSyncAt = null;
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
            error: 'WebView adapter closed',
          ),
        );
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

  _WebViewCookieMode _resolveCookieMode(
    RequestOptions options,
    bool shouldSyncAppCookies,
  ) {
    final explicitMode = options.extra[cookieModeExtraKey]?.toString();
    if (explicitMode == cookieModeNone) {
      return _WebViewCookieMode.none;
    }
    if (explicitMode == cookieModeReadOnly) {
      return shouldSyncAppCookies
          ? _WebViewCookieMode.readOnly
          : _WebViewCookieMode.none;
    }
    return shouldSyncAppCookies
        ? _WebViewCookieMode.sync
        : _WebViewCookieMode.none;
  }

  bool _trustsWebViewSessionFromResponse(
    RequestOptions options,
    int statusCode,
    Map<String, List<String>> responseHeaders,
  ) {
    if (statusCode < 200 || statusCode >= 400) return false;
    if (!_hasRequestHeaderValue(
      options.headers,
      'Discourse-Logged-In',
      'true',
    )) {
      return false;
    }
    return !_hasNonEmptyResponseHeader(responseHeaders, 'discourse-logged-out');
  }

  bool _hasRequestHeaderValue(
    Map<String, dynamic> headers,
    String name,
    String expectedValue,
  ) {
    final normalized = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != normalized) continue;
      return entry.value?.toString().toLowerCase() ==
          expectedValue.toLowerCase();
    }
    return false;
  }

  bool _hasNonEmptyResponseHeader(
    Map<String, List<String>> responseHeaders,
    String name,
  ) {
    final normalized = name.toLowerCase();
    for (final entry in responseHeaders.entries) {
      if (entry.key.toLowerCase() != normalized) continue;
      return entry.value.any((value) => value.trim().isNotEmpty);
    }
    return false;
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
          await cookieManager.setCookie(url: webUri, name: name, value: value);
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
    required WebViewOperationGuard guard,
  }) async {
    if (method == 'GET' || method == 'HEAD') {
      return const _RequestBodyPlan(script: '');
    }

    final directBodyScript = await _buildDirectBodyScript(options);
    if (directBodyScript != null) {
      return _RequestBodyPlan(script: directBodyScript);
    }

    final streamedBodyScript = await _buildStreamedBodyScript(
      options,
      requestStream,
      requestId: requestId,
      requestUri: requestUri,
      guard: guard,
    );
    if (streamedBodyScript != null) {
      return _RequestBodyPlan(script: streamedBodyScript);
    }

    final requestBytes = await _readRequestBytes(requestStream, guard);
    if (requestBytes != null && requestBytes.isNotEmpty) {
      final bodyBase64 = base64Encode(requestBytes);
      return _RequestBodyPlan(
        script:
            '''
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
    RequestOptions options,
    Stream<Uint8List>? requestStream, {
    required String requestId,
    required Uri requestUri,
    required WebViewOperationGuard guard,
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
      await guard.run(() => _installRequestBodyBridge(controller));

      channel = await guard.run(() async {
        final created = await controller.createWebMessageChannel();
        if (guard.isStopped) {
          if (created != null) _disposeMessageChannel(created);
        }
        channel = created;
        return created;
      });
      if (channel == null) {
        return null;
      }

      final port = channel!.port1;
      final readyCompleter = Completer<void>();
      final completeCompleter = Completer<void>();
      final errorCompleter = Completer<String>();

      await guard.run(
        () => port.setWebMessageCallback((message) async {
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
              final error = decoded['error']?.toString() ?? 'unknown';
              errorCompleter.complete(error);
              guard.stop(StateError(error));
            }
          } catch (_) {}
        }),
      );

      final origin = requestUri.origin;
      await guard.run(
        () => controller.postWebMessage(
          message: WebMessage(
            data: '__fluxdo:body:$requestId',
            ports: [channel!.port2],
          ),
          targetOrigin: WebUri(origin),
        ),
      );

      await guard.run(
        () => _awaitRequestBodyPortReady(
          readyCompleter,
          errorCompleter,
          requestId: requestId,
        ),
      );

      // 上传与下载复用同一原生能力查询，必须在消费流之前决定编码。
      final useBase64 = await guard.run(_responseTransport.usesBase64);
      _setNetworkLogField(
        options,
        'webViewUploadTransport',
        useBase64 ? 'base64' : 'arrayBuffer',
      );
      _setNetworkLogField(options, 'webViewUploadPhase', 'transfer');
      transferStarted = true;
      await WebViewRequestCodec.pipe(
        requestStream,
        useBase64: useBase64,
        guard: guard,
        send: (payload) => port.postMessage(
          WebMessage(
            data: payload,
            type: payload is String
                ? WebMessageType.STRING
                : WebMessageType.ARRAY_BUFFER,
          ),
        ),
      );

      await guard.run(
        () => _postRequestBodyControlMessage(port, {
          'kind': 'complete',
          'requestId': requestId,
        }),
      );

      await guard.run(
        () => _awaitRequestBodyTransferComplete(
          completeCompleter,
          errorCompleter,
          requestId: requestId,
        ),
      );

      _setNetworkLogField(options, 'webViewUploadPhase', 'complete');
      return 'fetchOptions.body = window.__fluxdoTakeRequestBody(${jsonEncode(requestId)});';
    } catch (e) {
      unawaited(_clearRequestBody(requestId));
      _setNetworkLogField(
        options,
        'webViewUploadPhase',
        transferStarted ? 'transfer_failed' : 'bridge_fallback',
      );
      _setNetworkLogField(
        options,
        'webViewUploadErrorType',
        e.runtimeType.toString(),
      );
      if (e is DioException &&
          (e.type == DioExceptionType.cancel ||
              e.type == DioExceptionType.sendTimeout)) {
        rethrow;
      }
      if (!transferStarted) {
        debugPrint(
          '[WebViewAdapter] Stream bridge unavailable, fallback to base64: $e',
        );
        return null;
      }
      rethrow;
    } finally {
      if (channel != null) _disposeMessageChannel(channel!);
    }
  }

  /// 页面内保存有限诊断字段；不依赖可能失效的 fetchResult 桥回传。
  @visibleForTesting
  static String buildUploadDiagnosticsScript(String requestId) =>
      '''
    window.__fluxdoUploadDiagnostics = window.__fluxdoUploadDiagnostics || {};
    const uploadDiagnostic = {phase: 'script_started'};
    window.__fluxdoUploadDiagnostics[${jsonEncode(requestId)}] = uploadDiagnostic;
    const uploadTrace = function(phase, value) {
      uploadDiagnostic.phase = phase;
      if (phase === 'fetch_started' && typeof value === 'number') {
        uploadDiagnostic.bodyBytes = value;
      }
      if (phase === 'response_headers') uploadDiagnostic.status = value;
    };
  ''';

  Future<void> _collectUploadDiagnostics(
    RequestOptions options,
    String requestId,
  ) async {
    try {
      final raw = await _controller
          ?.evaluateJavascript(
            source:
                'JSON.stringify(window.__fluxdoUploadDiagnostics && '
                'window.__fluxdoUploadDiagnostics[${jsonEncode(requestId)}] || null)',
          )
          .timeout(const Duration(seconds: 1));
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return;
      final phase = decoded['phase'];
      if (phase is String &&
          const {
            'script_started',
            'fetch_started',
            'response_headers',
            'response_body',
            'result_dispatch',
            'javascript_error',
            'result_bridge_error',
          }.contains(phase)) {
        _setNetworkLogField(options, 'webViewFetchPhase', phase);
      }
      for (final field in ['bodyBytes', 'status']) {
        final value = decoded[field];
        if (value is num) {
          _setNetworkLogField(
            options,
            field == 'status' ? 'webViewResponseStatus' : 'webViewUploadBytes',
            value,
          );
        }
      }
    } catch (_) {
      _setNetworkLogField(options, 'webViewDiagnosticsUnavailable', true);
    }
  }

  Future<void> _clearRequestBody(String requestId) async {
    try {
      await _controller?.evaluateJavascript(
        source:
            'window.__fluxdoDiscardRequestBody && window.__fluxdoDiscardRequestBody(${jsonEncode(requestId)});'
            'if (window.__fluxdoUploadDiagnostics) delete window.__fluxdoUploadDiagnostics[${jsonEncode(requestId)}];',
      );
    } catch (_) {
      // WebView 销毁时页面内存已释放，清理异常不能覆盖原请求错误。
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
      source:
          '''
        (function() {
          if (window.__fluxdoRequestBodyBridgeInstalled) return;
          window.__fluxdoRequestBodyBridgeInstalled = true;
          window.__fluxdoRequestBodyTransfers = new Map();

          window.__fluxdoDiscardRequestBody = function(requestId) {
            var state = window.__fluxdoRequestBodyTransfers.get(requestId);
            if (!state) return;
            state.discarded = true;
            state.chunks = [];
            state.body = null;
            if (state.port) state.port.close();
            window.__fluxdoRequestBodyTransfers.delete(requestId);
          };

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
            state.port = port;

            port.onmessage = function(portEvent) {
              try {
                if (state.discarded) return;
                var payload = portEvent.data;
                if (typeof payload === 'string') {
                  var message = JSON.parse(payload);
                  switch (message.kind) {
                    ${WebViewRequestCodec.receiverScript}
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
                state.chunks = [];
                state.body = null;
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

  @visibleForTesting
  static String? resolveFetchCacheMode(RequestOptions options) {
    final requestedMode = options.extra[fetchCacheModeExtraKey]
        ?.toString()
        .trim()
        .toLowerCase();
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

  Future<Uint8List?> _readRequestBytes(
    Stream<Uint8List>? requestStream,
    WebViewOperationGuard guard,
  ) async {
    if (requestStream == null) return null;

    final builder = BytesBuilder(copy: false);
    await WebViewRequestCodec.pipe(
      requestStream,
      useBase64: false,
      guard: guard,
      send: (payload) async {
        builder.add(payload as Uint8List);
      },
    );
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
      final headerValue = _headerValueToString(value);
      if (headerValue == null || headerValue.isEmpty) {
        return;
      }
      headersMap[key] = headerValue;
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

  String? _headerValueToString(Object? value) {
    if (value == null) return null;
    if (value is Iterable) {
      return value
          .where((e) => e != null)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .join(', ');
    }
    return value.toString().trim();
  }

  void _setNetworkLogField(RequestOptions options, String key, Object? value) =>
      setNetworkLogField(options, key, value);

  @visibleForTesting
  static void setNetworkLogField(
    RequestOptions options,
    String key,
    Object? value,
  ) {
    final currentFields = options.extra['_networkLogFields'];
    // Map<String, String> 也能通过 Map<String, dynamic> 类型检查，但
    // 写入整数会抛 TypeError；调用方还可能传只读映射，统一复制后追加。
    final mergedFields = <String, dynamic>{};
    if (currentFields is Map) {
      currentFields.forEach((fieldKey, fieldValue) {
        if (fieldKey is String) {
          mergedFields[fieldKey] = fieldValue;
        }
      });
    }
    mergedFields[key] = value;
    options.extra['_networkLogFields'] = mergedFields;
  }

  CookieManager _resolveCookieManager() {
    return Platform.isWindows
        ? WindowsWebViewEnvironmentService.instance.cookieManager
        : CookieManager.instance();
  }

  Future<void> _abortWebViewFetch(String requestId) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(
        source:
            'if (window.__fluxdoAbortFetch) window.__fluxdoAbortFetch(${jsonEncode(requestId)});',
      );
    } catch (e) {
      debugPrint('[WebViewAdapter] Abort fetch failed: $e');
    }
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
    Set<String>? excludeCookieNames,
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
      if (!force) return;
    }

    final future = BoundarySyncService.instance.syncFromWebView(
      currentUrl: currentUrl,
      controller: controller,
      cookieNames: CookieJarService.criticalCookieNames,
      excludeCookieNames: excludeCookieNames,
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

enum _WebViewCookieMode { sync, readOnly, none }

class WebViewBinaryResponseHeaders {
  const WebViewBinaryResponseHeaders({
    required this.statusCode,
    required this.headers,
    this.statusMessage,
  });

  factory WebViewBinaryResponseHeaders.fromJson(Map<dynamic, dynamic> json) {
    final headers = <String, List<String>>{};
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers[key.toString()] = [value.toString()];
      });
    }
    return WebViewBinaryResponseHeaders(
      statusCode: json['status'] as int? ?? 200,
      statusMessage: json['statusText']?.toString(),
      headers: headers,
    );
  }

  final int statusCode;
  final String? statusMessage;
  final Map<String, List<String>> headers;
}

/// 原生端口与 Dart MethodChannel 需要分别释放；清理不能阻塞请求结束。
void _disposeMessageChannel(WebMessageChannel channel) {
  for (final port in [channel.port1, channel.port2]) {
    unawaited(
      port
          .close()
          .timeout(const Duration(seconds: 1))
          .catchError((Object _) {}),
    );
  }
  channel.dispose();
}

@visibleForTesting
class WebViewBinaryResponseBridge {
  WebViewBinaryResponseBridge({
    required this.requestOptions,
    required this.channel,
    required Future<void> Function() onCancel,
  }) : _streamController = StreamController<Uint8List>() {
    // 提前挂错误观察者，但保留原 Future 的错误供调用方 await。
    unawaited(
      headersCompleter.future.then<void>((_) {}, onError: (Object _) {}),
    );
    _streamController.onCancel = () async {
      if (_closed) return;
      complete();
      await onCancel();
    };
  }

  final RequestOptions requestOptions;
  final WebMessageChannel channel;
  final StreamController<Uint8List> _streamController;
  final headersCompleter = Completer<WebViewBinaryResponseHeaders>();
  final _doneCompleter = Completer<void>();

  int bytesReceived = 0;
  int chunksReceived = 0;
  bool _closed = false;

  Stream<Uint8List> get stream => _streamController.stream;
  Future<void> get done => _doneCompleter.future;

  void completeHeaders(WebViewBinaryResponseHeaders headers) {
    if (!headersCompleter.isCompleted) {
      headersCompleter.complete(headers);
    }
  }

  void addBytes(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    bytesReceived += bytes.length;
    chunksReceived++;
    _streamController.add(bytes);
  }

  void complete() {
    if (_closed) return;
    _closed = true;
    _streamController.close();
    _disposeMessageChannel(channel);
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  void completeError(Object error) {
    if (!headersCompleter.isCompleted) {
      headersCompleter.completeError(error);
    }
    if (!_closed) {
      _closed = true;
      _streamController.addError(error);
      _streamController.close();
      _disposeMessageChannel(channel);
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}
