import 'dart:io' as io;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../../../constants.dart';
import '../../windows_webview_environment_service.dart';
import 'cookie_logger.dart';
import 'cookie_value_codec.dart';
import 'raw_set_cookie_queue.dart';
import 'strategy/platform_cookie_strategy.dart';

export 'cookie_value_codec.dart';

/// 统一的 Cookie 管理服务。
///
/// CookieJar 是 cookie 的唯一存储：
/// - Dio Set-Cookie 响应直接写入（hostOnly 100% 正确）
/// - WebView 边界同步通过 [BoundarySyncService] 写入
/// - Dio 请求通过 [loadForRequest] 加载
class CookieJarService {
  static final CookieJarService _instance = CookieJarService._internal();
  factory CookieJarService() => _instance;
  CookieJarService._internal();

  CookieJar? _cookieJar;
  bool _initialized = false;
  late final PlatformCookieStrategy _strategy;

  /// 可配置的关键 cookie 名集合
  static const Set<String> sessionCookieNames = {
    '_t',
    '_forum_session',
  };

  static Set<String> criticalCookieNames = {
    ...sessionCookieNames,
    'cf_clearance',
  };

  CookieManager get webViewCookieManager =>
      WindowsWebViewEnvironmentService.instance.cookieManager;

  /// 获取 CookieJar 实例（用于 Dio CookieManager）
  CookieJar get cookieJar {
    if (_cookieJar == null) {
      throw StateError(
        'CookieJarService not initialized. Call initialize() first.',
      );
    }
    return _cookieJar!;
  }

  bool get isInitialized => _initialized;

  /// 初始化 CookieJar（应用启动时调用）
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final cookiePath = path.join(directory.path, '.cookies');

      final cookieDir = io.Directory(cookiePath);
      if (!await cookieDir.exists()) {
        await cookieDir.create(recursive: true);
      }

      _cookieJar = EnhancedPersistCookieJar(
        ignoreExpires: false,
        store: FileCookieStore(cookiePath),
      );

      _initialized = true;
      _strategy = PlatformCookieStrategy.create();
      debugPrint('[CookieJar] Initialized with path: $cookiePath');

      // 初始化原始头队列
      await RawSetCookieQueue.instance.initialize(directory.path);
    } catch (e) {
      debugPrint(
        '[CookieJar] Failed to create persistent storage, using memory: $e',
      );
      _cookieJar = CookieJar();
      _initialized = true;
      _strategy = PlatformCookieStrategy.create();
    }
  }

  // ---------------------------------------------------------------------------
  // 单个 Cookie 操作
  // ---------------------------------------------------------------------------

  /// 获取指定 Cookie 的值
  Future<String?> getCookieValue(String name) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);

      for (final cookie in cookies) {
        if (cookie.name == name) {
          final value = CookieValueCodec.decode(cookie.value);
          if (value.isNotEmpty) return value;
        }
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cookie $name: $e');
    }
    return null;
  }

  /// 加载指定 URI 的 CanonicalCookie 列表
  Future<List<CanonicalCookie>> loadCanonicalCookiesForRequest(Uri uri) async {
    if (!_initialized) await initialize();
    final jar = _cookieJar;
    if (jar is EnhancedPersistCookieJar) {
      return jar.loadCanonicalForRequest(uri);
    }
    final cookies = await _cookieJar!.loadForRequest(uri);
    return cookies
        .map(
          (cookie) => CanonicalCookie(
            name: cookie.name,
            value: CookieValueCodec.decode(cookie.value),
            domain: cookie.domain,
            path: cookie.path ?? '/',
            expiresAt: cookie.expires?.toUtc(),
            maxAge: cookie.maxAge,
            secure: cookie.secure,
            httpOnly: cookie.httpOnly,
            hostOnly: cookie.domain == null || cookie.domain!.trim().isEmpty,
            persistent: cookie.expires != null || cookie.maxAge != null,
            originUrl: uri.toString(),
          ),
        )
        .toList(growable: false);
  }

  /// 获取指定名称的 CanonicalCookie
  Future<CanonicalCookie?> getCanonicalCookie(String name) async {
    if (!_initialized) await initialize();
    final uri = Uri.parse(AppConstants.baseUrl);
    final cookies = await loadCanonicalCookiesForRequest(uri);

    for (final cookie in cookies) {
      if (cookie.name == name) return cookie;
    }
    return null;
  }

  /// 加载指定 URI 下的 Cookie 诊断信息（不含真实值）
  Future<List<Map<String, dynamic>>> getCookieDiagnosticsForRequest(
    Uri uri, {
    Iterable<String>? names,
  }) async {
    final normalizedNames = names
        ?.map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    final cookies = await loadCanonicalCookiesForRequest(uri);
    final diagnostics = cookies
        .where(
          (cookie) =>
              normalizedNames == null || normalizedNames.contains(cookie.name),
        )
        .map(
          (cookie) => {
            'name': cookie.name,
            'domain': cookie.domain,
            'normalizedDomain': cookie.normalizedDomain,
            'path': cookie.path,
            'hostOnly': cookie.hostOnly,
            'valueLength': cookie.value.length,
            'secure': cookie.secure,
            'httpOnly': cookie.httpOnly,
            'persistent': cookie.persistent,
            'source': cookie.source.name,
            'originUrl': cookie.originUrl,
            'originHost': Uri.tryParse(cookie.originUrl ?? '')?.host,
          },
        )
        .toList(growable: false);

    diagnostics.sort((a, b) {
      final nameA = a['name']?.toString() ?? '';
      final nameB = b['name']?.toString() ?? '';
      final nameCompare = nameA.compareTo(nameB);
      if (nameCompare != 0) return nameCompare;

      final pathA = a['path']?.toString().length ?? 0;
      final pathB = b['path']?.toString().length ?? 0;
      return pathB.compareTo(pathA);
    });
    return diagnostics;
  }

  /// 加载应用主域下的会话 Cookie 诊断信息
  Future<List<Map<String, dynamic>>> getSessionCookieDiagnosticsForRequest({
    Uri? uri,
  }) {
    return getCookieDiagnosticsForRequest(
      uri ?? Uri.parse(AppConstants.baseUrl),
      names: sessionCookieNames,
    );
  }

  /// 加载所有 CanonicalCookie（供 RawSetCookieQueue 兜底使用）
  Future<List<CanonicalCookie>> loadAllCanonicalCookies() async {
    if (!_initialized) await initialize();
    final jar = _cookieJar;
    if (jar is EnhancedPersistCookieJar) {
      return jar.readAllCookies();
    }
    return const [];
  }

  /// 设置 Cookie
  Future<void> setCookie(
    String name,
    String value, {
    String? url,
    String? domain,
    String? path,
    DateTime? expires,
    bool secure = true,
    bool httpOnly = false,
  }) async {
    if (!_initialized) await initialize();

    try {
      final uri =
          Uri.tryParse(url ?? AppConstants.baseUrl) ??
          Uri.parse(AppConstants.baseUrl);
      final cookie = io.Cookie(name, value)
        ..path = path ?? '/'
        ..secure = secure
        ..httpOnly = httpOnly;

      final normalizedDomain = domain?.trim();
      if (normalizedDomain != null && normalizedDomain.isNotEmpty) {
        cookie.domain = normalizedDomain;
      }
      if (expires != null) {
        cookie.expires = expires;
      }

      await _cookieJar!.saveFromResponse(uri, [cookie]);
    } catch (e) {
      debugPrint('[CookieJar] Failed to set cookie $name: $e');
    }
  }

  /// 删除指定 Cookie
  Future<void> deleteCookie(String name) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final expired = DateTime.now().subtract(const Duration(days: 1));
      final hosts = await getKnownHostsForDomain(uri.host);

      for (final host in hosts) {
        final hostUri = Uri.parse('https://$host');
        final cookies = await _cookieJar!.loadForRequest(hostUri);

        final expiredCookies = <io.Cookie>[];
        for (final cookie in cookies) {
          if (cookie.name == name) {
            final expired0 = io.Cookie(name, '')
              ..path = cookie.path ?? '/'
              ..expires = expired;
            if (cookie.domain != null) {
              expired0.domain = cookie.domain;
            }
            expiredCookies.add(expired0);
          }
        }

        if (expiredCookies.isNotEmpty) {
          await _cookieJar!.saveFromResponse(hostUri, expiredCookies);
        }
      }

      await RawSetCookieQueue.instance.clearCookieNames({name});

      CookieLogger.delete(name: name, source: 'deleteCookie');
    } catch (e) {
      debugPrint('[CookieJar] Failed to delete cookie $name: $e');
    }
  }

  /// 清除所有 Cookie（包括 WebView cookie store）
  Future<void> clearAll() async {
    if (!_initialized) await initialize();

    try {
      // 先扫描已知域名（必须在 deleteAll 之前，否则 jar 已空扫不到）
      final baseHost = Uri.parse(AppConstants.baseUrl).host;
      final knownHosts = await getKnownHostsForDomain(baseHost);

      await _cookieJar!.deleteAll();
      await RawSetCookieQueue.instance.clear();

      // WebView cookie store 清理（平台策略处理差异）
      await _strategy.clearWebViewCookies(webViewCookieManager, knownHosts);

      CookieLogger.delete(name: '*', source: 'clearAll');
    } catch (e) {
      debugPrint('[CookieJar] Failed to clear cookies: $e');
    }
  }

  /// 从 WebView cookie store 删除指定名称的 cookie。
  /// Windows 上同时尝试 host-only / host / .host 三种变体，避免 WebView2 domain 形态不一致导致残留。
  Future<void> deleteWebViewCookie(String name) async {
    if (!_initialized) await initialize();

    try {
      await RawSetCookieQueue.instance.clearCookieNames({name});

      final baseHost = Uri.parse(AppConstants.baseUrl).host;
      final hosts = await getKnownHostsForDomain(baseHost);

      for (final host in hosts) {
        final url = WebUri('https://$host');
        for (final domain in <String?>{null, host, '.$host'}) {
          try {
            await webViewCookieManager.deleteCookie(
              url: url,
              name: name,
              domain: domain,
              path: '/',
            );
          } catch (e) {
            debugPrint(
              '[CookieJar] Failed to delete WebView cookie $name for host=$host domain=$domain: $e',
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to delete WebView cookie $name: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 便捷方法
  // ---------------------------------------------------------------------------

  /// 获取 _t token
  Future<String?> getTToken() => getCookieValue('_t');

  /// 获取 _t 的诊断信息
  Future<Map<String, dynamic>> getTTokenDiagnostics() async {
    if (!_initialized) await initialize();
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);
      final tCookies = cookies.where((c) => c.name == '_t').toList();
      return {
        'count': tCookies.length,
        'variants': tCookies
            .map(
              (c) => {
                'domain': c.domain,
                'path': c.path,
                'len': c.value.length,
                'hasPrefix': c.value.startsWith(CookieValueCodec.prefix),
              },
            )
            .toList(),
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// 获取 cf_clearance
  Future<String?> getCfClearance() => getCookieValue('cf_clearance');

  /// 获取 cf_clearance 的原始 Cookie 对象
  Future<io.Cookie?> getCfClearanceCookie() async {
    if (!_initialized) await initialize();
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);
      for (final cookie in cookies) {
        if (cookie.name == 'cf_clearance') return cookie;
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cf_clearance cookie: $e');
    }
    return null;
  }

  /// 恢复 cf_clearance（退出登录后保留 CF 通行证）
  Future<void> restoreCfClearance(io.Cookie cookie) async {
    if (!_initialized) await initialize();
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      await _cookieJar!.saveFromResponse(uri, [cookie]);
    } catch (e) {
      debugPrint('[CookieJar] Failed to restore cf_clearance: $e');
    }
  }

  /// 获取所有 Cookie 的字符串形式（用于请求头诊断）
  Future<String?> getCookieHeader() async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);
      if (cookies.isEmpty) return null;
      return cookies
          .map((c) => '${c.name}=${CookieValueCodec.decode(c.value)}')
          .join('; ');
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cookie header: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 工具方法
  // ---------------------------------------------------------------------------

  /// 从 jar 中扫描已知的相关域名
  Future<Set<String>> getKnownHostsForDomain(String baseDomain) async {
    if (!_initialized) await initialize();
    final hosts = <String>{baseDomain};

    final jar = _cookieJar;
    if (jar is EnhancedPersistCookieJar) {
      try {
        final cookies = await jar.readAllCookies();
        for (final cookie in cookies) {
          final d = cookie.normalizedDomain;
          if (d != null &&
              d.isNotEmpty &&
              (d == baseDomain || d.endsWith('.$baseDomain'))) {
            hosts.add(d);
          }
        }
      } catch (e) {
        debugPrint('[CookieJar] Failed to scan related hosts: $e');
      }
    }

    return hosts;
  }

  /// 标准化 WebView cookie domain
  static String? normalizeWebViewCookieDomain(String? rawDomain) {
    final trimmed = rawDomain?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.startsWith('.') ? trimmed.substring(1) : trimmed;
  }

  /// flutter_inappwebview 的 expires 兼容处理
  static DateTime? parseWebViewCookieExpires(int? rawExpiresDate) {
    if (rawExpiresDate == null || rawExpiresDate <= 0) return null;
    final normalizedMillis = rawExpiresDate < 100000000000
        ? rawExpiresDate * 1000
        : rawExpiresDate;
    return DateTime.fromMillisecondsSinceEpoch(normalizedMillis);
  }

  /// 是否是关键 cookie
  static bool isCriticalCookie(String name) =>
      criticalCookieNames.contains(name);

  /// 检查 domain 是否匹配应用主域
  static bool matchesAppHost(String? domain) {
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    final normalized = domain?.trim().replaceFirst(RegExp(r'^\.'), '');
    if (normalized == null || normalized.isEmpty) return true;
    return normalized == baseHost || normalized.endsWith('.$baseHost');
  }

  /// Windows：通过页面级 controller 的 CDP 读取实时 cookie 值。
  Future<String?> readCookieValueFromController(
    InAppWebViewController controller,
    String name, {
    String? currentUrl,
  }) async {
    if (!io.Platform.isWindows) return null;

    try {
      final rawCookies = await _readWindowsCookiesFromController(
        controller,
        currentUrl: currentUrl,
      );
      String? fallback;
      for (final raw in rawCookies) {
        final cookieName = raw['name']?.toString();
        final value = raw['value']?.toString() ?? '';
        final domain = raw['domain']?.toString();
        if (cookieName != name || value.isEmpty) continue;
        if (matchesAppHost(domain)) {
          return value;
        }
        fallback ??= value;
      }
      return fallback;
    } catch (e) {
      debugPrint('[CookieJar][Windows] Failed to read live cookie $name: $e');
      return null;
    }
  }

  /// Windows：通过页面级 controller 的 CDP 将关键 cookie 直接写入 CookieJar。
  Future<int> syncCriticalCookiesFromController(
    InAppWebViewController controller, {
    String? currentUrl,
    Set<String>? cookieNames,
  }) async {
    if (!io.Platform.isWindows) return 0;
    if (!_initialized) await initialize();

    try {
      final uri =
          Uri.tryParse(currentUrl ?? AppConstants.baseUrl) ??
          Uri.parse(AppConstants.baseUrl);
      final rawCookies = await _readWindowsCookiesFromController(
        controller,
        currentUrl: currentUrl,
      );
      final filtered = rawCookies
          .where((raw) {
            final name = raw['name']?.toString();
            final value = raw['value']?.toString() ?? '';
            final domain = raw['domain']?.toString();
            if (name == null || value.isEmpty) return false;
            if (cookieNames != null && !cookieNames.contains(name)) {
              return false;
            }
            return matchesAppHost(domain);
          })
          .toList(growable: false);

      if (filtered.isEmpty) return 0;

      final jar = _cookieJar;
      if (jar is EnhancedPersistCookieJar) {
        await jar.saveFromCdpCookies(uri, filtered);
        return filtered.length;
      }

      final toSave = <io.Cookie>[];
      for (final raw in filtered) {
        final name = raw['name']?.toString();
        final value = raw['value']?.toString() ?? '';
        if (name == null || value.isEmpty) continue;

        io.Cookie cookie;
        try {
          cookie = io.Cookie(name, value);
        } catch (_) {
          cookie = io.Cookie(name, CookieValueCodec.encode(value));
        }

        final domain = raw['domain']?.toString();
        final path = raw['path']?.toString();
        final secure = raw['secure'] == true;
        final httpOnly = raw['httpOnly'] == true;
        final expires = raw['expires'];

        if (domain != null && domain.trim().isNotEmpty) {
          cookie.domain = domain;
        }
        cookie
          ..path = path == null || path.isEmpty ? '/' : path
          ..secure = secure
          ..httpOnly = httpOnly;
        if (expires is num && expires > 0) {
          cookie.expires = DateTime.fromMillisecondsSinceEpoch(
            (expires * 1000).round(),
          );
        }
        toSave.add(cookie);
      }

      if (toSave.isEmpty) return 0;
      await _cookieJar!.saveFromResponse(uri, toSave);
      return toSave.length;
    } catch (e) {
      debugPrint('[CookieJar][Windows] Failed to sync live cookies: $e');
      return 0;
    }
  }

  Future<List<Map<String, dynamic>>> _readWindowsCookiesFromController(
    InAppWebViewController controller, {
    String? currentUrl,
  }) async {
    final baseUri = Uri.parse(AppConstants.baseUrl);
    final hosts = await getKnownHostsForDomain(baseUri.host);
    final currentHost = Uri.tryParse(currentUrl ?? '')?.host;
    if (currentHost != null &&
        currentHost.isNotEmpty &&
        matchesAppHost(currentHost)) {
      hosts.add(currentHost);
    }

    final urls = <String>{
      AppConstants.baseUrl,
      '${AppConstants.baseUrl}/',
      if (currentUrl != null && currentUrl.isNotEmpty) currentUrl,
      for (final host in hosts) 'https://$host',
      for (final host in hosts) 'https://$host/',
    }.toList(growable: false);

    final result = await controller.callDevToolsProtocolMethod(
      methodName: 'Network.getCookies',
      parameters: {'urls': urls},
    );
    final rawCookies = result is Map<String, dynamic>
        ? result['cookies']
        : null;
    if (rawCookies is! List) return const [];

    return rawCookies
        .whereType<Map>()
        .map((raw) => raw.map((key, value) => MapEntry(key.toString(), value)))
        .cast<Map<String, dynamic>>()
        .where((raw) => matchesAppHost(raw['domain']?.toString()))
        .toList(growable: false);
  }
}
