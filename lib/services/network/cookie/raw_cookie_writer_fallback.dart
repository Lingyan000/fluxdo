import 'dart:io' as io;

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../windows_webview_environment_service.dart';
import 'cookie_full_info.dart';

/// Windows / Linux 平台的 RawCookieWriter Dart fallback 实现。
///
/// macOS/iOS/Android 走 native method channel `com.fluxdo/raw_cookie`,
/// 但 Win/Linux 没有 native 实现。这里用 `flutter_inappwebview` 的
/// CookieManager 接口在 Dart 层等价实现 5 个原语:
/// - setRawCookie
/// - nukeAllVariants
/// - deleteExactCookie
/// - getAllCookieInfos
/// - countCookiesByName
///
/// **平台兼容性说明**:
///
/// - Windows: 走 WebView2 `ICoreWebView2CookieManager`,
///   `AddOrUpdateCookie` 按 (name, domain, path) 替换,行为符合标准。
///   `WindowsWebViewEnvironmentService` 提供的 cookieManager 内部绑定
///   到正确的 `WebViewEnvironment`,与 InAppWebView 共享同一 cookie store。
///
/// - Linux: 走 WPE WebKit `WebKitCookieManager` (SoupCookieJar)。
///   注意 native `deleteCookie` 实现 (packages/flutter_inappwebview_linux/
///   linux/cookie_manager.cc:440) 中 `path == "/"` 会匹配任意 path 的同名
///   cookie。对 `nukeAllVariants` (本就想多删) 是 feature, 对 `deleteExactCookie`
///   传 path="/" 时会误伤 — 但 Sentinel 实际只用 nukeAllVariants 路径,无影响。
///
/// **已知局限**:
/// - Win/Linux 没有 `WKHTTPCookieStoreObserver` 等价物, WV 网络层写入的
///   cookie 我们感知不到, 只能靠 `InAppWebView.onLoadStop` 触发 sweep
///   (覆盖页面级 cookie 变化, 不覆盖 XHR/fetch 中的 Set-Cookie)。
class RawCookieWriterFallback {
  RawCookieWriterFallback._();
  static final RawCookieWriterFallback instance = RawCookieWriterFallback._();

  /// 取当前平台对应的 CookieManager。
  /// Windows 必须先 [WindowsWebViewEnvironmentService.instance.initialize()],
  /// 否则环境未就绪 getter 会回退到默认实例,可能写到不同的 cookie store。
  /// `main.dart` 启动时 `Future.wait` 已保证先 init env, 这里安全。
  CookieManager get _cookieManager {
    if (io.Platform.isWindows) {
      return WindowsWebViewEnvironmentService.instance.cookieManager;
    }
    return CookieManager.instance();
  }

  /// 通过原始 Set-Cookie 头写入 WV。
  ///
  /// 用 [SetCookieParser] (项目内已有, 解析完整字段含 SameSite/Partitioned)
  /// 代替 `io.Cookie.fromSetCookieValue` (后者不解析 SameSite — 会丢字段
  /// 导致与 WV 网络层写入的同名 cookie 在隐藏属性上不一致, 引起共存)。
  Future<bool> setRawCookie(
    String url,
    String rawSetCookie, {
    bool writeSharedStorage = true,
  }) async {
    try {
      final uri = Uri.parse(url);
      final canonical = SetCookieParser.parse(rawSetCookie, uri: uri);

      return await _cookieManager.setCookie(
        url: WebUri(url),
        name: canonical.name,
        value: canonical.value,
        path: canonical.path.isEmpty ? '/' : canonical.path,
        // 没有 Domain= 的 Cookie 必须保持 host-only。Windows 的 Chromium
        // Network.setCookie 和 Linux 的 SoupCookie 都用前导点区分域 Cookie，
        // 因此仅对服务端明确声明了 Domain= 的 Cookie 补点。
        domain: resolveCookieDomain(
          hostOnly: canonical.hostOnly,
          domain: canonical.domain,
        ),
        expiresDate: canonical.expiresAt?.millisecondsSinceEpoch,
        maxAge: canonical.maxAge,
        isSecure: canonical.secure,
        isHttpOnly: canonical.httpOnly,
        sameSite: _mapSameSite(canonical.sameSite),
      );
    } catch (e) {
      debugPrint('[RawCookieWriterFallback] setRawCookie failed: $e');
      return false;
    }
  }

  /// 删除指定 name 的所有变体。
  ///
  /// 优先：用 `getCookies` 枚举真实 cookie，按各自真实 (domain, path) 精确删
  /// （与 [countCookiesByName] 对齐，确保"数得到的一定删得到"）。
  /// 兜底：旧 WebView 枚举不到字段 / getCookies 失败时，回退到穷举候选组合。
  Future<int> nukeAllVariants({
    required String url,
    required String name,
    required List<String?> domainCandidates,
    required List<String> pathCandidates,
  }) async {
    final webUri = WebUri(url);

    try {
      final cookies = await _cookieManager.getCookies(url: webUri);
      final matching = cookies.where((c) => c.name == name).toList();
      if (matching.isNotEmpty) {
        var deleted = 0;
        for (final c in matching) {
          try {
            final ok = await _cookieManager.deleteCookie(
              url: webUri,
              name: name,
              path: c.path ?? '/',
              domain: c.domain,
            );
            if (ok) deleted++;
          } catch (e) {
            debugPrint(
              '[RawCookieWriterFallback] deleteCookie(real $name, '
              '${c.domain}, ${c.path}) failed: $e',
            );
          }
        }
        return deleted;
      }
    } catch (e) {
      debugPrint(
        '[RawCookieWriterFallback] enumerate for nuke failed, '
        'fallback to candidates: $e',
      );
    }

    // 兜底：穷举 (domainCandidates × pathCandidates)。
    var deleted = 0;
    for (final domain in domainCandidates) {
      for (final path in pathCandidates) {
        try {
          final ok = await _cookieManager.deleteCookie(
            url: webUri,
            name: name,
            path: path,
            domain: domain,
          );
          if (ok) deleted++;
        } catch (e) {
          debugPrint(
            '[RawCookieWriterFallback] deleteCookie($name, $domain, $path) '
            'failed: $e',
          );
        }
      }
    }
    return deleted;
  }

  /// 精确删除指定 (name, domain, path) 的单条 cookie。
  ///
  /// 警告: Linux 上 path="/" 会误删任意 path 的同名 cookie (native 实现细节)。
  /// Sentinel 当前只走 nukeAllVariants, 暂不踩此坑。
  Future<bool> deleteExactCookie({
    required String url,
    required String name,
    required String? domain,
    required String path,
  }) async {
    try {
      return await _cookieManager.deleteCookie(
        url: WebUri(url),
        name: name,
        path: path,
        domain: domain,
      );
    } catch (e) {
      debugPrint('[RawCookieWriterFallback] deleteExactCookie failed: $e');
      return false;
    }
  }

  /// 读取指定 url 下所有 cookie 的完整信息。
  Future<List<CookieFullInfo>> getAllCookieInfos(String url) async {
    try {
      final cookies = await _cookieManager.getCookies(url: WebUri(url));
      return cookies
          .map(CookieFullInfo.fromWebViewCookie)
          .toList(growable: false);
    } catch (e) {
      debugPrint('[RawCookieWriterFallback] getAllCookieInfos failed: $e');
      return const [];
    }
  }

  /// 统计指定 url 下 cookie name 的变体数。
  Future<int> countCookiesByName(String url, String name) async {
    try {
      final cookies = await _cookieManager.getCookies(url: WebUri(url));
      return cookies.where((c) => c.name == name).length;
    } catch (e) {
      debugPrint('[RawCookieWriterFallback] countCookiesByName failed: $e');
      return 0;
    }
  }

  @visibleForTesting
  static String? resolveCookieDomain({
    required bool hostOnly,
    required String? domain,
  }) {
    if (hostOnly) return null;
    final value = domain?.trim();
    if (value == null || value.isEmpty) return null;
    return value.startsWith('.') ? value : '.$value';
  }

  HTTPCookieSameSitePolicy? _mapSameSite(CookieSameSite sameSite) {
    switch (sameSite) {
      case CookieSameSite.lax:
        return HTTPCookieSameSitePolicy.LAX;
      case CookieSameSite.strict:
        return HTTPCookieSameSitePolicy.STRICT;
      case CookieSameSite.none:
        return HTTPCookieSameSitePolicy.NONE;
      case CookieSameSite.unspecified:
        return null;
    }
  }
}
