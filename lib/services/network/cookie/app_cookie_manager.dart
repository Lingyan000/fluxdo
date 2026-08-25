import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import '../../auth_session.dart';
import '../../log/log_writer.dart';
import '../flux_request_spec.dart';
import 'cookie_jar_service.dart';
import 'raw_cookie_writer.dart';
import 'session_cookie_sentinel.dart';

/// App-specific CookieManager.
/// Avoids saving Set-Cookie into redirect target domains by default.
class AppCookieManager extends Interceptor {
  AppCookieManager(this.cookieJar, {this.saveRedirectedCookies = false});

  /// The cookie jar used to load and save cookies.
  final CookieJar cookieJar;

  static const String skipCookieManagerExtraKey = 'skipCookieManager';

  /// Whether to also save Set-Cookie to redirect target domains when
  /// followRedirects is false. Default false to avoid cross-domain pollution.
  final bool saveRedirectedCookies;

  static final _setCookieReg = RegExp('(?<=)(,)(?=[^;]+?=)');

  // v0.4.0 路径分流标记
  // 路径 A (纯 Dio): 默认, jar 是权威源, 写 jar 后 sweep 同步到 WV
  // 路径 B (WebViewHttpAdapter): WV 是权威源, 跳过 critical 的 jar 写入,
  //                              sweep 后从 WV 反向同步到 jar
  // 设计依据: docs/cookie-sync-design-v0.4.0.md §5.5
  static const String _viaExtraKey = '_via';
  static const String _viaAdapter = 'wv-adapter';

  /// 标记请求来自 WebViewHttpAdapter (路径 B)。
  /// 由 WebViewHttpAdapter.fetch 入口调用。
  static void markAsWebViewAdapter(RequestOptions options) {
    options.extra[_viaExtraKey] = _viaAdapter;
  }

  /// 判定 cookie 的 sweep 意图。
  /// 服务器下发 value=del / 空值 / 已过期时按 [SweepIntent.delete] 处理。
  static SweepIntent _intentForCookie(Cookie cookie) {
    if (cookie.value == 'del' || cookie.value.isEmpty) {
      return SweepIntent.delete;
    }
    final expires = cookie.expires;
    if (expires != null && expires.isBefore(DateTime.now())) {
      return SweepIntent.delete;
    }
    return SweepIntent.ensureUnique;
  }

  static Map<String, SweepIntent> _finalAuthCookieIntents(
    Iterable<Cookie> cookies,
  ) {
    final result = <String, SweepIntent>{};
    for (final cookie in cookies) {
      if (!CookieJarService.hostOnlyCookieNames.contains(cookie.name)) {
        continue;
      }
      result[cookie.name] = _intentForCookie(cookie);
    }
    return result;
  }

  Future<void> _deleteAuthCookieVariantsIfManaged({
    required Iterable<String> names,
    required String reason,
  }) async {
    final authNames = names
        .where(CookieJarService.hostOnlyCookieNames.contains)
        .toSet();
    if (authNames.isEmpty) return;

    final service = CookieJarService();
    if (!service.isInitialized) return;
    if (!identical(cookieJar, service.cookieJar)) return;

    for (final name in authNames) {
      debugPrint(
        '[CookieManager] delete auth cookie variants: name=$name reason=$reason',
      );
      await service.deleteCookie(name);
    }
  }

  Future<void> _enforceAuthCookiePolicyIfManaged({
    required Iterable<String> names,
    required String reason,
  }) async {
    final authNames = names
        .where(CookieJarService.hostOnlyCookieNames.contains)
        .toSet();
    if (authNames.isEmpty) return;

    final service = CookieJarService();
    if (!service.isInitialized) return;
    if (!identical(cookieJar, service.cookieJar)) return;

    await service.enforceAuthCookiePolicy(reason: reason, names: authNames);
  }

  Future<String?> _canonicalAuthSetCookieHeaderIfManaged(String name) async {
    if (!CookieJarService.hostOnlyCookieNames.contains(name)) return null;
    final service = CookieJarService();
    if (!service.isInitialized) return null;
    if (!identical(cookieJar, service.cookieJar)) return null;
    final canonical = await service.getCanonicalCookie(name);
    return canonical?.toSetCookieHeader();
  }

  /// Select cookies for a request.
  /// Cookies with longer paths are listed before cookies with shorter paths.
  /// 同名 cookie 去重：优先保留 host-only cookie，避免重复发送。
  ///
  /// host-only cookie 来自服务器 Set-Cookie 响应（无 domain 属性），
  /// 代表服务器最新轮换的值（如 _t 会话 token）。
  /// domain cookie 来自 syncFromWebView（WKWebView 自动添加 domain），
  /// 可能是旧值。优先 host-only 确保发送服务器最新认可的值。
  /// 测试用:直接对给定 cookie 列表跑发请求选优,返回最终发送顺序。
  /// 绕过真实 CookieJar 的落库去重,便于验证 cf_clearance 双变体选优。
  @visibleForTesting
  static List<Cookie> selectCookiesForTest(List<Cookie> cookies, Uri uri) =>
      _selectCookies(cookies, uri);

  static List<Cookie> _selectCookies(List<Cookie> cookies, Uri uri) {
    final requestHost = uri.host.toLowerCase();
    final baseHost = CookieJarService.appBaseHost;
    final sortedCookies = [...cookies]
      ..sort((a, b) {
        if (a.path == null && b.path == null) {
          return 0;
        } else if (a.path == null) {
          return -1;
        } else if (b.path == null) {
          return 1;
        } else {
          return b.path!.length.compareTo(a.path!.length);
        }
      });

    final selected = <String, Cookie>{};
    for (final cookie in sortedCookies) {
      final isHostOnlyAuth = CookieJarService.hostOnlyCookieNames.contains(
        cookie.name,
      );
      if (isHostOnlyAuth && requestHost != baseHost) {
        continue;
      }
      final key = isHostOnlyAuth
          ? cookie.name
          : '${cookie.name}|${cookie.path ?? '/'}';
      final existing = selected[key];
      if (existing == null ||
          _compareCookiePriority(cookie, existing, requestHost) > 0) {
        selected[key] = cookie;
      }
    }

    final deduped = selected.values.toList()
      ..sort((a, b) {
        final pathA = a.path?.length ?? 0;
        final pathB = b.path?.length ?? 0;
        final pathCompare = pathB.compareTo(pathA);
        if (pathCompare != 0) return pathCompare;
        return _compareCookiePriority(b, a, requestHost);
      });

    return deduped;
  }

  static int _compareCookiePriority(
    Cookie candidate,
    Cookie existing,
    String requestHost,
  ) {
    final scoreDiff =
        _cookiePriorityScore(candidate, requestHost) -
        _cookiePriorityScore(existing, requestHost);
    if (scoreDiff != 0) return scoreDiff;

    final candidateDomainLength =
        candidate.domain?.replaceFirst(RegExp(r'^\.'), '').length ?? 0;
    final existingDomainLength =
        existing.domain?.replaceFirst(RegExp(r'^\.'), '').length ?? 0;
    final domainLengthDiff = candidateDomainLength.compareTo(
      existingDomainLength,
    );
    if (domainLengthDiff != 0) return domainLengthDiff;

    // 同分同域时按过期时间取最新("取新"兜底):cf_clearance 只由 WebView 里
    // 的 CF 更新、单向流回 jar;万一 jar 里同名多枚,后签发的过期更晚、即当前
    // 有效那枚。native 侧拿不到分区等更强信号,取新是最优兜底(与写侧
    // BoundarySync._selectBestWebViewCookie 的 expiresDate 决胜口径一致)。
    final candidateExpires = candidate.expires;
    final existingExpires = existing.expires;
    if (candidateExpires != null &&
        existingExpires != null &&
        candidateExpires != existingExpires) {
      return candidateExpires.compareTo(existingExpires);
    }
    if ((candidateExpires == null) != (existingExpires == null)) {
      // 持久 cookie(带过期时间)胜过会话 cookie
      return candidateExpires != null ? 1 : -1;
    }
    return candidate.value.length.compareTo(existing.value.length);
  }

  static int _cookiePriorityScore(Cookie cookie, String requestHost) {
    final normalizedDomain = cookie.domain?.trim().toLowerCase().replaceFirst(
      RegExp(r'^\.'),
      '',
    );
    final isHostOnlyAuth = CookieJarService.hostOnlyCookieNames.contains(
      cookie.name,
    );
    final isRootPath = (cookie.path == null || cookie.path == '/');

    var score = 0;
    if (normalizedDomain == null || normalizedDomain.isEmpty) {
      score = 10000;
    } else if (normalizedDomain == requestHost) {
      score = 9000 + normalizedDomain.length;
    } else if (requestHost.endsWith('.$normalizedDomain')) {
      score = 1000 + normalizedDomain.length;
    } else {
      score = normalizedDomain.length;
    }

    if (isHostOnlyAuth) {
      if (requestHost == CookieJarService.appBaseHost) score += 2000;
      if (isRootPath) score += 1500;
      if (cookie.httpOnly) score += 250;
      if (cookie.secure) score += 250;
    }
    return score;
  }

  static bool _isCfChallengePlatformRequest(RequestOptions options) {
    // challenge-platform 请求由 WebView 内的注入脚本发起,dio 侧只按 URL
    // 路径识别(历史上曾有 extra 标记通道,写入方已随 CF 验证改走 WebView 移除)。
    return options.uri.path.toLowerCase().contains(
      '/cdn-cgi/challenge-platform/',
    );
  }

  static bool _isCloudflareCookieName(String name) {
    final normalized = name.toLowerCase();
    return normalized == 'cf_clearance' ||
        normalized.startsWith('__cf') ||
        normalized.startsWith('cf_');
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[skipCookieManagerExtraKey] == true) {
      handler.next(options);
      return;
    }

    try {
      final cookies = await loadCookies(options);
      options.headers[HttpHeaders.cookieHeader] = cookies.isNotEmpty
          ? cookies
          : null;
      handler.next(options);
    } catch (e, s) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: e,
          stackTrace: s,
          message: 'Failed to load cookies for the request.',
        ),
        true,
      );
    }
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    if (response.requestOptions.extra[skipCookieManagerExtraKey] == true) {
      handler.next(response);
      return;
    }

    try {
      await saveCookies(response);
      handler.next(response);
    } catch (e, s) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.unknown,
          error: e,
          stackTrace: s,
          message: 'Failed to save cookies from the response.',
        ),
        true,
      );
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    if (response == null) {
      handler.next(err);
      return;
    }
    if (err.requestOptions.extra[skipCookieManagerExtraKey] == true) {
      handler.next(err);
      return;
    }
    try {
      await saveCookies(response);
      handler.next(err);
    } catch (e, s) {
      handler.next(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.unknown,
          error: e,
          stackTrace: s,
          message: 'Failed to save cookies from the error response.',
        ),
      );
    }
  }

  /// Load cookies in cookie string for the request.
  Future<String> loadCookies(RequestOptions options) async {
    List<Cookie> savedCookies;
    try {
      savedCookies = await cookieJar.loadForRequest(options.uri);
    } on FormatException catch (e) {
      debugPrint(
        '[CookieManager] loadForRequest format fallback for '
        '${options.uri}: $e',
      );
      if (cookieJar is EnhancedPersistCookieJar) {
        final canonicalCookies = await (cookieJar as EnhancedPersistCookieJar)
            .loadCanonicalForRequest(options.uri);
        savedCookies = canonicalCookies
            .map((cookie) => cookie.toIoCookie())
            .toList(growable: false);
      } else {
        rethrow;
      }
    }
    final requestCookies = _isCfChallengePlatformRequest(options)
        ? savedCookies
              .where((cookie) => _isCloudflareCookieName(cookie.name))
              .toList(growable: false)
        : savedCookies;

    if (_isCfChallengePlatformRequest(options)) {
      final cookieNames =
          requestCookies.map((cookie) => cookie.name).toSet().toList()..sort();
      debugPrint(
        '[CookieManager] isolated CF request cookies: '
        'uri=${options.uri.host}${options.uri.path}, names=$cookieNames',
      );
    }

    // 诊断：记录 _t cookie 的 host-only/domain 变体
    final tCookies = requestCookies.where((c) => c.name == '_t').toList();
    if (tCookies.length > 1) {
      final hostOnly = tCookies
          .where((c) => c.domain == null)
          .map((c) => c.value.length);
      final domain = tCookies
          .where((c) => c.domain != null)
          .map((c) => '${c.domain}:${c.value.length}');
      debugPrint(
        '[CookieManager] _t 多副本: hostOnly=$hostOnly, domain=$domain, '
        'uri=${options.uri.host}${options.uri.path}',
      );
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'cookie_conflict',
        'event': 'duplicate_t_cookie_on_request',
        'message': '_t 在请求前存在多副本',
        'host': options.uri.host,
        'path': options.uri.path,
        'cookies': tCookies
            .map(
              (cookie) => {
                'domain': cookie.domain,
                'path': cookie.path,
                'valueLength': cookie.value.length,
                'hostOnly': cookie.domain == null,
              },
            )
            .toList(growable: false),
      });
    }

    final selectedCookies = _selectCookies(requestCookies, options.uri);
    final cookies = selectedCookies
        .map(
          (cookie) => '${cookie.name}=${CookieValueCodec.decode(cookie.value)}',
        )
        .join('; ');
    // 仅多副本（异常态）时记录选优结果；登录后 _t 恒存在，
    // 单副本场景不值得每个请求落一次盘。
    if (tCookies.length > 1) {
      final selectedTCookies = selectedCookies
          .where((cookie) => cookie.name == '_t')
          .toList(growable: false);
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'cookie_conflict',
        'event': 't_cookie_selected_for_request',
        'message': '请求发送前已完成 _t 选优',
        'host': options.uri.host,
        'path': options.uri.path,
        'duplicateCount': tCookies.length,
        'selectedCount': selectedTCookies.length,
        'selectedTokenLengths': selectedTCookies
            .map((cookie) => cookie.value.length)
            .toList(growable: false),
        'selectedCookies': selectedTCookies
            .map(
              (cookie) => {
                'domain': cookie.domain,
                'path': cookie.path,
                'hostOnly': cookie.domain == null,
                'valueLength': cookie.value.length,
              },
            )
            .toList(growable: false),
      });
    }

    if (options.uri.host == 'connect.linux.do') {
      final authCookies = requestCookies
          .where((cookie) => cookie.name == 'auth.session-token')
          .map(
            (cookie) =>
                '${cookie.domain ?? '<host-only>'}|${cookie.path ?? '/'}|len=${cookie.value.length}',
          )
          .toList(growable: false);
      if (authCookies.isNotEmpty) {
        debugPrint(
          '[CookieManager] request cookies for connect.linux.do: $authCookies',
        );
      } else {
        debugPrint(
          '[CookieManager] request cookies for connect.linux.do: <none>',
        );
      }
    }

    return cookies;
  }

  /// Save cookies from the response including redirected requests.
  Future<void> saveCookies(Response response) async {
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies == null || setCookies.isEmpty) {
      return;
    }

    final requestGeneration =
        response.requestOptions.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      debugPrint(
        '[CookieManager] Skip stale response cookies: '
        'gen=$requestGeneration, current=${AuthSession().generation}, '
        'uri=${response.requestOptions.uri}',
      );
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'cookie_trace',
        'event': 'skip_stale_response_cookies',
        'message': '已丢弃过期会话响应中的 Set-Cookie',
        'requestGeneration': requestGeneration,
        'currentGeneration': AuthSession().generation,
        'url': response.requestOptions.uri.toString(),
      });
      return;
    }

    final flattenedSetCookies = setCookies
        .map((str) => str.split(_setCookieReg))
        .expand((cookie) => cookie)
        .where((cookie) => cookie.isNotEmpty)
        .toList(growable: false);

    final locationHeader = response.headers.value(HttpHeaders.locationHeader);
    final requestUri = response.requestOptions.uri;
    final hasAuthSessionToken = flattenedSetCookies.any(
      (header) => header.toLowerCase().startsWith('auth.session-token='),
    );
    if (hasAuthSessionToken) {
      debugPrint(
        '[CookieManager] auth.session-token Set-Cookie from '
        '${response.requestOptions.method} ${requestUri.toString()} '
        '(status=${response.statusCode}, location=$locationHeader, '
        'allowRedirectSetCookie=${response.requestOptions.spec.allowRedirectSetCookie})',
      );
      for (final header in flattenedSetCookies.where(
        (item) => item.toLowerCase().startsWith('auth.session-token='),
      )) {
        debugPrint('[CookieManager] auth.session-token raw: $header');
      }
    }

    final List<Cookie> cookies = flattenedSetCookies
        .map((str) => Cookie.fromSetCookieValue(str))
        .toList();

    final isCfChallengePlatform = _isCfChallengePlatformRequest(
      response.requestOptions,
    );
    final filteredCookies = <Cookie>[];
    final filteredSetCookieHeaders = <String>[];
    for (var i = 0; i < cookies.length; i++) {
      final cookie = cookies[i];
      if (isCfChallengePlatform && !_isCloudflareCookieName(cookie.name)) {
        debugPrint(
          '[CookieManager] drop non-CF cookie from challenge-platform response: '
          '${cookie.name}, uri=${response.requestOptions.uri}',
        );
        continue;
      }

      final isSessionCookie =
          cookie.name == '_t' || cookie.name == '_forum_session';
      if (isSessionCookie) {
        final isExpired =
            cookie.expires != null && cookie.expires!.isBefore(DateTime.now());
        final isDeletion =
            cookie.value == 'del' || cookie.value.isEmpty || isExpired;
        final uri = response.requestOptions.uri;

        // Mixed signal 保护：2xx/3xx + discourse-logged-out 但非 not_logged_in
        // 时，拦截 session cookie 的删除指令。
        // 这种矛盾信号（请求成功但 header 要求登出）不应直接删除 cookie，
        // 由 _auth.dart 的 probe 机制决定是否真正登出。
        if (isDeletion) {
          final statusCode = response.statusCode ?? 0;
          final hasLoggedOutHeader =
              response.headers.value('discourse-logged-out')?.isNotEmpty ==
              true;
          final responseBody = response.data;
          final hasNotLoggedInError =
              responseBody is Map &&
              responseBody['error_type'] == 'not_logged_in';

          if (statusCode < 400 && hasLoggedOutHeader && !hasNotLoggedInError) {
            debugPrint(
              '[CookieManager] ${cookie.name} DEL(blocked/mixed-signal) '
              'from ${response.requestOptions.method} ${uri.host}${uri.path} '
              '(status=$statusCode)',
            );
            LogWriter.instance.write({
              'timestamp': DateTime.now().toIso8601String(),
              'level': 'warning',
              'type': 'cookie_change',
              'event': 'token_cookie_delete_blocked_mixed_signal',
              'message':
                  '${cookie.name} 删除被拦截（$statusCode + discourse-logged-out 矛盾信号）',
              'statusCode': statusCode,
              'method': response.requestOptions.method,
              'url': uri.path,
              'fullUrl': uri.toString(),
            });
            continue;
          }
        }

        debugPrint(
          '[CookieManager] ${cookie.name} ${isDeletion ? "DEL" : "SET"} '
          'from ${response.requestOptions.method} ${uri.host}${uri.path} '
          '(status=${response.statusCode}, len=${cookie.value.length}, '
          'domain=${cookie.domain}, hasLoggedIn=${response.requestOptions.headers['Discourse-Logged-In']})',
        );
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': isDeletion ? 'warning' : 'info',
          'type': 'cookie_change',
          'event': isDeletion ? 'token_cookie_deleted' : 'token_cookie_updated',
          'message': isDeletion
              ? '${cookie.name} cookie 被删除'
              : '${cookie.name} cookie 被更新',
          'valueLength': cookie.value.length,
          'isExpired': isExpired,
          'method': response.requestOptions.method,
          'url': uri.path,
          'fullUrl': uri.toString(),
          'statusCode': response.statusCode,
          'cookieDomain': cookie.domain,
          'hasLoggedInHeader':
              response.requestOptions.headers['Discourse-Logged-In'] == 'true',
          'hasLoggedOutHeader':
              response.headers.value('discourse-logged-out')?.isNotEmpty ==
              true,
        });
      }
      filteredCookies.add(cookie);
      filteredSetCookieHeaders.add(flattenedSetCookies[i]);
    }

    // Save cookies for the original site.
    final originalUri = response.requestOptions.uri;
    final resolvedUri = originalUri.resolveUri(response.realUri);
    final enhancedJar = cookieJar is EnhancedPersistCookieJar
        ? cookieJar as EnhancedPersistCookieJar
        : null;

    // 路径判别 (v0.4.0):
    // - 路径 A (默认): 全部写 jar, 后续 sweep 同步到 WV
    // - 路径 B (WebViewHttpAdapter): critical cookies 跳过 jar 写入,
    //   后续 sweep 从 WV 反向同步到 jar (WV 已自写)
    final isPathB = response.requestOptions.extra[_viaExtraKey] == _viaAdapter;
    final criticalNames = SessionCookieSentinel.criticalCookieNames;

    final cookiesToSaveToJar = <Cookie>[];
    final headersToSaveToJar = <String>[];
    for (var i = 0; i < filteredCookies.length; i++) {
      final cookie = filteredCookies[i];
      final isCritical = criticalNames.contains(cookie.name);
      // 路径 B 时跳过 critical cookies 的 jar 写入 (boundary_sync 反向同步)
      // 注: 这里仍按 critical 判断 — boundary_sync_service 也是按
      // critical 集合做 WV→jar 同步,两者必须配对。
      if (isPathB && isCritical) continue;
      cookiesToSaveToJar.add(cookie);
      headersToSaveToJar.add(filteredSetCookieHeaders[i]);
    }

    if (cookiesToSaveToJar.isNotEmpty) {
      if (enhancedJar != null) {
        // dio 响应的 Set-Cookie 是服务器直发的权威值，标记 trusted 让它升 version，
        // 盖过 WebView 泛读可能带回的旧残留。
        await enhancedJar.saveFromSetCookieHeaders(
          resolvedUri,
          headersToSaveToJar,
          trusted: true,
        );
      } else {
        await cookieJar.saveFromResponse(resolvedUri, cookiesToSaveToJar);
      }
    }
    final authIntents = _finalAuthCookieIntents(cookiesToSaveToJar);
    await _deleteAuthCookieVariantsIfManaged(
      names: authIntents.entries
          .where((entry) => entry.value == SweepIntent.delete)
          .map((entry) => entry.key),
      reason: 'dio_response_delete',
    );
    await _enforceAuthCookiePolicyIfManaged(
      names: authIntents.entries
          .where((entry) => entry.value == SweepIntent.ensureUnique)
          .map((entry) => entry.key),
      reason: 'dio_response',
    );

    if (hasAuthSessionToken) {
      debugPrint(
        '[CookieManager] auth.session-token primary save uri: '
        '${resolvedUri.toString()} (pathB=$isPathB)',
      );
    }

    // dio→WebView 增量同步（仅路径 A）：critical cookie 的新值立即推 WebView。
    // 破除 "WV 只有 1 份旧值 → sweep ensureUnique 直接 noop 不更新" 的死角，
    // 避免必须重启 priming 才同步（用户反馈的 dio→WV 不及时）。删除指令交给
    // 下面的 sweep delete 处理。
    if (!isPathB) {
      for (var i = 0; i < filteredCookies.length; i++) {
        final cookie = filteredCookies[i];
        if (!criticalNames.contains(cookie.name)) continue;
        // cf_clearance 只在 WebView 中由 CF 更新,Dio 侧永远不产新值——
        // 绝不从 Dio 侧回推它到 WebView(会丢 Partitioned 造非分区副本)。
        if (cookie.name == 'cf_clearance') continue;
        if (_intentForCookie(cookie) == SweepIntent.delete) continue;
        final rawSetCookie =
            await _canonicalAuthSetCookieHeaderIfManaged(cookie.name) ??
            filteredSetCookieHeaders[i];
        await RawCookieWriter.instance.setRawCookie(
          resolvedUri.toString(),
          rawSetCookie,
          writeSharedStorage: cookie.name != 'cf_clearance',
        );
      }
    }

    // 对响应里 *所有* cookie 触发 sweep (不再按 critical 过滤):
    // - 路径 A: sweep 内部从 jar 读 winner 写 WV (保证两端一致)
    // - 路径 B: sweep 内部从 WV 读 winner 反向写 jar (WV 已自写)
    // 全量 sweep 是为了不漏掉新业务 cookie (如 LDC/CDK 等)。
    // 同步等所有 sweep 完成,保证 next handler 时两端一致。
    if (filteredCookies.isNotEmpty) {
      final sweepFutures = filteredCookies.map((cookie) {
        return SessionCookieSentinel.instance.sweep(
          resolvedUri.toString(),
          cookie.name,
          intent: _intentForCookie(cookie),
        );
      }).toList();
      await Future.wait(sweepFutures);
    }

    // Optionally save cookies for redirected locations.
    final allowRedirectSave =
        response.requestOptions.spec.allowRedirectSetCookie;
    if (!(saveRedirectedCookies || allowRedirectSave)) {
      return;
    }

    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? [];
    final redirected = statusCode >= 300 && statusCode < 400;
    if (redirected && locations.isNotEmpty) {
      final baseUri = response.realUri;
      await Future.wait(
        locations.map((location) async {
          final redirectUri = baseUri.resolve(location);
          if (hasAuthSessionToken) {
            debugPrint(
              '[CookieManager] auth.session-token redirect save uri: '
              '${redirectUri.toString()}',
            );
          }
          await cookieJar.saveFromResponse(redirectUri, filteredCookies);
          final redirectAuthIntents = _finalAuthCookieIntents(filteredCookies);
          await _deleteAuthCookieVariantsIfManaged(
            names: redirectAuthIntents.entries
                .where((entry) => entry.value == SweepIntent.delete)
                .map((entry) => entry.key),
            reason: 'redirect_response_delete',
          );
          await _enforceAuthCookiePolicyIfManaged(
            names: redirectAuthIntents.entries
                .where((entry) => entry.value == SweepIntent.ensureUnique)
                .map((entry) => entry.key),
            reason: 'redirect_response',
          );
        }),
      );
    }
  }
}
