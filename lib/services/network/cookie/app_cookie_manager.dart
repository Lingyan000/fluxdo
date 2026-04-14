import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import '../../auth_session.dart';
import '../../log/log_writer.dart';
import 'cookie_jar_service.dart';
import 'raw_set_cookie_queue.dart';

/// App-specific CookieManager.
/// Avoids saving Set-Cookie into redirect target domains by default.
class AppCookieManager extends Interceptor {
  AppCookieManager(
    this.cookieJar, {
    this.saveRedirectedCookies = false,
  });

  /// The cookie jar used to load and save cookies.
  final CookieJar cookieJar;

  /// Whether to also save Set-Cookie to redirect target domains when
  /// followRedirects is false. Default false to avoid cross-domain pollution.
  final bool saveRedirectedCookies;

  static final _setCookieReg = RegExp('(?<=)(,)(?=[^;]+?=)');

  /// Select cookies for a request.
  /// Cookies with longer paths are listed before cookies with shorter paths.
  /// 同名 cookie 去重：优先保留 host-only cookie，避免重复发送。
  ///
  /// host-only cookie 来自服务器 Set-Cookie 响应（无 domain 属性），
  /// 代表服务器最新轮换的值（如 _t 会话 token）。
  /// domain cookie 来自 syncFromWebView（WKWebView 自动添加 domain），
  /// 可能是旧值。优先 host-only 确保发送服务器最新认可的值。
  static List<Cookie> _selectCookies(List<Cookie> cookies, Uri uri) {
    final requestHost = uri.host.toLowerCase();
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
      final key = '${cookie.name}|${cookie.path ?? '/'}';
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
    final domainLengthDiff =
        candidateDomainLength.compareTo(existingDomainLength);
    if (domainLengthDiff != 0) return domainLengthDiff;

    final candidateValueLength = candidate.value.length;
    final existingValueLength = existing.value.length;
    return candidateValueLength.compareTo(existingValueLength);
  }

  static int _cookiePriorityScore(Cookie cookie, String requestHost) {
    final normalizedDomain = cookie.domain
        ?.trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '');

    if (normalizedDomain == null || normalizedDomain.isEmpty) {
      return 10000;
    }
    if (normalizedDomain == requestHost) {
      return 9000 + normalizedDomain.length;
    }
    if (requestHost.endsWith('.$normalizedDomain')) {
      return 1000 + normalizedDomain.length;
    }
    return normalizedDomain.length;
  }

  static bool _isCfChallengePlatformRequest(RequestOptions options) {
    if (options.extra['isCfChallengePlatform'] == true) {
      return true;
    }
    return options.uri.path.toLowerCase().contains('/cdn-cgi/challenge-platform/');
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
    try {
      final cookies = await loadCookies(options);
      options.headers[HttpHeaders.cookieHeader] =
          cookies.isNotEmpty ? cookies : null;
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
      final cookieNames = requestCookies.map((cookie) => cookie.name).toSet().toList()
        ..sort();
      debugPrint(
        '[CookieManager] isolated CF request cookies: '
        'uri=${options.uri.host}${options.uri.path}, names=$cookieNames',
      );
    }

    // 诊断：记录 _t cookie 的 host-only/domain 变体
    final tCookies = requestCookies.where((c) => c.name == '_t').toList();
    if (tCookies.length > 1) {
      final hostOnly = tCookies.where((c) => c.domain == null).map((c) => c.value.length);
      final domain = tCookies.where((c) => c.domain != null).map((c) => '${c.domain}:${c.value.length}');
      debugPrint('[CookieManager] _t 多副本: hostOnly=$hostOnly, domain=$domain, '
          'uri=${options.uri.host}${options.uri.path}');
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
          (cookie) =>
              '${cookie.name}=${CookieValueCodec.decode(cookie.value)}',
        )
        .join('; ');
    if (tCookies.isNotEmpty) {
      final selectedTCookies = selectedCookies
          .where((cookie) => cookie.name == '_t')
          .toList(growable: false);
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': tCookies.length > 1 ? 'warning' : 'info',
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
        'allowRedirectSetCookie=${response.requestOptions.extra['allowRedirectSetCookie'] == true})',
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

      final isSessionCookie = cookie.name == '_t' || cookie.name == '_forum_session';
      if (isSessionCookie) {
        final isExpired = cookie.expires != null &&
            cookie.expires!.isBefore(DateTime.now());
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
              response.headers.value('discourse-logged-out')?.isNotEmpty == true;
          final responseBody = response.data;
          final hasNotLoggedInError =
              responseBody is Map && responseBody['error_type'] == 'not_logged_in';

          if (statusCode < 400 && hasLoggedOutHeader && !hasNotLoggedInError) {
            debugPrint('[CookieManager] ${cookie.name} DEL(blocked/mixed-signal) '
                'from ${response.requestOptions.method} ${uri.host}${uri.path} '
                '(status=$statusCode)');
            LogWriter.instance.write({
              'timestamp': DateTime.now().toIso8601String(),
              'level': 'warning',
              'type': 'cookie_change',
              'event': 'token_cookie_delete_blocked_mixed_signal',
              'message': '${cookie.name} 删除被拦截（$statusCode + discourse-logged-out 矛盾信号）',
              'statusCode': statusCode,
              'method': response.requestOptions.method,
              'url': uri.path,
              'fullUrl': uri.toString(),
            });
            continue;
          }
        }

        debugPrint('[CookieManager] ${cookie.name} ${isDeletion ? "DEL" : "SET"} '
            'from ${response.requestOptions.method} ${uri.host}${uri.path} '
            '(status=${response.statusCode}, len=${cookie.value.length}, '
            'domain=${cookie.domain}, hasLoggedIn=${response.requestOptions.headers['Discourse-Logged-In']})');
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': isDeletion ? 'warning' : 'info',
          'type': 'cookie_change',
          'event': isDeletion ? 'token_cookie_deleted' : 'token_cookie_updated',
          'message': isDeletion ? '${cookie.name} cookie 被删除' : '${cookie.name} cookie 被更新',
          'valueLength': cookie.value.length,
          'isExpired': isExpired,
          'method': response.requestOptions.method,
          'url': uri.path,
          'fullUrl': uri.toString(),
          'statusCode': response.statusCode,
          'cookieDomain': cookie.domain,
          'hasLoggedInHeader': response.requestOptions.headers['Discourse-Logged-In'] == 'true',
          'hasLoggedOutHeader': response.headers.value('discourse-logged-out')?.isNotEmpty == true,
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
    if (enhancedJar != null) {
      await enhancedJar.saveFromSetCookieHeaders(
        resolvedUri,
        filteredSetCookieHeaders,
      );
    } else {
      await cookieJar.saveFromResponse(
        resolvedUri,
        filteredCookies,
      );
    }

    if (hasAuthSessionToken) {
      debugPrint(
        '[CookieManager] auth.session-token primary save uri: '
        '${resolvedUri.toString()}',
      );
    }

    // 将原始 Set-Cookie 头逐条入队，供后续处理使用
    for (final rawHeader in filteredSetCookieHeaders) {
      RawSetCookieQueue.instance.enqueue(resolvedUri.toString(), rawHeader);
    }

    // Optionally save cookies for redirected locations.
    final allowRedirectSave = response.requestOptions.extra['allowRedirectSetCookie'] == true;
    if (!(saveRedirectedCookies || allowRedirectSave)) {
      return;
    }

    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? [];
    final redirected = statusCode >= 300 && statusCode < 400;
    if (redirected && locations.isNotEmpty) {
      final baseUri = response.realUri;
      await Future.wait(
        locations.map(
          (location) async {
            final redirectUri = baseUri.resolve(location);
            if (hasAuthSessionToken) {
              debugPrint(
                '[CookieManager] auth.session-token redirect save uri: '
                '${redirectUri.toString()}',
              );
            }
            await cookieJar.saveFromResponse(
              redirectUri,
              filteredCookies,
            );
          },
        ),
      );
    }
  }

}
