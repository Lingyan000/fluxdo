import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../../../l10n/s.dart';
import '../../network_logger.dart';
import '../core/net_core_http_adapter.dart';
import '../core/net_core_service.dart';
import '../flux_request_spec.dart';
import '../cookie/csrf_session_trace.dart';
import '../system_proxy_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import 'adapter_log_metadata.dart';
import 'core_fallback_service.dart';
import 'webview_http_adapter.dart';

/// 当前使用的适配器类型
enum AdapterType {
  /// 网络核心：进程内 Rust 栈，按 WebView 指纹出站（默认）
  core,

  /// Dart IO 应急路径：核心不可用时顶上，指纹差但能用
  emergency,

  /// WebView 适配器：兼容模式 / CF 恢复 / Windows 兜底
  webview,
}

/// 当前适配器生效的原因（用于 UI 解释"为什么是这个引擎"）
enum AdapterReason {
  /// 核心正常工作
  core,

  /// 核心在跑但指纹模板还没采到，暂按默认档出站
  coreWarmingUp,

  /// 核心不可用，已降级到应急路径
  fallback,

  /// 用户开启了兼容模式
  webview,
}

/// 当前生效的适配器及其原因
class EffectiveAdapter {
  const EffectiveAdapter(this.type, this.reason);

  final AdapterType type;
  final AdapterReason reason;
}

/// 全局变量：记录当前使用的适配器类型
AdapterType? _currentAdapterType;

/// 获取当前使用的适配器类型
AdapterType? getCurrentAdapterType() => _currentAdapterType;

AdapterType? tryParseAdapterType(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  for (final type in AdapterType.values) {
    if (type.name == value) {
      return type;
    }
  }
  return null;
}

/// 获取适配器类型的显示名称
String getAdapterDisplayName(AdapterType type) {
  switch (type) {
    case AdapterType.core:
      return S.current.network_adapterCore;
    case AdapterType.emergency:
      return S.current.network_adapterEmergency;
    case AdapterType.webview:
      return S.current.network_adapterWebView;
  }
}

/// 创建一个 HttpClientAdapter，用于外部服务（如 AI 请求）复用应用网络配置
HttpClientAdapter createExternalHttpAdapter() =>
    _WebViewAware(_DynamicAdapter());

/// 配置平台适配器
void configurePlatformAdapter(Dio dio, {bool preferWebViewFallback = false}) {
  if (Platform.isWindows && preferWebViewFallback) {
    configureWebViewFallbackAdapter(dio);
    return;
  }
  dio.httpClientAdapter = _WebViewAware(_DynamicAdapter());
  _currentAdapterType = resolveEffectiveAdapter().type;
}

/// 配置 WebView 适配器（仅 Windows 显式兜底）
void configureWebViewFallbackAdapter(Dio dio) {
  final adapter = WebViewHttpAdapter();
  dio.httpClientAdapter = adapter;
  _currentAdapterType = AdapterType.webview;
  adapter
      .initialize()
      .then((_) {
        NetworkLogger.log('[DIO] Windows 兜底：使用 WebView 适配器');
      })
      .catchError((e) {
        NetworkLogger.log('[DIO] WebView 适配器初始化失败: $e', level: 'error');
      });
}

/// 实时解析当前生效的适配器及原因（UI 单一数据源）。
///
/// 不依赖请求触发，读取各 service 当前状态即时推算，
/// 与 [_DynamicAdapter] 每次请求时的判断完全同源。
EffectiveAdapter resolveEffectiveAdapter() {
  if (CoreFallbackService.instance.hasFallenBack) {
    return const EffectiveAdapter(
      AdapterType.emergency,
      AdapterReason.fallback,
    );
  }
  final core = NetCoreService.instance;
  if (!core.isRunning) {
    return const EffectiveAdapter(
      AdapterType.emergency,
      AdapterReason.fallback,
    );
  }
  return EffectiveAdapter(
    AdapterType.core,
    (core.status.templateReady || core.status.templateSource == 'builtin')
        ? AdapterReason.core
        : AdapterReason.coreWarmingUp,
  );
}

/// 应急路径：Dart SDK 自带，不占体积，仅核心不可用时启用。
///
/// 跟随系统代理，与 WebView 保持同一出口（cf_clearance 绑 IP，
/// 出口不一致会导致 CF 验证无限循环）。findProxy 每个请求求值，
/// 系统代理开关变化即时生效。
HttpClientAdapter _createEmergencyAdapter() {
  NetworkLogger.log('[DIO] 网络核心不可用，启用 Dart IO 应急路径', level: 'warning');
  return IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.findProxy = (uri) {
        final proxy = SystemProxyService.instance.effectiveProxyUrl;
        if (proxy == null) return 'DIRECT';
        final parsed = Uri.tryParse(proxy);
        // dart:io HttpClient 不支持 SOCKS 代理，该场景保持直连。
        if (parsed == null || parsed.scheme.startsWith('socks'))
          return 'DIRECT';
        return 'PROXY ${parsed.host}:${parsed.port}';
      };
      return client;
    },
  );
}

/// WebView 包装：兼容模式下主域名的 API 请求改由浏览器内核代发。
class _WebViewAware implements HttpClientAdapter {
  _WebViewAware(this._inner) {
    WebViewAdapterSettingsService.instance.effectiveNotifier.addListener(
      _handleWebViewSettingChanged,
    );
  }

  final HttpClientAdapter _inner;
  WebViewHttpAdapter? _webViewAdapter;

  WebViewHttpAdapter _getWebViewAdapter() =>
      _webViewAdapter ??= WebViewHttpAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (_shouldUseWebView(options)) {
      _currentAdapterType = AdapterType.webview;
      setRequestAdapterLogName(options, AdapterType.webview.name);
      CsrfSessionTrace.captureDispatch(options, browserManaged: true);
      return _getWebViewAdapter().fetch(options, requestStream, cancelFuture);
    }
    return _inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    WebViewAdapterSettingsService.instance.effectiveNotifier.removeListener(
      _handleWebViewSettingChanged,
    );
    _webViewAdapter?.close(force: force);
    _webViewAdapter = null;
    _inner.close(force: force);
  }

  void _handleWebViewSettingChanged() {
    if (WebViewAdapterSettingsService.instance.effectiveEnabled) {
      return;
    }
    // 关闭当前调用者，已发出的请求继续持有运行时租约直到结束。
    _webViewAdapter?.close(force: false);
    _webViewAdapter = null;
  }

  bool _shouldUseWebView(RequestOptions options) {
    if (!WebViewAdapterSettingsService.instance.effectiveEnabled) {
      return false;
    }
    return requestCanUseWebViewAdapter(options);
  }
}

/// 判断请求本身是否能由 WebView 适配器承载，不考虑当前兼容模式开关。
/// 用于 CF 恢复在弹出兼容提示前确认该请求确实可以被浏览器网络栈接管。
bool requestCanUseWebViewAdapter(RequestOptions options) {
  final uri = options.uri;
  if (options.spec.skipWebViewAdapter) {
    return false;
  }
  // CF 的 /cdn-cgi/ 端点(challenge-platform 等)必须走原生栈,
  // 不能被 WebView 适配器接管。
  if (uri.path.startsWith('/cdn-cgi/')) {
    return false;
  }

  final resourceKind = options.extra[WebViewHttpAdapter.resourceKindExtraKey]
      ?.toString();
  final method = options.method.toUpperCase();
  final isBinaryResponse =
      options.responseType == ResponseType.stream ||
      options.responseType == ResponseType.bytes;

  // 当前 WebView fetch 运行在 linux.do origin；跨域图片即使浏览器能显示，
  // JS 也不能读取响应字节。图片流仅允许同源请求，其它 stream 请求
  //（MessageBus、下载等）仍不走 WebView。
  if (resourceKind == WebViewHttpAdapter.resourceKindImage) {
    return (method == 'GET' || method == 'HEAD') &&
        isBinaryResponse &&
        WebViewAdapterSettingsService.instance.canUseWebView(uri);
  }

  if (!WebViewAdapterSettingsService.instance.canUseWebView(uri)) {
    return false;
  }
  if (isBinaryResponse) {
    return false;
  }

  final accept = _requestHeaderValue(options.headers, 'Accept').toLowerCase();
  final requestedWith = _requestHeaderValue(
    options.headers,
    'X-Requested-With',
  );
  final explicitlyHtml =
      accept.contains('text/html') || accept.contains('application/xhtml+xml');
  if (explicitlyHtml) {
    return false;
  }
  final apiLikeGet =
      requestedWith == 'XMLHttpRequest' ||
      uri.path.endsWith('.json') ||
      accept.contains('application/json') ||
      accept.contains('text/javascript');
  if ((method == 'GET' || method == 'HEAD') && !apiLikeGet) {
    return false;
  }

  return method == 'GET' ||
      method == 'HEAD' ||
      method == 'POST' ||
      method == 'PUT' ||
      method == 'PATCH' ||
      method == 'DELETE';
}

String _requestHeaderValue(Map<String, dynamic> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toString().toLowerCase() == name.toLowerCase()) {
      return _requestHeaderValueToString(entry.value);
    }
  }
  return '';
}

String _requestHeaderValueToString(Object? value) {
  if (value == null) return '';
  if (value is Iterable) {
    return value
        .where((e) => e != null)
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .join(', ');
  }
  return value.toString().trim();
}

/// 在网络核心与应急路径之间按需切换。
///
/// 只有这两档：核心是常规栈，应急路径仅在核心整体不可用时顶上。
class _DynamicAdapter implements HttpClientAdapter {
  final Map<AdapterType, HttpClientAdapter> _delegates = {};
  bool _hasFallenBack = false;
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
    // 冷启动早期核心可能还在启动：等它一下，别让首批请求用应急路径的指纹撞 CF
    final core = NetCoreService.instance;
    if (!core.isRunning &&
        core.isAvailable &&
        !CoreFallbackService.instance.hasFallenBack) {
      await core.whenFirstStarted();
    }
    final desiredType = resolveEffectiveAdapter().type;
    final delegate = _ensureDelegate(desiredType);
    setRequestAdapterLogName(options, desiredType.name);
    _currentAdapterType = desiredType;
    if (desiredType != AdapterType.core)
      CsrfSessionTrace.captureDispatch(options);
    return delegate.fetch(options, requestStream, cancelFuture);
  }

  HttpClientAdapter _ensureDelegate(AdapterType desiredType) {
    final hasFallenBack = CoreFallbackService.instance.hasFallenBack;
    if (_hasFallenBack != hasFallenBack) {
      _hasFallenBack = hasFallenBack;
      // 不强杀：在途请求各自走完，核心适配器本身是无状态的
      for (final delegate in _delegates.values) {
        delegate.close(force: false);
      }
      _delegates.clear();
    }
    return _delegates.putIfAbsent(
      desiredType,
      () => switch (desiredType) {
        AdapterType.core => NetCoreHttpAdapter(),
        AdapterType.emergency => _createEmergencyAdapter(),
        AdapterType.webview => WebViewHttpAdapter(),
      },
    );
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final delegate in _delegates.values) {
      delegate.close(force: force);
    }
    _delegates.clear();
  }
}
