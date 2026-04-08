import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

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

  /// Merge cookies into a Cookie string.
  /// Cookies with longer paths are listed before cookies with shorter paths.
  /// 同名 cookie 去重：优先保留 host-only cookie，避免重复发送。
  ///
  /// host-only cookie 来自服务器 Set-Cookie 响应（无 domain 属性），
  /// 代表服务器最新轮换的值（如 _t 会话 token）。
  /// domain cookie 来自 syncFromWebView（WKWebView 自动添加 domain），
  /// 可能是旧值。优先 host-only 确保发送服务器最新认可的值。
  static String _mergeCookies(List<Cookie> cookies, Uri uri) {
    final requestHost = uri.host.toLowerCase();
    cookies.sort((a, b) {
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
    for (final cookie in cookies) {
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

    return deduped.map((cookie) => '${cookie.name}=${CookieValueCodec.decode(cookie.value)}').join('; ');
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
    final previousCookies =
        options.headers[HttpHeaders.cookieHeader] as String?;
    final allCookies = [
      ...?previousCookies
          ?.split(';')
          .where((e) => e.isNotEmpty)
          .map((c) => Cookie.fromSetCookieValue(c)),
      ...savedCookies,
    ];

    // 诊断：记录 _t cookie 的 host-only/domain 变体
    final tCookies = allCookies.where((c) => c.name == '_t').toList();
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

    final cookies = _mergeCookies(allCookies, options.uri);
    if (tCookies.isNotEmpty) {
      final selectedTCookies = cookies
          .split('; ')
          .where((entry) => entry.startsWith('_t='))
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
            .map((entry) => entry.length - 3)
            .toList(growable: false),
      });
    }

    if (options.uri.host == 'connect.linux.do') {
      final authCookies = allCookies
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

    // 会话 cookie 删除指令仍需非常保守。
    // 实测里服务端会在 200 响应的公开/半公开接口上带 discourse-logged-out，
    // 甚至同时返回可渲染数据；如果此时直接接受 _t 删除，会把“混合信号”放大成
    // 真掉线，造成频繁退出，甚至出现“页面还在、真实会话已被本地删掉”的假状态。
    // 因此这里只信任以下强证据：
    // - 响应体明确 error_type=not_logged_in
    // - /session/current 明确返回 current_user=null
    // - 明确需要登录的接口直接返回 401/403
    // 单独的 discourse-logged-out header（尤其是 2xx 成功响应）不再直接删除会话 cookie。
    final filteredCookies = <Cookie>[];
    final filteredSetCookieHeaders = <String>[];
    final responseBody = response.data;
    final hasNotLoggedInError =
        responseBody is Map && responseBody['error_type'] == 'not_logged_in';
    final hasLoggedOutHeader =
        response.headers.value('discourse-logged-out')?.isNotEmpty == true;
    final hasAnonymousSessionPayload =
        responseBody is Map &&
        responseBody.containsKey('current_user') &&
        responseBody['current_user'] == null;
    final isStrictAuthEndpoint =
        requestUri.path.startsWith('/presence/') ||
        requestUri.path.startsWith('/topics/timings') ||
        requestUri.path.startsWith('/notifications') ||
        requestUri.path.startsWith('/bookmarks') ||
        requestUri.path.startsWith('/drafts') ||
        requestUri.path.startsWith('/session/current');
    final ambiguousLoggedOutOnSuccess =
        hasLoggedOutHeader &&
        (response.statusCode != null && response.statusCode! < 400) &&
        !hasNotLoggedInError &&
        !hasAnonymousSessionPayload;
    final shouldTrustSessionDeletion =
        hasNotLoggedInError ||
        hasAnonymousSessionPayload ||
        ((response.statusCode == 401 || response.statusCode == 403) &&
            isStrictAuthEndpoint);

    for (var i = 0; i < cookies.length; i++) {
      final cookie = cookies[i];
      final isSessionCookie =
          cookie.name == '_t' || cookie.name == '_forum_session';
      if (isSessionCookie) {
        final isExpired = cookie.expires != null &&
            cookie.expires!.isBefore(DateTime.now());
        final isDeletion =
            cookie.value == 'del' || cookie.value.isEmpty || isExpired;
        final uri = response.requestOptions.uri;
        final allowDeletion = isDeletion && shouldTrustSessionDeletion;
        final shouldBlockSessionSet = !isDeletion && ambiguousLoggedOutOnSuccess;
        debugPrint('[CookieManager] ${cookie.name} '
            '${shouldBlockSessionSet ? "SET(blocked)" : (!isDeletion ? "SET" : (allowDeletion ? "DEL(accepted)" : "DEL(blocked)"))} '
            'from ${response.requestOptions.method} ${uri.host}${uri.path} '
            '(status=${response.statusCode}, len=${cookie.value.length}, '
            'domain=${cookie.domain}, hasLoggedIn=${response.requestOptions.headers['Discourse-Logged-In']})');
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': (isDeletion || shouldBlockSessionSet) ? 'warning' : 'info',
          'type': 'cookie_change',
          'event': shouldBlockSessionSet
              ? 'token_cookie_update_blocked_ambiguous_success'
              : (!isDeletion
                    ? 'token_cookie_updated'
                    : (allowDeletion
                          ? 'token_cookie_delete_accepted'
                          : (ambiguousLoggedOutOnSuccess
                                ? 'token_cookie_delete_blocked_ambiguous_success'
                                : 'token_cookie_delete_blocked'))),
          'message': shouldBlockSessionSet
              ? '${cookie.name} 更新被拦截（2xx 响应中的 mixed auth signal）'
              : (!isDeletion
                    ? '${cookie.name} cookie 被更新'
                    : (allowDeletion
                          ? '${cookie.name} 删除已接受（服务端会话失效证据充分）'
                          : (ambiguousLoggedOutOnSuccess
                                ? '${cookie.name} 删除被拦截（2xx 响应中的 mixed auth signal）'
                                : '${cookie.name} 删除被拦截'))),
          'valueLength': cookie.value.length,
          'isExpired': isExpired,
          'method': response.requestOptions.method,
          'url': uri.path,
          'fullUrl': uri.toString(),
          'statusCode': response.statusCode,
          'cookieDomain': cookie.domain,
          'hasLoggedInHeader': response.requestOptions.headers['Discourse-Logged-In'] == 'true',
          'hasLoggedOutHeader': hasLoggedOutHeader,
          'hasNotLoggedInError': hasNotLoggedInError,
          'hasAnonymousSessionPayload': hasAnonymousSessionPayload,
          'isStrictAuthEndpoint': isStrictAuthEndpoint,
          'ambiguousLoggedOutOnSuccess': ambiguousLoggedOutOnSuccess,
        });
        if ((isDeletion && !allowDeletion) || shouldBlockSessionSet) {
          continue;
        }
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
