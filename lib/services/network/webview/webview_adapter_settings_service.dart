import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';

/// WebView 适配器设置服务
///
/// 开启后，主站 API 请求通过 WebView 内核发送（真正的 Chrome TLS 指纹），
/// 可改善因 TLS 指纹被 Cloudflare 识别为非浏览器客户端导致的登录失效问题。
///
/// 仅对主域名的 API 请求生效，排除：
/// - CDN 图片请求（cdn.linux.do 等子域名）
/// - MessageBus 长轮询（/message-bus/ 路径）
class WebViewAdapterSettingsService {
  WebViewAdapterSettingsService._internal();

  static final WebViewAdapterSettingsService instance =
      WebViewAdapterSettingsService._internal();

  static const _enabledKey = 'webview_adapter_enabled';

  /// 用户持久化的兼容模式开关。
  ///
  /// 设置页只监听这个 notifier，避免把 CF 恢复流程启用的临时兼容模式
  /// 误显示成用户主动修改的永久设置。
  final ValueNotifier<bool> notifier = ValueNotifier(false);

  /// 当前会话的临时兼容模式开关，不写入 SharedPreferences。
  final ValueNotifier<bool> sessionFallbackNotifier = ValueNotifier(false);

  /// 实际用于请求分流的开关。
  ///
  /// 持久化兼容模式或会话临时兼容模式任一开启时均为 true。
  final ValueNotifier<bool> effectiveNotifier = ValueNotifier(false);

  SharedPreferences? _prefs;

  /// 用户持久化设置是否开启。
  bool get enabled => notifier.value;

  bool get persistentEnabled => notifier.value;

  /// 当前会话是否因 CF 恢复流程临时启用了兼容模式。
  bool get sessionFallbackEnabled => sessionFallbackNotifier.value;

  /// 当前请求是否应允许使用 WebView 适配器。
  bool get effectiveEnabled => effectiveNotifier.value;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    notifier.value = prefs.getBool(_enabledKey) ?? false;
    _syncEffectiveEnabled();
  }

  Future<void> setEnabled(bool value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = value;
    _syncEffectiveEnabled();
    await prefs.setBool(_enabledKey, value);
  }

  /// 仅在当前应用会话启用临时兼容模式。
  void enableSessionFallback() {
    _setSessionFallbackEnabled(true);
  }

  /// 退出当前会话的临时兼容模式。
  void disableSessionFallback() {
    _setSessionFallbackEnabled(false);
  }

  /// 在登录会话结束时清除临时兼容状态。
  ///
  /// 该操作不会修改用户持久化的兼容模式设置。
  void resetSessionFallback() {
    _setSessionFallbackEnabled(false);
  }

  /// 判断请求是否应走 WebView 适配器
  bool shouldUseWebView(Uri uri) {
    if (!effectiveEnabled) return false;
    return canUseWebView(uri);
  }

  /// 判断目标地址是否属于 WebView 适配器可覆盖的范围，不考虑当前是否启用。
  bool canUseWebView(Uri uri) {
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    // 仅主域名（排除 CDN、ping 等子域名）
    if (uri.host != baseHost) return false;
    // 排除 MessageBus 长轮询
    if (uri.path.startsWith('/message-bus/')) return false;
    return true;
  }

  void _setSessionFallbackEnabled(bool value) {
    if (sessionFallbackNotifier.value == value) return;
    sessionFallbackNotifier.value = value;
    _syncEffectiveEnabled();
  }

  void _syncEffectiveEnabled() {
    effectiveNotifier.value = enabled || sessionFallbackEnabled;
  }

  /// 重置单例内部状态，仅用于测试，使 initialize() 可重新执行。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    notifier.value = false;
    sessionFallbackNotifier.value = false;
    effectiveNotifier.value = false;
  }
}
