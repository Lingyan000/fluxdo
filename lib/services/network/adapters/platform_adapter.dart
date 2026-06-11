import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

import '../doh/network_settings_service.dart';
import '../proxy/proxy_settings_service.dart';
import '../rhttp/rhttp_settings_service.dart';
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

/// 配置稳定的 NativeAdapter,绕过 _DynamicAdapter 的 rhttp/proxy 切换。
///
/// 适用于 long polling 等长期运行的场景:
/// - iOS/macOS 走 URLSession,享受系统级后台 suspend 和 radio coalescing,
///   功耗显著低于 rhttp 的用户态 reqwest。
/// - 不参与 rhttp/proxy 设置版本号轮换,连接复用更稳定。
///
/// 仍走 [_GatewayAdapterWrapper] 包装,以保持 gateway 模式下的 URL 改写一致。
void configureStableNativeAdapter(Dio dio) {
  final adapter = _GatewayAdapterWrapper(_createNativeAdapter());
  dio.httpClientAdapter = adapter;
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
  // rhttp 优先（满足条件时）
  if (rhttpSettings.shouldUseRhttp(settings.current, proxySettings.current)) {
    return AdapterType.rhttp;
  }
  // Gateway 模式：NativeAdapter 直连 + 拦截器改写 URL 到 localhost 代理
  // 比 MITM 少一层 TLS，作为 rhttp 不可用时的次优方案
  if (settings.isGatewayMode && !fallbackService.hasFallenBack) {
    return AdapterType.native;
  }
  // MITM 代理模式（Cronet 降级、或 gateway 不可用时的 fallback）
  if (settings.shouldRunLocalProxy || fallbackService.hasFallenBack) {
    return AdapterType.network;
  }
  return AdapterType.native;
}

/// 创建当前平台对应的 NativeAdapter
HttpClientAdapter _createNativeAdapter() {
  if (Platform.isWindows) {
    debugPrint('[DIO] Dynamic adapter -> IOHttpClientAdapter');
    return IOHttpClientAdapter();
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
  _GatewayAdapterWrapper(this._inner);

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
    final currentAdapter = getCurrentAdapterType();

    // rhttp 直连时保留原始 HTTPS URL
    final shouldUseRhttp =
        currentAdapter == AdapterType.rhttp ||
        rhttpSettings.shouldUseRhttp(settings.current, proxySettings.current);

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
    _webViewAdapter?.close(force: force);
    _webViewAdapter = null;
    _inner.close(force: force);
  }

  bool _shouldUseWebView(RequestOptions options) {
    final uri = options.uri;
    if (!WebViewAdapterSettingsService.instance.shouldUseWebView(uri)) {
      return false;
    }
    if (options.extra['skipWebViewAdapter'] == true) {
      return false;
    }
    if (options.extra['isCfChallengePlatform'] == true ||
        uri.path.startsWith('/cdn-cgi/')) {
      return false;
    }
    if (options.responseType == ResponseType.stream ||
        options.responseType == ResponseType.bytes) {
      return false;
    }

    final method = options.method.toUpperCase();
    final accept = _headerValue(options.headers, 'Accept').toLowerCase();
    final requestedWith = _headerValue(options.headers, 'X-Requested-With');
    final explicitlyHtml =
        accept.contains('text/html') ||
        accept.contains('application/xhtml+xml');
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

  String _headerValue(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toString().toLowerCase() == name.toLowerCase()) {
        return entry.value?.toString() ?? '';
      }
    }
    return '';
  }
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

  HttpClientAdapter? _delegate;
  AdapterType? _delegateType;
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
    final delegate = _ensureDelegate();
    final delegateType = _delegateType;
    if (delegateType != null) {
      setRequestAdapterLogName(options, delegateType.name);
    }
    return delegate.fetch(options, requestStream, cancelFuture);
  }

  HttpClientAdapter _ensureDelegate() {
    final desiredType = _resolveAdapterType(
      _settings,
      _proxySettings,
      _fallbackService,
      _rhttpSettings,
    );
    final settingsVersion = _settings.version;
    final proxyVersion = _proxySettings.version;
    final rhttpVersion = _rhttpSettings.version;
    final hasFallenBack = _fallbackService.hasFallenBack;

    final shouldRebuild =
        _delegate == null ||
        _delegateType != desiredType ||
        _settingsVersion != settingsVersion ||
        _proxyVersion != proxyVersion ||
        _rhttpVersion != rhttpVersion ||
        _hasFallenBack != hasFallenBack;

    if (!shouldRebuild) {
      return _delegate!;
    }

    // 不要强杀旧 delegate，避免进行中的 Cronet 请求触发 native 崩溃。
    _delegate?.close(force: false);
    if (desiredType == AdapterType.rhttp) {
      _delegate = RhttpAdapter(_settings, _proxySettings);
      debugPrint('[DIO] Dynamic adapter -> RhttpAdapter');
    } else if (desiredType == AdapterType.network) {
      _delegate = NetworkHttpAdapter(_settings, _proxySettings);
      debugPrint('[DIO] Dynamic adapter -> NetworkHttpAdapter');
    } else {
      _delegate = _createNativeAdapter();
    }

    _delegateType = desiredType;
    _settingsVersion = settingsVersion;
    _proxyVersion = proxyVersion;
    _rhttpVersion = rhttpVersion;
    _hasFallenBack = hasFallenBack;
    _currentAdapterType = desiredType;
    return _delegate!;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _delegate?.close(force: force);
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
