import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'config/site_customization.dart';
import 'config/sites/linuxdo.dart';

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

  /// 初始化 User-Agent（应用启动时调用一次）
  /// 获取 WebView 的真实 UA 并移除 wv 标识（解决 Google 登录问题）
  static Future<void> initUserAgent() async {
    if (_uaInitialized) return;
    _uaInitialized = true;

    try {
      // 所有平台都尝试获取 WebView 的真实 UA，确保 UA 与 WebView 能力匹配
      final webViewUA = await InAppWebViewController.getDefaultUserAgent();
      // 移除 "; wv)" 标识，使其看起来像普通浏览器
      _cachedUserAgent = _sanitizeUserAgent(webViewUA);
      debugPrint('[AppConstants] WebView UA: $webViewUA');
      debugPrint('[AppConstants] Sanitized UA: $_cachedUserAgent');
    } catch (e) {
      debugPrint('[AppConstants] 获取 WebView UA 失败: $e');
      // 降级到默认值
      _cachedUserAgent = _buildDefaultUserAgent();
    }
    _uaCompleter.complete(_cachedUserAgent!);
  }

  /// 去掉 WebView UA 中的 "wv" 标识
  /// Android WebView UA 通常是: "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/xxx; wv) ..."
  /// 移除 "; wv" 让它看起来像 Chrome，以通过 Google OAuth 检测
  static String _sanitizeUserAgent(String ua) {
    return ua.replaceAll(RegExp(r';\s*wv(?=\))'), '');
  }

  /// 异步获取 User-Agent
  static Future<String> getUserAgent() async {
    if (_cachedUserAgent != null) return _cachedUserAgent!;
    if (!_uaInitialized) await initUserAgent();
    return _uaCompleter.future;
  }

  /// 同步获取 User-Agent（需确保已初始化，否则返回默认值）
  static String get userAgent => _cachedUserAgent ?? _buildDefaultUserAgent();

  /// 构建默认 User-Agent（降级方案）
  static String _buildDefaultUserAgent() {
    if (Platform.isAndroid) {
      return 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
    if (Platform.isWindows) {
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }
    if (Platform.isMacOS) {
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }
    return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  }

  /// linux.do 域名
  static const String baseUrl = 'https://linux.do';

  /// LINUX DO Connect 服务
  static const String connectUrl = 'https://connect.linux.do';

  /// LINUX DO Credits 服务
  static const String creditUrl = 'https://credit.linux.do';

  /// 请求首页时是否跳过 X-CSRF-Token（用于预热）
  static const bool skipCsrfForHomeRequest = true;
}
