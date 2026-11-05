import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'config/site_customization.dart';
import 'config/sites/linuxdo.dart';
import 'services/network/client_hints.dart';
import 'services/windows_webview_environment_service.dart';

/// 应用常量
class AppConstants {
  /// 当前站点自定义配置
  static final SiteCustomization siteCustomization = linuxdoCustomization;

  /// 是否启用 WebView Cookie 同步（启动时预热 WebView）
  /// 设为 false 时，不使用 WebView 同步，Cookie 由 Dio Set-Cookie 与本地存储维护
  static const bool enableWebViewCookieSync = false;

  /// 缓存的 User-Agent
  static String? _cachedUserAgent;
  static final Completer<String> _uaCompleter = Completer<String>();
  static bool _uaInitialized = false;

  /// macOS Safari 真实版本号（从 /Applications/Safari.app 读取），
  /// 用于补齐 WKWebView 默认 UA 缺失的 `Version/x.y`。
  static String? _cachedMacSafariVersion;

  /// 与原生层通信的系统信息 channel（目前只有 macOS 用到）
  static const MethodChannel _systemInfoChannel = MethodChannel('com.fluxdo/system_info');

  /// 缓存的 Client Hints 请求头（仅安卓；iOS 的 Safari 内核不支持 Client Hints）
  static Map<String, String>? _cachedClientHints;

  /// 初始化 User-Agent（应用启动时调用一次）
  /// 获取 WebView 的真实 UA 并移除 wv 标识（解决 Google 登录问题）
  static Future<void> initUserAgent() async {
    if (_uaInitialized) return;
    _uaInitialized = true;

    if (Platform.isWindows || Platform.isLinux) {
      try {
        final runtimeUa = await _getDesktopWebViewUserAgent();
        if (runtimeUa != null && runtimeUa.isNotEmpty) {
          _cachedUserAgent = runtimeUa;
          debugPrint(
            '[AppConstants] Desktop WebView runtime UA: $_cachedUserAgent',
          );
        } else {
          _cachedUserAgent = _buildDefaultUserAgent();
          debugPrint(
            '[AppConstants] Desktop WebView runtime UA 为空，使用内置默认 UA: '
            '$_cachedUserAgent',
          );
        }
      } catch (e) {
        debugPrint('[AppConstants] 获取 Desktop WebView UA 失败: $e');
        _cachedUserAgent = _buildDefaultUserAgent();
      }
      _uaCompleter.complete(_cachedUserAgent!);
      _initClientHints();
      return;
    }

    try {
      // 移动端 / macOS 尝试获取 WebView 的真实 UA，确保 UA 与 WebView 能力匹配
      if (Platform.isMacOS) {
        // macOS WKWebView 默认 UA 缺 Version/x.y 和 Safari/，sanitize 时要补；
        // 这里先读真实 Safari 版本号缓存住。
        _cachedMacSafariVersion = await _readMacSafariVersion();
      }
      final webViewUA = await InAppWebViewController.getDefaultUserAgent();
      // 清理 UA，使其看起来像普通浏览器
      _cachedUserAgent = _sanitizeUserAgent(webViewUA);
      debugPrint('[AppConstants] WebView UA: $webViewUA');
      debugPrint('[AppConstants] Sanitized UA: $_cachedUserAgent');
    } catch (e) {
      debugPrint('[AppConstants] 获取 WebView UA 失败: $e');
      _cachedUserAgent = _buildDefaultUserAgent();
    }
    _uaCompleter.complete(_cachedUserAgent!);

    // 初始化 Client Hints（仅移动端）
    _initClientHints();
  }

  static Future<String?> _getDesktopWebViewUserAgent() async {
    if (Platform.isWindows) {
      await WindowsWebViewEnvironmentService.instance.initialize();
    }

    HeadlessInAppWebView? headlessWebView;
    final completer = Completer<String?>();

    try {
      headlessWebView = HeadlessInAppWebView(
        webViewEnvironment:
            WindowsWebViewEnvironmentService.instance.environment,
        initialData: InAppWebViewInitialData(
          data: '<!DOCTYPE html><html><head></head><body></body></html>',
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          isInspectable: false,
        ),
        onLoadStop: (controller, url) async {
          if (completer.isCompleted) return;
          try {
            final result = await controller.evaluateJavascript(
              source: 'navigator.userAgent',
            );
            completer.complete(result?.toString());
          } catch (e) {
            debugPrint(
              '[AppConstants] 读取 WebView navigator.userAgent 失败: $e',
            );
            completer.complete(null);
          }
        },
        onReceivedError: (controller, request, error) {
          if (!completer.isCompleted) {
            debugPrint(
              '[AppConstants] WebView UA 页面加载失败: ${error.description}',
            );
            completer.complete(null);
          }
        },
      );

      await headlessWebView.run();
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[AppConstants] 获取 Desktop WebView UA 超时');
          return null;
        },
      );
    } finally {
      await headlessWebView?.dispose();
    }
  }

  /// 初始化 User-Agent Client Hints 请求头
  ///
  /// 由实际发送的 UA 推导，与真实浏览器一致：只发三个低熵头，品牌与 UA 对应。
  /// iOS 的 UA 不含 Chrome 内核标识，推导结果为 null（Safari 不发 Client Hints）。
  /// 桌面端暂不发送，WebView2 的品牌列表未实测，留给网络核心按采样模板处理。
  static void _initClientHints() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _cachedClientHints = ClientHints.fromUserAgent(_cachedUserAgent!);
    debugPrint('[AppConstants] Client Hints: $_cachedClientHints');
  }

  /// 获取缓存的 Client Hints 请求头（可能为 null）
  static Map<String, String>? get clientHints => _cachedClientHints;

  /// 清理 WebView UA，使其看起来像普通浏览器，以通过 Google OAuth 检测
  ///
  /// Android: 移除 "; wv" 标识及变体
  /// iOS: 补充缺失的 Version/x.x 和 Safari/xxx 字段
  /// macOS: 移除可能的嵌入式 WebView 标记
  static String _sanitizeUserAgent(String ua) {
    var sanitized = ua;

    if (Platform.isAndroid) {
      // Android WebView UA 有两个暴露身份的特征，需要同时移除：
      // 1. "; wv" — 括号内的 WebView 标识
      // 2. "Version/4.0" — WebView 遗留的静态标识符（值永远是 4.0，
      //    真实 Chrome 不包含此 token，引擎版本在 Chrome/xxx 中）
      // 参考 DuckDuckGo Android 浏览器的做法（UserAgentProvider.kt）

      // 移除 wv 标识的各种变体
      // 常见格式: "; wv)"  ";wv)"  "; wv;"  "wv; " 等
      sanitized = sanitized.replaceAll(RegExp(r'[;\s]*\bwv\b[;\s]*(?=\))'), '');
      // 移除 "Version/x.x"（尾随空格可选，避免产生双空格）
      sanitized = sanitized.replaceAll(RegExp(r'Version/[^ ]+ *'), '');
    }

    if (Platform.isIOS && !sanitized.contains('Safari/')) {
      // iOS WKWebView UA 缺少 Version/x.x 和 Safari/xxx
      // Google 通过此特征检测 WebView 并拒绝 OAuth 登录
      //
      // WKWebView: "... (KHTML, like Gecko) Mobile/15E148"
      // Safari:    "... (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
      //
      // 真实 Safari 的 Version/ 只有 major.minor 两段，
      // 不跟 iOS 的补丁号（iOS 18_3_2 → Version/18.3）

      // 提取 iOS 主版本号和次版本号（仅取前两段）
      final versionMatch = RegExp(
        r'CPU (?:iPhone )?OS (\d+)[_\.](\d+)',
      ).firstMatch(sanitized);
      final version = versionMatch != null
          ? '${versionMatch.group(1)}.${versionMatch.group(2)}'
          : '18.0';

      // iOS Safari/ 固定为 604.1（自 iOS 11 起冻结，不随系统版本变化）
      const safariBuild = '604.1';

      // 在 Mobile/ 前插入 Version/x.x
      sanitized = sanitized.replaceFirstMapped(
        RegExp(r'Mobile/'),
        (m) => 'Version/$version ${m.group(0)}',
      );
      sanitized = '$sanitized Safari/$safariBuild';
    }

    if (Platform.isMacOS) {
      // macOS WKWebView 默认 UA 形如:
      //   "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
      // 缺少真实 Safari 那段 "Version/x.y Safari/605.1.15"，CF 会判为半截 UA → 403。
      // 这里按真实 Safari 模板补齐：Apple 自 2017 起冻结了 OS 段和 WebKit/Safari 数字，
      // 唯一会动的是 Version/，所以从本机 Safari.app 读到什么就填什么。
      sanitized = sanitized.replaceAll(RegExp(r'\s*Electron/[\d.]+'), '');
      if (!sanitized.contains('Safari/')) {
        // 从原始 UA 抓 AppleWebKit 版本号，真 Safari 里 Safari/<num> 永远等于 AppleWebKit/<num>
        final webKitMatch = RegExp(r'AppleWebKit/([^\s]+)').firstMatch(sanitized);
        final webKitVersion = webKitMatch?.group(1) ?? '605.1.15';
        final safariVersion = _cachedMacSafariVersion ?? '18.5';
        sanitized = '$sanitized Version/$safariVersion Safari/$webKitVersion';
      }
    }

    return sanitized;
  }

  /// 从原生层读取本机 Safari 的版本号 (CFBundleShortVersionString)。
  /// 用于补齐 macOS WKWebView 默认 UA 缺失的 Version/x.y 段。
  /// 读不到时返回 null，由 sanitize / fallback 处使用保守默认值。
  static Future<String?> _readMacSafariVersion() async {
    try {
      final version = await _systemInfoChannel.invokeMethod<String>('getSafariVersion');
      if (version == null || version.isEmpty) return null;
      debugPrint('[AppConstants] macOS Safari version: $version');
      return version;
    } catch (e) {
      debugPrint('[AppConstants] 读取 macOS Safari 版本失败: $e');
      return null;
    }
  }

  /// 异步获取 User-Agent
  static Future<String> getUserAgent() async {
    if (_cachedUserAgent != null) return _cachedUserAgent!;
    if (!_uaInitialized) await initUserAgent();
    return _uaCompleter.future;
  }

  /// 同步获取 User-Agent（需确保已初始化，否则返回默认值）
  static String get userAgent => _cachedUserAgent ?? _buildDefaultUserAgent();

  /// WebView 内核层面的 UA 覆写。
  ///
  /// Windows 不再强行覆写 WebView UA，让底层 WebView2
  /// 使用自己的原生默认值，避免验证页基于 UA/能力特征出现不一致。
  static String? get webViewUserAgentOverride {
    // Windows/Linux 桌面端不覆写 WebView UA，让底层引擎使用原生默认值，
    // 避免 UA 与引擎能力指纹不一致被 CF 等检测到
    if (Platform.isWindows || Platform.isLinux) {
      return null;
    }
    return userAgent;
  }

  /// 构建默认 User-Agent（降级方案）
  /// 版本号对齐 Chrome 131 (2024.11)，避免过旧被 Cloudflare 等拦截
  static String _buildDefaultUserAgent() {
    if (Platform.isAndroid) {
      return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
    }
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1';
    }
    if (Platform.isWindows) {
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
    }
    if (Platform.isMacOS) {
      // macOS 底层是 WKWebView (WebKit)，使用 Safari 风格的 UA 与引擎匹配。
      // Apple 自 2017 起冻结了 OS 段 (10_15_7) 和 WebKit/Safari 数字 (605.1.15)，
      // Version/ 跟真实 Safari 走；这里是降级路径，读不到时给一个保守值。
      final safariVersion = _cachedMacSafariVersion ?? '18.5';
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/$safariVersion '
          'Safari/605.1.15';
    }
    return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  }

  /// linux.do 域名
  static const String baseUrl = 'https://linux.do';

  /// 请求首页时是否跳过 X-CSRF-Token（用于预热）
  static const bool skipCsrfForHomeRequest = true;
}
