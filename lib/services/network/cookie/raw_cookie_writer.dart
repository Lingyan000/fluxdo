import 'dart:async';
import 'dart:io' as io;

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cookie_full_info.dart';
import 'cookie_logger.dart';
import 'raw_cookie_writer_fallback.dart';

/// A read can be abandoned safely: a late snapshot never mutates the store.
class CookieStoreReadTimeout extends TimeoutException {
  CookieStoreReadTimeout(Duration timeout)
    : super('Cookie store read timed out', timeout);
}

/// 通过原生平台通道写入 / 读取 / 删除 WebView cookie store。
///
/// 保留完整的 cookie 语义（host-only / domain / sameSite 等）。
///
/// v0.4.0 扩展：增加 [nukeAllVariants] / [deleteExactCookie] /
/// [getAllCookieInfos] / [countCookiesByName] 用于 Sentinel 内核（参见
/// `docs/cookie-sync-design-v0.4.0.md` §5.4）。
///
/// 平台支持矩阵:
/// - Android / iOS / macOS: native method channel `com.fluxdo/raw_cookie`
/// - Windows / Linux: Dart 层 [RawCookieWriterFallback] 包装
///   flutter_inappwebview 的 CookieManager (无需 native)
class RawCookieWriter {
  RawCookieWriter._() : _forceNativeChannel = false;

  /// 单元测试通过模拟 MethodChannel 验证共享读取，避免依赖宿主平台插件。
  @visibleForTesting
  RawCookieWriter.forTesting() : _forceNativeChannel = true;

  final bool _forceNativeChannel;
  static final instance = RawCookieWriter._();

  static const _channel = MethodChannel('com.fluxdo/raw_cookie');
  static const _readTimeout = Duration(seconds: 5);
  final Map<String, Future<List<CookieFullInfo>>> _reads = {};

  void invalidateReads() => _reads.clear();
  static const _sharedStorageIsolatedCookieNames = {
    'cf_clearance',
    '_t',
    '_forum_session',
  };

  /// 当前平台是否有 native method channel 实现。
  bool get _hasNativeChannel =>
      _forceNativeChannel ||
      io.Platform.isAndroid ||
      io.Platform.isIOS ||
      io.Platform.isMacOS;

  /// 当前平台是否走 Dart fallback (flutter_inappwebview CookieManager)。
  bool get _hasDartFallback =>
      !_forceNativeChannel && (io.Platform.isWindows || io.Platform.isLinux);

  /// 是否支持当前平台 (native 或 Dart fallback 任一可用即支持)。
  bool get isSupported => _hasNativeChannel || _hasDartFallback;

  /// 认证 Cookie 由 WK store 持有。清理 Foundation 中的旧副本，避免
  /// sharedCookiesEnabled 在创建页面时把它们重新导入。
  Future<void> clearSharedAuthCookieCopies(
    String url,
    Iterable<String> names,
  ) async {
    if (!io.Platform.isMacOS && !io.Platform.isIOS) return;
    final authNames = names
        .where((name) => name == '_t' || name == '_forum_session')
        .toSet();
    if (authNames.isEmpty) return;
    await _channel.invokeMethod<void>('clearSharedAuthCookieCopies', {
      'url': url,
      'names': authNames.toList(),
    });
  }

  /// 通过原始 Set-Cookie 头字符串写入 cookie。
  ///
  /// [url] — cookie 所属的 URL（如 `https://linux.do`）
  /// [rawSetCookie] — 原始 Set-Cookie 头（如 `_t=xxx; path=/; secure; httponly`）
  ///
  /// 各平台实现：
  /// - Android: `CookieManager.setCookie(url, rawSetCookie)`
  /// - iOS/macOS: `HTTPCookie.cookies(withResponseHeaderFields:for:)` → `WKHTTPCookieStore.setCookie`
  ///   默认同时写入 `HTTPCookieStorage.shared`；[writeSharedStorage] 可关闭
  ///   shared storage 写入，用于避免 Apple 平台对特定 HttpOnly domain cookie
  ///   产生双份 WK 变体。
  ///   `cf_clearance`、`_t`、`_forum_session` 仅写入 WK store，避免
  ///   Foundation 副本在创建页面时重新导入旧值或重复变体。
  /// - Linux: `soup_cookie_jar_set_cookie(jar, uri, rawSetCookie)`
  Future<bool> setRawCookie(
    String url,
    String rawSetCookie, {
    bool writeSharedStorage = true,
  }) async {
    invalidateReads();
    try {
      return await _setRawCookie(
        url,
        rawSetCookie,
        writeSharedStorage: writeSharedStorage,
      );
    } finally {
      invalidateReads();
    }
  }

  Future<bool> _setRawCookie(
    String url,
    String rawSetCookie, {
    bool writeSharedStorage = true,
  }) async {
    final effectiveWriteSharedStorage = _effectiveSharedStorageWrite(
      url,
      rawSetCookie,
      requested: writeSharedStorage,
    );
    if (_hasDartFallback) {
      return RawCookieWriterFallback.instance.setRawCookie(
        url,
        rawSetCookie,
        writeSharedStorage: effectiveWriteSharedStorage,
      );
    }
    try {
      final result = await _channel.invokeMethod<bool>('setRawCookie', {
        'url': url,
        'rawSetCookie': rawSetCookie,
        'writeSharedStorage': effectiveWriteSharedStorage,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('[RawCookieWriter] setRawCookie failed: $e');
      return false;
    } on MissingPluginException {
      debugPrint('[RawCookieWriter] Platform channel not available');
      return false;
    }
  }

  bool _effectiveSharedStorageWrite(
    String url,
    String rawSetCookie, {
    required bool requested,
  }) {
    if (!requested) return false;

    final name = _cookieNameFromRawHeader(url, rawSetCookie);
    if (name == null) return requested;
    return !_sharedStorageIsolatedCookieNames.contains(name.toLowerCase());
  }

  String? _cookieNameFromRawHeader(String url, String rawSetCookie) {
    try {
      return SetCookieParser.parse(rawSetCookie, uri: Uri.parse(url)).name;
    } catch (_) {
      final separator = rawSetCookie.indexOf('=');
      if (separator <= 0) return null;
      final name = rawSetCookie.substring(0, separator).trim();
      return name.isEmpty ? null : name;
    }
  }

  /// 批量写入多个 raw Set-Cookie 头。
  Future<int> setRawCookies(String url, List<String> rawSetCookies) async {
    var written = 0;
    for (final raw in rawSetCookies) {
      if (await setRawCookie(url, raw)) written++;
    }
    return written;
  }

  // ---------------------------------------------------------------------------
  // v0.4.0 新增：Sentinel 内核所需的原语
  //
  // 原生侧实现详见 §8.4。Phase 1 阶段 Dart 通道已包装，原生侧 Phase 2 实现。
  // 待原生侧实现前，调用返回安全默认值（不抛异常）。
  // ---------------------------------------------------------------------------

  /// 暴力穷举删除指定 name 的所有变体。
  ///
  /// 仅供 Sentinel 在 Android 上"无法精确枚举变体"时使用。
  /// 对每对 `(domain, path)` 组合发出 `Max-Age=0` 删除请求。
  ///
  /// [domainCandidates] — null 表示尝试 host-only（不传 Domain 属性）
  ///
  /// 返回成功删除的变体数（best-effort，原生侧可能无法精确统计）。
  ///
  /// 验证项：V4（Android Max-Age=0 + Domain 精确匹配实测）。
  Future<int> nukeAllVariants({
    required String url,
    required String name,
    required List<String?> domainCandidates,
    required List<String> pathCandidates,
  }) async {
    invalidateReads();
    try {
      return await _nukeAllVariants(
        url: url,
        name: name,
        domainCandidates: domainCandidates,
        pathCandidates: pathCandidates,
      );
    } finally {
      invalidateReads();
    }
  }

  Future<int> _nukeAllVariants({
    required String url,
    required String name,
    required List<String?> domainCandidates,
    required List<String> pathCandidates,
  }) async {
    if (_hasDartFallback) {
      return RawCookieWriterFallback.instance.nukeAllVariants(
        url: url,
        name: name,
        domainCandidates: domainCandidates,
        pathCandidates: pathCandidates,
      );
    }
    try {
      final result = await _channel.invokeMethod<int>('nukeAllVariants', {
        'url': url,
        'name': name,
        'domainCandidates': domainCandidates,
        'pathCandidates': pathCandidates,
      });
      return result ?? 0;
    } on PlatformException catch (e) {
      debugPrint('[RawCookieWriter] nukeAllVariants failed: $e');
      return 0;
    } on MissingPluginException {
      debugPrint('[RawCookieWriter] Platform channel not available');
      return 0;
    }
  }

  /// 精确删除指定 `(name, domain, path)` 的单条 cookie 变体。
  ///
  /// iOS / macOS：`WKHTTPCookieStore.delete(HTTPCookie)` 精确匹配。
  /// Android：退化为 `nukeAllVariants` 的单组合调用（domain/path 必须与设置时一致）。
  ///
  /// 验证项：V1（iOS HTTPCookie host-only 行为）。
  Future<bool> deleteExactCookie({
    required String url,
    required String name,
    required String? domain,
    required String path,
  }) async {
    invalidateReads();
    try {
      return await _deleteExactCookie(
        url: url,
        name: name,
        domain: domain,
        path: path,
      );
    } finally {
      invalidateReads();
    }
  }

  Future<bool> _deleteExactCookie({
    required String url,
    required String name,
    required String? domain,
    required String path,
  }) async {
    if (_hasDartFallback) {
      return RawCookieWriterFallback.instance.deleteExactCookie(
        url: url,
        name: name,
        domain: domain,
        path: path,
      );
    }
    try {
      final result = await _channel.invokeMethod<bool>('deleteExactCookie', {
        'url': url,
        'name': name,
        'domain': domain,
        'path': path,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('[RawCookieWriter] deleteExactCookie failed: $e');
      return false;
    } on MissingPluginException {
      debugPrint('[RawCookieWriter] Platform channel not available');
      return false;
    }
  }

  /// 读取指定 url 下所有 cookie 的完整信息。
  ///
  /// 平台差异：
  /// - iOS / macOS：`WKHTTPCookieStore.getAllCookies()` 返回完整字段
  /// - Android（新 WebView）：通过 `WebViewCompat.getCookieInfo` 返回完整字段
  /// - Android（旧 WebView）：仅能拿到 name + value，其它字段为 null
  ///
  /// 验证项：V12（flutter_inappwebview Android getCookies 实际行为）。
  Future<List<CookieFullInfo>> getAllCookieInfos(String url) async {
    final uri = Uri.parse(url);
    final key = uri.replace(query: '', fragment: '').toString();
    final existing = _reads[key];
    if (existing != null) return existing;
    // Keep this shorter than Sentinel's lock-acquisition timeout. A stalled
    // platform read must not hold a per-name lock or the shared read forever.
    // Writes/deletes deliberately do not use this timeout: they can finish late.
    final read = _readAllCookieInfos(url).timeout(
      _readTimeout,
      onTimeout: () {
        CookieLogger.readTimeout(url: url, elapsed: _readTimeout);
        throw CookieStoreReadTimeout(_readTimeout);
      },
    );
    _reads[key] = read;
    try {
      return await read;
    } finally {
      if (identical(_reads[key], read)) _reads.remove(key);
    }
  }

  Future<List<CookieFullInfo>> _readAllCookieInfos(String url) async {
    if (_hasDartFallback) {
      return RawCookieWriterFallback.instance.getAllCookieInfos(url);
    }
    try {
      final raw = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
        'getAllCookieInfos',
        {'url': url},
      );
      if (raw == null) return const [];
      return raw
          .map((m) {
            final map = Map<String, dynamic>.from(m);
            return CookieFullInfo(
              name: map['name'] as String? ?? '',
              value: map['value'] as String? ?? '',
              domain: map['domain'] as String?,
              path: map['path'] as String?,
              isSecure: map['isSecure'] as bool?,
              isHttpOnly: map['isHttpOnly'] as bool?,
              expiresMillis: map['expiresMillis'] as int?,
              sameSite: map['sameSite'] as String?,
              isPartitioned: map['partitioned'] as bool?,
            );
          })
          .where((cookie) {
            // Apple 的原生枚举按域名返回，补上 host-only 对子域的隔离。
            if (!io.Platform.isMacOS && !io.Platform.isIOS) return true;
            final domain = cookie.domain;
            return domain == null ||
                domain.startsWith('.') ||
                domain.toLowerCase() == Uri.parse(url).host.toLowerCase();
          })
          .toList(growable: false);
    } on PlatformException catch (e) {
      debugPrint('[RawCookieWriter] getAllCookieInfos failed: $e');
      return const [];
    } on MissingPluginException {
      debugPrint('[RawCookieWriter] Platform channel not available');
      return const [];
    }
  }

  /// 统计指定 url 下 cookie name 的变体数量。
  ///
  /// 在 Android 上基于 `CookieManager.getCookie(url)` 拼接字符串拆分计数。
  /// 在 iOS 上基于 `getAllCookies` 过滤。
  ///
  /// 复用并发的完整快照，在 Dart 侧计数，避免逐名称发起原生枚举。
  Future<int> countCookiesByName(String url, String name) async {
    final snapshot = await getAllCookieInfos(url);
    return snapshot.where((cookie) => cookie.name == name).length;
  }
}
