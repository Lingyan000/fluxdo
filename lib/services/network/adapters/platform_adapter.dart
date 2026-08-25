import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

import '../doh/network_settings_service.dart';
import '../proxy/proxy_settings_service.dart';
import '../rhttp/rhttp_settings_service.dart';
import '../system_proxy_service.dart';
import '../flux_request_spec.dart';
import '../webview/webview_adapter_settings_service.dart';
import 'adapter_log_metadata.dart';
import 'cronet_fallback_service.dart';
import 'network_http_adapter.dart';
import '../../../l10n/s.dart';
import 'rhttp_adapter.dart';
import 'webview_http_adapter.dart';

/// 当前使用的适配器类型
enum AdapterType {
  webview, // WebView 适配器（仅 Windows 显式兜底）
  native, // Native/IO 适配器（Cronet/Cupertino/Dio IO）
  network, // Network 适配器（通过代理）
  rhttp, // rhttp 引擎（Rust reqwest）
}

/// 当前适配器生效的原因（用于 UI 解释"为什么是这个引擎"）
enum AdapterReason {
  rhttp, // rhttp 已启用且满足使用条件
  gateway, // DoH 直连模式（Native + URL 改写到本地代理）
  proxy, // 本地代理（MITM）转发
  fallback, // Cronet 已降级，走备用适配器
  native, // 默认直连
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
    case AdapterType.webview:
      return S.current.network_adapterWebView;
    case AdapterType.native:
      if (Platform.isAndroid) {
        return S.current.network_adapterNativeAndroid;
      }
      if (Platform.isIOS || Platform.isMacOS) {
        return S.current.network_adapterNativeIos;
      }
      return _getDesktopIoAdapterDisplayName();
    case AdapterType.network:
      return S.current.network_adapterNetwork;
    case AdapterType.rhttp:
      return S.current.network_adapterRhttp;
  }
}

/// 创建一个 HttpClientAdapter，用于外部服务（如 AI 请求）复用应用网络配置
HttpClientAdapter createExternalHttpAdapter() {
  final settings = NetworkSettingsService.instance;
  final proxySettings = ProxySettingsService.instance;
  final fallbackService = CronetFallbackService.instance;
  final rhttpSettings = RhttpSettingsService.instance;

  final adapter = _DynamicAdapter(
    settings,
    proxySettings,
    fallbackService,
    rhttpSettings,
  );
  return _GatewayAdapterWrapper(adapter);
}

/// 配置平台适配器
void configurePlatformAdapter(Dio dio, {bool preferWebViewFallback = false}) {
  final settings = NetworkSettingsService.instance;
  final proxySettings = ProxySettingsService.instance;
  final fallbackService = CronetFallbackService.instance;
  final rhttpSettings = RhttpSettingsService.instance;

  if (Platform.isWindows && preferWebViewFallback) {
    configureWebViewFallbackAdapter(dio);
    return;
  }

  // 所有平台默认使用主链路动态适配；
  // Windows 主链路为 Dio IO 适配器，WebView 仅保留显式兜底入口。
  dio.httpClientAdapter = _DynamicAdapter(
    settings,
    proxySettings,
    fallbackService,
    rhttpSettings,
  );
  _currentAdapterType = _resolveAdapterType(
    settings,
    proxySettings,
    fallbackService,
    rhttpSettings,
  );

  // Gateway 包装：在传输层透明改写 URL 到 localhost 代理
  // 所有拦截器始终看到原始 URL，避免 cookie 域名不匹配等问题
  dio.httpClientAdapter = _GatewayAdapterWrapper(dio.httpClientAdapter);
}

/// 配置 WebView 适配器（仅 Windows 显式兜底）
void configureWebViewFallbackAdapter(Dio dio) {
  _configureWebViewAdapter(dio);
  _currentAdapterType = AdapterType.webview;
}

/// 配置 WebView 适配器
void _configureWebViewAdapter(Dio dio) {
  final adapter = WebViewHttpAdapter();
  dio.httpClientAdapter = adapter;
  adapter
      .initialize()
      .then((_) {
        debugPrint('[DIO] Using WebViewHttpAdapter as Windows fallback');
      })
      .catchError((e) {
        debugPrint('[DIO] WebViewHttpAdapter init failed: $e');
      });
}

AdapterType _resolveAdapterType(
  NetworkSettingsService settings,
  ProxySettingsService proxySettings,
  CronetFallbackService fallbackService,
  RhttpSettingsService rhttpSettings,
) {
  return _resolveEffective(
    settings,
    proxySettings,
    fallbackService,
    rhttpSettings,
  ).type;
}

AdapterType _resolveAdapterTypeForRequest(
  RequestOptions options,
  NetworkSettingsService settings,
  ProxySettingsService proxySettings,
  CronetFallbackService fallbackService,
  RhttpSettingsService rhttpSettings,
) {
  return _resolveEffective(
    settings,
    proxySettings,
    fallbackService,
    rhttpSettings,
    requestOptions: options,
  ).type;
}

/// 实时解析当前生效的适配器及原因（UI 单一数据源）。
///
/// 不依赖请求触发，读取各 service 当前状态即时推算，
/// 与 [_DynamicAdapter] 每次请求时的判断完全同源。
EffectiveAdapter resolveEffectiveAdapter() {
  return _resolveEffective(
    NetworkSettingsService.instance,
    ProxySettingsService.instance,
    CronetFallbackService.instance,
    RhttpSettingsService.instance,
  );
}

EffectiveAdapter _resolveEffective(
  NetworkSettingsService settings,
  ProxySettingsService proxySettings,
  CronetFallbackService fallbackService,
  RhttpSettingsService rhttpSettings, {
  RequestOptions? requestOptions,
}) {
  // rhttp 优先（满足条件时）
  if (rhttpSettings.shouldUseRhttp(settings.current, proxySettings.current) &&
      (requestOptions == null || requestAllowsRhttpAdapter(requestOptions))) {
    return const EffectiveAdapter(AdapterType.rhttp, AdapterReason.rhttp);
  }
  // Gateway 模式：NativeAdapter 直连 + 拦截器改写 URL 到 localhost 代理
  // 比 MITM 少一层 TLS，作为 rhttp 不可用时的次优方案
  if (settings.isGatewayMode && !fallbackService.hasFallenBack) {
    return const EffectiveAdapter(AdapterType.native, AdapterReason.gateway);
  }
  // MITM 代理模式（Cronet 降级、或 gateway 不可用时的 fallback）
  if (settings.shouldRunLocalProxy || fallbackService.hasFallenBack) {
    final reason = fallbackService.hasFallenBack
        ? AdapterReason.fallback
        : AdapterReason.proxy;
    return EffectiveAdapter(AdapterType.network, reason);
  }
  return const EffectiveAdapter(AdapterType.native, AdapterReason.native);
}

@visibleForTesting
bool requestAllowsRhttpAdapter(RequestOptions options) {
  return !options.spec.skipRhttpAdapter;
}

/// 创建当前平台对应的 NativeAdapter
HttpClientAdapter _createNativeAdapter() {
  if (Platform.isWindows) {
    debugPrint('[DIO] Dynamic adapter -> IOHttpClientAdapter');
    // 与 RhttpAdapter 一致:跟随注册表系统代理,保持与 WebView2 同一出口
    // (cf_clearance 绑 IP,出口不一致会导致 CF 验证无限循环)。
    // findProxy 每个请求求值,系统代理开关变化即时生效。
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) {
          // Gateway 模式会把 https URL 改写为明文 http 指向本地 DoH 网关
          // (127.0.0.1:port)。这类回环请求绝不能再进系统代理,否则明文
          // HTTP 会被代理直接送到 CF,触发 Always-Use-HTTPS 301 死循环。
          if (_isLoopbackHost(uri.host)) return 'DIRECT';
          final proxy = SystemProxyService.instance.effectiveProxyUrl;
          if (proxy == null) return 'DIRECT';
          final u = Uri.tryParse(proxy);
          // dart:io HttpClient 不支持 SOCKS 代理,该场景保持直连。
          if (u == null || u.scheme.startsWith('socks')) return 'DIRECT';
          return 'PROXY ${u.host}:${u.port}';
        };
        return client;
      },
    );
  }
  if (kDebugMode && (Platform.isMacOS || Platform.isIOS)) {
    // 调试模式下使用默认适配器（IOHttpClientAdapter），避免 NativeAdapter 热重启崩溃
    debugPrint('[DIO] Dynamic adapter -> IOHttpClientAdapter (debug mode)');
    return IOHttpClientAdapter();
  }
  if (Platform.isMacOS && _macOSNeedsNativeFallback) {
    // objective_c 原生库编译产物的 LC_BUILD_VERSION minos 可能与构建机器一致，
    // 在低版本 macOS 上 dlopen 时 dyld 无法处理 __DATA_CONST 段保护，
    // 触发 SIGBUS 崩溃 (KERN_PROTECTION_FAILURE in map_images_nolock)。
    // 参见 https://github.com/dart-lang/native/issues/3011
    debugPrint('[DIO] Dynamic adapter -> IOHttpClientAdapter (macOS < 14)');
    return IOHttpClientAdapter();
  }
  if (Platform.isIOS || Platform.isMacOS) {
    // Release 模式: URLSession 默认会自动管理 Cookie（httpShouldSetCookies=true），
    // 会与 AppCookieManager 拦截器冲突。禁用 URLSession 的 Cookie 自动管理。
    final config = URLSessionConfiguration.ephemeralSessionConfiguration();
    config.httpShouldSetCookies = false;
    return NativeAdapter(createCupertinoConfiguration: () => config);
  }
  return NativeAdapter();
}

/// 回环地址判定:本地网关/本地代理的请求必须直连,不跟随系统代理。
bool _isLoopbackHost(String host) {
  if (host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  return address?.isLoopback ?? false;
}

/// macOS 版本 < 14 时需要降级为 IO 适配器。
/// objective_c 框架在构建时 minos 可能被设为构建机器的 OS 版本，
/// 导致在低版本 macOS 上 dlopen 崩溃 (dart-lang/native#3011)。
final bool _macOSNeedsNativeFallback = () {
  if (!Platform.isMacOS) return false;
  try {
    // Platform.operatingSystemVersion 格式: "Version 14.5 (Build 23F79)"
    final ver = Platform.operatingSystemVersion;
    final match = RegExp(r'Version (\d+)\.').firstMatch(ver);
    if (match != null) {
      return int.parse(match.group(1)!) < 14;
    }
  } catch (_) {}
  return false;
}();

/// Gateway 适配器包装器：在传输层透明改写 URL
///
/// 将 HTTPS 请求改写为 HTTP 指向 localhost gateway 代理，
/// 消除 MITM 双重 TLS 开销。改写仅在 `fetch()` 调用期间生效，
/// 结束后立即恢复原始 URL，确保所有拦截器始终看到原始 URL。
///
/// 这解决了在拦截器链中改写 URL 导致的根本问题：
/// Cookie 管理器按 localhost 域名存取 cookie，
/// 重试拦截器拿到被改写的 localhost URL 等。
class _GatewayAdapterWrapper implements HttpClientAdapter {
  _GatewayAdapterWrapper(this._inner) {
    WebViewAdapterSettingsService.instance.effectiveNotifier.addListener(
      _handleWebViewSettingChanged,
    );
  }

  final HttpClientAdapter _inner;
  WebViewHttpAdapter? _webViewAdapter;

  WebViewHttpAdapter _getWebViewAdapter() {
    return _webViewAdapter ??= WebViewHttpAdapter();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // WebView 适配器：主域名 API 请求走 WebView 内核（真正的浏览器 TLS 指纹）
    if (_shouldUseWebView(options)) {
      return _getWebViewAdapter().fetch(options, requestStream, cancelFuture);
    }

    final settings = NetworkSettingsService.instance;
    final proxySettings = ProxySettingsService.instance;
    final rhttpSettings = RhttpSettingsService.instance;

    // rhttp 直连时保留原始 HTTPS URL；显式旁路 rhttp 的请求
    // 仍需要在 gateway 模式下改写到本地代理。
    final shouldUseRhttp =
        rhttpSettings.shouldUseRhttp(settings.current, proxySettings.current) &&
        requestAllowsRhttpAdapter(options);

    if (!shouldUseRhttp && settings.isGatewayMode) {
      final port = settings.current.proxyPort;
      final uri = options.uri;
      if (port != null && uri.scheme == 'https') {
        // 保存原始状态
        final savedBaseUrl = options.baseUrl;
        final savedPath = options.path;
        final savedHost = options.headers['Host'];

        // 改写为明文 HTTP 指向 localhost gateway
        options.headers['Host'] = uri.host;
        final gatewayUri = Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: port,
          path: uri.path,
          query: uri.query.isEmpty ? null : uri.query,
          fragment: uri.fragment.isEmpty ? null : uri.fragment,
        );
        options.baseUrl = '';
        options.path = gatewayUri.toString();

        try {
          return await _inner.fetch(options, requestStream, cancelFuture);
        } finally {
          // 恢复原始 URL，确保拦截器响应链始终看到原始域名
          options.baseUrl = savedBaseUrl;
          options.path = savedPath;
          if (savedHost != null) {
            options.headers['Host'] = savedHost;
          } else {
            options.headers.remove('Host');
          }
        }
      }
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
    _webViewAdapter?.disposeWhenIdle();
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

/// 动态适配器：每次请求时根据设置 version 变化自动切换底层适配器
///
/// Android 上在 rhttp ↔ network ↔ native（Cronet）之间切换；
/// iOS/macOS 在 rhttp ↔ network ↔ native（Cupertino）之间切换；
/// Windows 在 rhttp ↔ network ↔ native（Dio IO）之间切换。
class _DynamicAdapter implements HttpClientAdapter {
  _DynamicAdapter(
    this._settings,
    this._proxySettings,
    this._fallbackService,
    this._rhttpSettings,
  );

  final NetworkSettingsService _settings;
  final ProxySettingsService _proxySettings;
  final CronetFallbackService _fallbackService;
  final RhttpSettingsService _rhttpSettings;

  final Map<AdapterType, HttpClientAdapter> _delegates = {};
  int _settingsVersion = -1;
  int _proxyVersion = -1;
  int _rhttpVersion = -1;
  bool _hasFallenBack = false;
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (_closed) {
      throw StateError(
        "Can't establish connection after the adapter was closed.",
      );
    }
    final desiredType = _resolveAdapterTypeForRequest(
      options,
      _settings,
      _proxySettings,
      _fallbackService,
      _rhttpSettings,
    );
    final delegate = _ensureDelegate(desiredType);
    setRequestAdapterLogName(options, desiredType.name);
    _currentAdapterType = desiredType;
    return delegate.fetch(options, requestStream, cancelFuture);
  }

  HttpClientAdapter _ensureDelegate(AdapterType desiredType) {
    final settingsVersion = _settings.version;
    final proxyVersion = _proxySettings.version;
    final rhttpVersion = _rhttpSettings.version;
    final hasFallenBack = _fallbackService.hasFallenBack;

    final configChanged =
        _settingsVersion != settingsVersion ||
        _proxyVersion != proxyVersion ||
        _rhttpVersion != rhttpVersion ||
        _hasFallenBack != hasFallenBack;

    if (configChanged) {
      // 不要强杀旧 delegate，避免进行中的 Cronet/rhttp 请求触发 native 崩溃。
      for (final delegate in _delegates.values) {
        delegate.close(force: false);
      }
      _delegates.clear();
    }

    final existing = _delegates[desiredType];
    if (existing != null) {
      return existing;
    }

    final delegate = switch (desiredType) {
      AdapterType.webview => WebViewHttpAdapter(),
      AdapterType.rhttp => RhttpAdapter(_settings, _proxySettings),
      AdapterType.network => NetworkHttpAdapter(_settings, _proxySettings),
      AdapterType.native => _createNativeAdapter(),
    };

    switch (desiredType) {
      case AdapterType.webview:
        debugPrint('[DIO] Dynamic adapter -> WebViewHttpAdapter');
      case AdapterType.rhttp:
        debugPrint('[DIO] Dynamic adapter -> RhttpAdapter');
      case AdapterType.network:
        debugPrint('[DIO] Dynamic adapter -> NetworkHttpAdapter');
      case AdapterType.native:
        break;
    }

    _settingsVersion = settingsVersion;
    _proxyVersion = proxyVersion;
    _rhttpVersion = rhttpVersion;
    _hasFallenBack = hasFallenBack;
    _delegates[desiredType] = delegate;
    return delegate;
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

String _getDesktopIoAdapterDisplayName() {
  final localeName = S.current.localeName.toLowerCase();
  if (localeName.startsWith('zh_hk')) {
    return 'Dio IO 適配器';
  }
  if (localeName.startsWith('zh_tw')) {
    return 'Dio IO 介面卡';
  }
  if (localeName.startsWith('zh')) {
    return 'Dio IO 适配器';
  }
  return 'Dio IO adapter';
}
