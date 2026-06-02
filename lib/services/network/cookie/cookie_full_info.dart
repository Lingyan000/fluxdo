import 'dart:io' as io;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Cookie 完整信息的跨平台抽象。
///
/// 用于 [SessionCookieSentinel] 枚举 cookie 变体时统一描述 cookie。
///
/// 平台差异说明（参见 `docs/cookie-sync-design-v0.4.0.md` §5.4）：
/// - iOS / macOS：所有字段可获取（基于 `WKHTTPCookieStore.getAllCookies()`）
/// - Android（新 WebView，`GET_COOKIE_INFO` 支持）：所有字段可获取
/// - Android（旧 WebView）：仅 [name] / [value] 可保证，其它字段可能为 null
class CookieFullInfo {
  CookieFullInfo({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.isSecure,
    this.isHttpOnly,
    this.expiresMillis,
  });

  final String name;
  final String value;

  /// cookie 的 Domain 属性；null 表示 host-only cookie，
  /// 或者 Android 旧设备无法获取该字段。
  final String? domain;

  /// cookie 的 Path 属性；null 表示 Android 旧设备无法获取。
  final String? path;

  final bool? isSecure;
  final bool? isHttpOnly;

  /// cookie 过期时间（毫秒时间戳）；
  /// null 表示 session cookie 或 Android 旧设备无法获取。
  final int? expiresMillis;

  /// 是否为 host-only cookie（[domain] 缺失则视为 host-only）。
  ///
  /// 注意：在 Android 旧设备上，[domain] 可能因为 API 限制而为 null，
  /// 这种情况下无法准确判断是否真为 host-only，需要结合上下文。
  bool get isHostOnly => domain == null || domain!.trim().isEmpty;

  /// 从 `flutter_inappwebview` 的 [Cookie] 转换（iOS / 新 Android）。
  factory CookieFullInfo.fromWebViewCookie(Cookie cookie) {
    return CookieFullInfo(
      name: cookie.name,
      value: cookie.value?.toString() ?? '',
      domain: cookie.domain,
      path: cookie.path,
      isSecure: cookie.isSecure,
      isHttpOnly: cookie.isHttpOnly,
      expiresMillis: cookie.expiresDate,
    );
  }

  /// 从 `dart:io` 的 [io.Cookie] 转换（用于从 jar 中读取）。
  factory CookieFullInfo.fromIoCookie(io.Cookie cookie) {
    return CookieFullInfo(
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
      isSecure: cookie.secure,
      isHttpOnly: cookie.httpOnly,
      expiresMillis: cookie.expires?.millisecondsSinceEpoch,
    );
  }

  @override
  String toString() {
    return 'CookieFullInfo(name=$name, valueLength=${value.length}, '
        'domain=$domain, path=$path, hostOnly=$isHostOnly, '
        'secure=$isSecure, httpOnly=$isHttpOnly, expires=$expiresMillis)';
  }
}
