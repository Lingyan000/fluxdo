import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../constants.dart';
import '../../auth_session.dart';
import '../../log/log_writer.dart';
import 'cookie_jar_service.dart';
import 'cookie_logger.dart';
import 'strategy/platform_cookie_strategy.dart';

/// 边界同步服务：在登录成功、CF 验证成功等关键时机，
/// 从 WebView CookieManager 读取 cookie 写入 CookieJar。
///
/// 只在边界时机调用，不做常态同步。
class BoundarySyncService {
  BoundarySyncService._internal();

  static final BoundarySyncService instance = BoundarySyncService._internal();

  final CookieJarService _jar = CookieJarService();
  final PlatformCookieStrategy _strategy = PlatformCookieStrategy.create();

  /// 从 WebView 读 cookie 写入 jar。
  ///
  /// [currentUrl] 当前页面 URL，用于确定读取哪个域名的 cookie。
  /// [cookieNames] 只同步指定的 cookie 名；null 表示同步所有。
  Future<void> syncFromWebView({
    String? currentUrl,
    InAppWebViewController? controller,
    Set<String>? cookieNames,
    bool allowLowConfidenceSessionCookies = false,
    int? requestGeneration,
  }) async {
    final url = currentUrl ?? AppConstants.baseUrl;
    final uri = Uri.parse(url);
    final host = uri.host;

    try {
      if (requestGeneration != null &&
          !AuthSession().isValid(requestGeneration)) {
        debugPrint(
          '[BoundarySync] 跳过过期会话同步: '
          'gen=$requestGeneration current=${AuthSession().generation}',
        );
        return;
      }

      if (io.Platform.isWindows && controller != null) {
        final synced = await _jar.syncCriticalCookiesFromController(
          controller,
          currentUrl: url,
          cookieNames: cookieNames,
        );
        if (synced > 0) {
          final syncedDetails = await _jar.getCookieDiagnosticsForRequest(
            uri,
            names: cookieNames,
          );
          CookieLogger.sync(
            direction: 'WebView(CDP) → CookieJar',
            count: synced,
            names: cookieNames?.toList() ?? const [],
            source: 'boundary_sync',
            url: url,
            cookieDetails: syncedDetails,
          );
          return;
        }
      }

      // 通过 strategy 读取（Linux 用 getAllCookies 兜底）
      final webViewCookies = await _strategy.readCookiesFromWebView(
        _jar.webViewCookieManager,
        url,
      );
      final cookiesToPersist = <Cookie>[];
      final sessionCookieGroups = <String, List<Cookie>>{};

      for (final wc in webViewCookies) {
        final value = wc.value?.toString() ?? '';
        if (value.isEmpty) continue;
        if (cookieNames != null && !cookieNames.contains(wc.name)) continue;

        final isSessionCookie =
            CookieJarService.sessionCookieNames.contains(wc.name);
        if (isSessionCookie) {
          sessionCookieGroups.putIfAbsent(wc.name, () => <Cookie>[]).add(wc);
        } else {
          cookiesToPersist.add(wc);
        }
      }

      for (final entry in sessionCookieGroups.entries) {
        final selected = _selectBestSessionCookie(entry.value, host);
        if (selected == null) continue;

        if (entry.value.length > 1) {
          _logDuplicateSessionCookies(
            url: url,
            host: host,
            name: entry.key,
            cookies: entry.value,
            selected: selected,
          );
        }
        cookiesToPersist.add(selected);
      }

      final toSave = <io.Cookie>[];
      final forcedHostOnlySessionCookies = <Map<String, dynamic>>[];

      for (final wc in cookiesToPersist) {
        final value = wc.value?.toString() ?? '';
        final isSessionCookie =
            CookieJarService.sessionCookieNames.contains(wc.name);
        final lowConfidenceSnapshot = _isLowConfidenceWebViewCookie(wc);
        if (isSessionCookie &&
            lowConfidenceSnapshot &&
            !allowLowConfidenceSessionCookies) {
          debugPrint(
            '[BoundarySync] ${wc.name}: 跳过低置信度会话 Cookie 快照',
          );
          continue;
        }

        // domain 处理：优先用平台返回值，旧 Android 兜底
        String? domain;
        final rawDomain = wc.domain?.trim();
        final shouldForceSessionHostOnly =
            io.Platform.isAndroid && isSessionCookie;
        if (shouldForceSessionHostOnly) {
          domain = null;
          if (rawDomain != null && rawDomain.isNotEmpty) {
            forcedHostOnlySessionCookies.add({
              'name': wc.name,
              'webViewDomain': wc.domain,
              'path': wc.path,
              'valueLength': value.length,
            });
          }
        } else if (rawDomain != null && rawDomain.isNotEmpty) {
          // 新设备：平台返回了 domain，直接使用
          domain = rawDomain;
        } else if (isSessionCookie) {
          // 会话 Cookie 缺失 domain 时，保持 host-only 语义，不再放大到子域名。
          domain = null;
        } else {
          // 旧 Android（GET_COOKIE_INFO 不支持）：domain 为 null
          // 优先继承 jar 中已有的 domain
          final existing = await _jar.getCanonicalCookie(wc.name);
          if (existing != null &&
              existing.domain != null &&
              existing.domain!.trim().isNotEmpty) {
            domain = existing.domain;
            debugPrint(
              '[BoundarySync] ${wc.name}: domain=null, 继承 jar 已有 domain=${existing.domain}',
            );
          } else {
            // jar 也没有 → 兜底为 .{host}（domain cookie）
            // 宁可多发到子域名，不能因为 host-only 导致子域名拿不到关键 cookie
            domain = '.$host';
            debugPrint('[BoundarySync] ${wc.name}: domain=null, 兜底为 .$host');
          }
        }

        io.Cookie cookie;
        try {
          cookie = io.Cookie(wc.name, value);
        } catch (_) {
          // value 含 RFC 不允许的字符（如 { } " 等），编码后存储
          cookie = io.Cookie(wc.name, CookieValueCodec.encode(value));
        }
        cookie
          ..path = wc.path ?? '/'
          ..secure = wc.isSecure ?? (isSessionCookie ? uri.scheme == 'https' : false)
          ..httpOnly =
              wc.isHttpOnly ?? (isSessionCookie && allowLowConfidenceSessionCookies);
        if (domain != null && domain.trim().isNotEmpty) {
          cookie.domain = domain;
        }

        if (wc.expiresDate != null) {
          cookie.expires = DateTime.fromMillisecondsSinceEpoch(wc.expiresDate!);
        }

        toSave.add(cookie);
      }

      if (toSave.isEmpty) {
        debugPrint('[BoundarySync] 未从 WebView 读取到有效 cookie: url=$url');
        return;
      }

      if (requestGeneration != null &&
          !AuthSession().isValid(requestGeneration)) {
        debugPrint(
          '[BoundarySync] 跳过过期会话写入: '
          'gen=$requestGeneration current=${AuthSession().generation}',
        );
        return;
      }

      if (!_jar.isInitialized) await _jar.initialize();
      await _jar.cookieJar.saveFromResponse(uri, toSave);
      final syncedDetails = await _jar.getCookieDiagnosticsForRequest(
        uri,
        names: toSave.map((cookie) => cookie.name),
      );

      CookieLogger.sync(
        direction: 'WebView → CookieJar',
        count: toSave.length,
        names: toSave.map((c) => c.name).toList(),
        source: 'boundary_sync',
        url: url,
        cookieDetails: syncedDetails,
        extraFields: {
          if (forcedHostOnlySessionCookies.isNotEmpty)
            'forcedHostOnlySessionCookies': forcedHostOnlySessionCookies,
        },
      );
    } catch (e) {
      CookieLogger.error(operation: 'boundary_sync', error: e.toString());
    }
  }

  bool _isLowConfidenceWebViewCookie(Cookie cookie) {
    final hasDomain = cookie.domain != null && cookie.domain!.trim().isNotEmpty;
    final hasPath = cookie.path != null && cookie.path!.trim().isNotEmpty;
    final hasSecureFlag = cookie.isSecure != null;
    final hasHttpOnlyFlag = cookie.isHttpOnly != null;
    final hasExpiry = cookie.expiresDate != null;
    final hasSameSite = cookie.sameSite != null;
    return !(hasDomain ||
        hasPath ||
        hasSecureFlag ||
        hasHttpOnlyFlag ||
        hasExpiry ||
        hasSameSite);
  }

  Cookie? _selectBestSessionCookie(List<Cookie> cookies, String requestHost) {
    if (cookies.isEmpty) return null;
    final candidates = [...cookies]
      ..sort((a, b) {
        final scoreDiff =
            _scoreSessionCookie(b, requestHost) - _scoreSessionCookie(a, requestHost);
        if (scoreDiff != 0) return scoreDiff;

        final pathDiff = (b.path?.length ?? 1).compareTo(a.path?.length ?? 1);
        if (pathDiff != 0) return pathDiff;

        return (b.value?.length ?? 0).compareTo(a.value?.length ?? 0);
      });
    return candidates.first;
  }

  int _scoreSessionCookie(Cookie cookie, String requestHost) {
    var score = 0;
    final value = cookie.value?.toString() ?? '';
    if (value.isNotEmpty) score += 100000;

    final expires = CookieJarService.parseWebViewCookieExpires(cookie.expiresDate);
    if (expires == null || expires.isAfter(DateTime.now())) {
      score += 50000;
    }

    final normalizedDomain =
        CookieJarService.normalizeWebViewCookieDomain(cookie.domain);
    if (normalizedDomain == null || normalizedDomain.isEmpty) {
      score += 40000;
    } else if (normalizedDomain == requestHost) {
      score += 30000 + normalizedDomain.length;
    } else if (requestHost.endsWith('.$normalizedDomain')) {
      score += 20000 + normalizedDomain.length;
    } else {
      score += normalizedDomain.length;
    }

    if (cookie.isHttpOnly == true) score += 500;
    if (cookie.isSecure == true) score += 250;
    score += cookie.path?.length ?? 1;
    score += value.length;
    return score;
  }

  void _logDuplicateSessionCookies({
    required String url,
    required String host,
    required String name,
    required List<Cookie> cookies,
    required Cookie selected,
  }) {
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'cookie_conflict',
      'event': 'duplicate_session_cookie_from_webview',
      'message': 'WebView 中检测到重复会话 Cookie，已在边界同步时选优',
      'url': url,
      'host': host,
      'name': name,
      'duplicateCount': cookies.length,
      'selected': {
        'domain': selected.domain,
        'path': selected.path,
        'hostOnly': selected.domain == null || selected.domain!.trim().isEmpty,
        'valueLength': selected.value?.length ?? 0,
        'httpOnly': selected.isHttpOnly,
        'secure': selected.isSecure,
      },
      'cookies': cookies
          .map(
            (cookie) => {
              'domain': cookie.domain,
              'path': cookie.path,
              'hostOnly': cookie.domain == null || cookie.domain!.trim().isEmpty,
              'valueLength': cookie.value?.length ?? 0,
              'httpOnly': cookie.isHttpOnly,
              'secure': cookie.isSecure,
              'expiresDate': cookie.expiresDate,
            },
          )
          .toList(growable: false),
    });
  }
}
