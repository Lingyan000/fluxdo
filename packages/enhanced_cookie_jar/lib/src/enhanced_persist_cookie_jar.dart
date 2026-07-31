import 'dart:io' as io;

import 'package:cookie_jar/cookie_jar.dart' as base;

import 'canonical_cookie.dart';
import 'cdp_cookie_parser.dart';
import 'file_cookie_store.dart';
import 'set_cookie_parser.dart';

class EnhancedPersistCookieJar implements base.CookieJar {
  EnhancedPersistCookieJar(
      {required FileCookieStore store, this.ignoreExpires = false})
      : _store = store;

  final FileCookieStore _store;

  @override
  final bool ignoreExpires;

  List<CanonicalCookie>? _cache;

  /// 串行化所有"读-改-写"操作：并发保存会基于同一内存快照各自写回，
  /// 后者覆盖前者（lost update），且并发写同一临时文件会产生 rename 竞态。
  Future<void> _serial = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<List<CanonicalCookie>> readAllCookies() async =>
      List.unmodifiable(await _readAll());

  Future<List<CanonicalCookie>> _readAll() async {
    final cached = _cache;
    if (cached != null) return cached;
    final loaded = await _store.readAll();
    _cache = loaded;
    return loaded;
  }

  Future<void> _writeAll(List<CanonicalCookie> cookies) async {
    _cache = cookies;
    // 只持久化非过期 + 非 session 的 cookie，session cookie 仅保留在内存缓存中
    final toPersist = cookies.where(_shouldPersist).toList(growable: false);
    await _store.writeAll(toPersist);
  }

  /// 保存一组 CanonicalCookie，按 storageKey 去重。
  ///
  /// [trusted] 标记写入来源是否权威：
  /// - true（服务器 Set-Cookie / CF challenge 确认值）：值变化时升 version 盖过
  ///   泛读旧值；值未变则保持。
  /// - false（WebView 泛读，可能读到旧残留）：仅当比已有值更新鲜（[isFresherThan]）
  ///   时才覆盖，避免旧值盖掉权威新值。
  Future<void> saveCanonicalCookies(
    Uri uri,
    List<CanonicalCookie> cookies, {
    bool trusted = false,
  }) {
    if (cookies.isEmpty) return Future.value();
    return _synchronized(
      () => _saveCanonicalCookiesLocked(uri, cookies, trusted: trusted),
    );
  }

  Future<void> _saveCanonicalCookiesLocked(
    Uri uri,
    List<CanonicalCookie> cookies, {
    required bool trusted,
  }) async {
    final all = [...await _readAll()];
    for (final cookie in cookies) {
      var resolved = cookie.copyWith(
        domain: cookie.domain ?? uri.host.toLowerCase(),
        path: cookie.path.isEmpty ? '/' : cookie.path,
      );
      final idx = all
          .indexWhere((existing) => existing.storageKey == resolved.storageKey);
      if (idx >= 0) {
        final existing = all[idx];
        if (_isWebViewHostOnlyDowngrade(resolved, existing)) {
          continue;
        }
        if (trusted) {
          resolved = resolved.copyWith(
            version: existing.value == resolved.value
                ? existing.version
                : existing.version + 1,
          );
        } else if (!resolved.isFresherThan(existing)) {
          // 不可信且不更新鲜：保留已有的权威值，跳过本次写入。
          continue;
        }
        // RFC 6265 §5.3.11.3：替换同 key cookie 时继承 creation-time。
        // lastAccessTime 无消费方，一并继承使序列化结果稳定——
        // 服务器重复下发相同 cookie 时配合存储层脏检查跳过全量写盘。
        resolved = resolved.copyWith(
          creationTime: existing.creationTime,
          lastAccessTime: existing.lastAccessTime,
        );
        all.removeAt(idx);
      }
      if (ignoreExpires || !resolved.isExpired) {
        all.add(resolved);
      }
    }
    await _writeAll(all);
  }

  bool _isWebViewHostOnlyDowngrade(
    CanonicalCookie next,
    CanonicalCookie existing,
  ) {
    final fromWebView = next.source == CookieSource.webViewCdp ||
        next.source == CookieSource.webViewManager;
    return fromWebView &&
        next.value == existing.value &&
        next.hostOnly &&
        !existing.hostOnly &&
        next.normalizedDomain == existing.normalizedDomain &&
        next.path == existing.path &&
        next.partitionKey == existing.partitionKey;
  }

  Future<void> saveFromSetCookieHeaders(
    Uri uri,
    List<String> headers, {
    bool trusted = false,
  }) async {
    final cookies =
        headers.map((e) => SetCookieParser.parse(e, uri: uri)).toList();
    await saveCanonicalCookies(uri, cookies, trusted: trusted);
  }

  Future<void> saveFromCdpCookies(
    Uri uri,
    List<Map<String, dynamic>> rawCookies, {
    bool trusted = false,
  }) async {
    final cookies = rawCookies
        .map((e) => CdpCookieParser.parse(e, originUrl: uri.toString()))
        .whereType<CanonicalCookie>()
        .toList();
    await saveCanonicalCookies(uri, cookies, trusted: trusted);
  }

  Future<List<CanonicalCookie>> loadCanonicalForRequest(Uri uri) async {
    final all = await _readAll();
    final filtered = all
        .where((cookie) =>
            _matches(uri, cookie) && (ignoreExpires || !cookie.isExpired))
        .toList()
      ..sort((a, b) {
        final pathCompare = b.path.length.compareTo(a.path.length);
        if (pathCompare != 0) return pathCompare;

        final domainCompare = (b.normalizedDomain?.length ?? 0)
            .compareTo(a.normalizedDomain?.length ?? 0);
        if (domainCompare != 0) return domainCompare;

        if (a.hostOnly != b.hostOnly) {
          return a.hostOnly ? -1 : 1;
        }

        return a.creationTime.compareTo(b.creationTime);
      });
    return _dedupePartitionVariants(filtered);
  }

  /// 同名同域同路径、仅 partitionKey 不同的重复项只保留一条。
  ///
  /// CF 会把 cf_clearance 以 CHIPS 分区 cookie 重新签发，与 jar 中旧的
  /// 非分区条目 storageKey 不同而并存；一次请求发出两个同名 cookie 时
  /// 服务端可能读到旧值，导致反复弹盾。version 是 per-storageKey 计数器，
  /// 跨条目不可比，这里按 expiresAt / creationTime 判断新鲜度。
  List<CanonicalCookie> _dedupePartitionVariants(
    List<CanonicalCookie> cookies,
  ) {
    final byIdentity = <(String, String?, String), CanonicalCookie>{};
    final order = <(String, String?, String)>[];
    for (final cookie in cookies) {
      final key = (cookie.name, cookie.normalizedDomain, cookie.path);
      final existing = byIdentity[key];
      if (existing == null) {
        byIdentity[key] = cookie;
        order.add(key);
      } else if (_fresherAcrossPartitions(cookie, existing)) {
        byIdentity[key] = cookie;
      }
    }
    if (order.length == cookies.length) return cookies;
    return [for (final key in order) byIdentity[key]!];
  }

  bool _fresherAcrossPartitions(CanonicalCookie a, CanonicalCookie b) {
    final ea = a.expiresAt;
    final eb = b.expiresAt;
    if (ea != null && eb != null) {
      if (ea != eb) return ea.isAfter(eb);
    } else if (ea != null || eb != null) {
      return ea != null;
    }
    return a.creationTime.isAfter(b.creationTime);
  }

  @override
  Future<List<io.Cookie>> loadForRequest(Uri uri) async {
    final cookies = await loadCanonicalForRequest(uri);
    return cookies.map((e) => e.toIoCookie()).toList(growable: false);
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<io.Cookie> cookies) async {
    final canonical =
        cookies.map((e) => SetCookieParser.fromIoCookie(e, uri: uri)).toList();
    await saveCanonicalCookies(uri, canonical);
  }

  /// 与 [saveFromResponse] 相同，但可标记 [trusted]（CF challenge 等确认的权威
  /// 写入），升 version 盖过 WebView 泛读到的旧值。
  Future<void> saveFromResponseTrusted(
    Uri uri,
    List<io.Cookie> cookies, {
    bool trusted = false,
  }) async {
    final canonical =
        cookies.map((e) => SetCookieParser.fromIoCookie(e, uri: uri)).toList();
    await saveCanonicalCookies(uri, canonical, trusted: trusted);
  }

  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) {
    return _synchronized(() async {
      final all = [...await _readAll()];
      all.removeWhere((cookie) {
        final matchDomain = cookie.normalizedDomain ?? _originHost(cookie);
        if (cookie.hostOnly) return matchDomain == uri.host.toLowerCase();
        if (!withDomainSharedCookie) return false;
        return _domainMatches(uri.host, matchDomain);
      });
      await _writeAll(all);
    });
  }

  /// 按名称显式删除与 [uri] 站点相关的所有 cookie，返回删除条数。
  ///
  /// 与写入"已过期同名 cookie"的删除方式不同，本方法绕过 [CanonicalCookie.isFresherThan]
  /// 新鲜度仲裁——过期 cookie 永远比未过期的现有条目"旧"，会被仲裁静默跳过，
  /// 导致对未过期持久 cookie（如 cf_clearance）的删除变成 no-op。
  /// 显式删除是业务意图，不应被防 WebView 旧值回灌的机制拦截。
  ///
  /// 匹配范围：cookie 有效域等于 uri.host、是其子域、或是其父域
  /// （父域 domain cookie 对 uri.host 可见）。
  Future<int> deleteByName(Uri uri, String name) {
    return _synchronized(() async {
      final host = uri.host.toLowerCase();
      final all = [...await _readAll()];
      final before = all.length;
      all.removeWhere((cookie) {
        if (cookie.name != name) return false;
        return _isSiteRelated(host, cookie);
      });
      final removed = before - all.length;
      if (removed > 0) {
        await _writeAll(all);
      }
      return removed;
    });
  }

  /// 原子替换与 [uri] 站点相关的指定 name。
  ///
  /// 用于把 `_t` / `_forum_session` 这类站点单例 cookie 收敛为唯一规范
  /// 形态。相比先 [deleteByName] 再 [saveCanonicalCookies]，本方法在同一把
  /// jar 串行锁内完成，避免并发请求读到“已删未写”的半截状态。
  Future<int> replaceByNameForSite(
    Uri uri,
    String name,
    List<CanonicalCookie> replacements,
  ) {
    return _synchronized(() async {
      final host = uri.host.toLowerCase();
      final all = [...await _readAll()];
      final before = all.length;

      all.removeWhere((cookie) {
        if (cookie.name != name) return false;
        return _isSiteRelated(host, cookie);
      });

      final deduped = <String, CanonicalCookie>{};
      for (final cookie in replacements) {
        if (cookie.name != name) continue;
        var resolved = cookie.copyWith(
          domain: cookie.domain ?? host,
          path: cookie.path.isEmpty ? '/' : cookie.path,
        );
        if (!ignoreExpires && resolved.isExpired) continue;
        deduped[resolved.storageKey] = resolved;
      }
      all.addAll(deduped.values);

      final removed = before - (all.length - deduped.length);
      if (removed > 0 || deduped.isNotEmpty) {
        await _writeAll(all);
      }
      return removed;
    });
  }

  @override
  Future<void> deleteAll() {
    return _synchronized(() async {
      _cache = const [];
      await _store.deleteAll();
    });
  }

  /// 丢弃持久 cookie 的内存缓存并从磁盘重新加载。
  ///
  /// 用于另一个 isolate（如 iOS 后台轮询任务）写盘之后让本 isolate 看到新值，
  /// 避免之后用陈旧缓存全量覆盖文件、丢掉对方写入的 token。
  /// 文件中不存 session cookie，内存中现有的 session cookie 会被保留；
  /// 持久 cookie 以磁盘为准。
  Future<void> reloadPersistedCookies() {
    return _synchronized(() async {
      final cached = _cache;
      final fromDisk = await _store.readAll();
      if (cached == null) {
        _cache = fromDisk;
        return;
      }
      final diskKeys = fromDisk.map((c) => c.storageKey).toSet();
      _cache = [
        ...fromDisk,
        ...cached.where(
          (c) => !_shouldPersist(c) && !diskKeys.contains(c.storageKey),
        ),
      ];
    });
  }

  /// RFC 6265 §5.3: 有 expires/max-age 的是持久化 cookie，没有的是 session cookie
  /// session cookie 只保留在内存缓存中，不写入文件（与浏览器行为一致）
  bool _shouldPersist(CanonicalCookie cookie) {
    if (ignoreExpires) return true;
    if (cookie.isExpired) return false;
    return cookie.expiresAt != null || cookie.maxAge != null;
  }

  bool _matches(Uri uri, CanonicalCookie cookie) {
    final matchDomain = cookie.normalizedDomain ?? _originHost(cookie);
    if (!_domainMatches(uri.host, matchDomain, hostOnly: cookie.hostOnly)) {
      return false;
    }
    if (!_pathMatches(uri.path.isEmpty ? '/' : uri.path, cookie.path)) {
      return false;
    }
    if (cookie.secure && uri.scheme != 'https') return false;
    return true;
  }

  String? _originHost(CanonicalCookie cookie) {
    final originHost = Uri.tryParse(cookie.originUrl ?? '')?.host.trim();
    if (originHost == null || originHost.isEmpty) return null;
    return originHost.toLowerCase();
  }

  bool _isSiteRelated(String host, CanonicalCookie cookie) {
    final matchDomain = cookie.normalizedDomain ?? _originHost(cookie);
    if (matchDomain == null || matchDomain.isEmpty) return true;
    return host == matchDomain ||
        host.endsWith('.$matchDomain') ||
        matchDomain.endsWith('.$host');
  }

  bool _domainMatches(String host, String? cookieDomain,
      {bool hostOnly = false}) {
    final normalizedHost = host.toLowerCase();
    if (cookieDomain == null || cookieDomain.isEmpty) return false;
    if (hostOnly) return normalizedHost == cookieDomain;
    return normalizedHost == cookieDomain ||
        normalizedHost.endsWith('.$cookieDomain');
  }

  bool _pathMatches(String requestPath, String cookiePath) {
    final normalizedRequest = requestPath.isEmpty ? '/' : requestPath;
    final normalizedCookie = cookiePath.isEmpty ? '/' : cookiePath;
    if (normalizedCookie == '/' || normalizedRequest == normalizedCookie) {
      return true;
    }
    if (!normalizedRequest.startsWith(normalizedCookie)) return false;
    if (normalizedCookie.endsWith('/')) return true;
    return normalizedRequest.length > normalizedCookie.length &&
        normalizedRequest[normalizedCookie.length] == '/';
  }
}
