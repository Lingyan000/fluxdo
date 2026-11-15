import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_policy.dart';
import 'package:fluxdo/services/network/adapters/adapter_log_metadata.dart';
import 'package:fluxdo/services/network/cookie/csrf_session_trace.dart';

String masked(int pad) => base64Url
    .encode([...List.filled(32, pad), ...List.generate(32, (i) => i ^ pad)])
    .replaceAll('=', '');

void main() {
  setUp(CsrfSessionTrace.clear);
  test('浏览器 Cookie 快照保留不同变体和缺失项，不暴露原文', () {
    final options = RequestOptions(
      path: '/topics/timings',
      method: 'POST',
      headers: {
        'Cookie': '_forum_session=input-session; _t=input-login',
        'X-CSRF-Token': 'secret-token',
      },
    );
    final trace = CsrfSessionTrace.captureDispatch(
      options,
      browserManaged: true,
    )!;
    CsrfSessionTrace.captureBrowserCookies(options, const [
      MapEntry('_forum_session', 'input-session'),
      MapEntry('_forum_session', 'different-session'),
      MapEntry('unrelated', 'ignored-value'),
    ]);
    final browser = trace['browserStoreCookieHashes'] as Map;
    final input = trace['adapterInputCookieHashes'] as Map;
    expect(browser['_forum_session'], hasLength(2));
    expect(browser['_forum_session'][0], input['_forum_session'][0]);
    expect(browser['_forum_session'][1], isNot(input['_forum_session'][0]));
    expect(browser.containsKey('_t'), isFalse);
    expect(browser.containsKey('unrelated'), isFalse);
    expect(trace['browserCookieSnapshotStage'], 'store-before-fetch');
    final serialized = jsonEncode(trace);
    for (final secret in [
      'input-session',
      'different-session',
      'input-login',
      'secret-token',
    ]) {
      expect(serialized, isNot(contains(secret)));
    }
  });
  test('核心入口哈希与原始头值一致，保留重复头以供核心侧核对', () {
    final options = RequestOptions(
      path: '/session/csrf',
      headers: {
        'X-CSRF-Token': ['secret-token', 'second-token'],
      },
    );
    final trace = CsrfSessionTrace.captureDispatch(options)!;
    final hashes = trace['csrfInputHeaderHashes'] as Map;
    expect(hashes['x-csrf-token'], hasLength(2));
    expect(hashes['x-csrf-token'][0], '930bbdc51b6aed5c');
  });
  test('头部摘要经过落盘与导出仍可关联，原始凭据继续脱敏', () {
    final options = RequestOptions(
      path: '/topics/timings',
      method: 'POST',
      headers: {
        'Cookie': '_forum_session=raw-session; cf_clearance=raw-clearance',
        'X-CSRF-Token': 'raw-csrf-token',
      },
    );
    final trace = CsrfSessionTrace.captureDispatch(options)!;
    final hashes = trace['csrfInputHeaderHashes'] as Map;
    trace['corePreparedRequest'] = {
      'stage': 'core-prepared-headers',
      'header_hashes': Map<String, dynamic>.from(hashes),
    };
    final row = LogPolicy.normalize({
      'type': 'request',
      ...CsrfSessionTrace.forLog(trace),
      'rawHeaders': options.headers,
    });
    final exported = LogPolicy.export(jsonEncode(row));
    final result = jsonDecode(
      const LineSplitter().convert(exported).last,
    ) as Map<String, dynamic>;
    final input = result['csrfInputHeaderHashes'] as Map;
    final prepared = result['corePreparedRequest']['header_hashes'] as Map;
    for (final name in hashes.keys) {
      expect(input['$name-sha256'], hashes[name]);
      expect(prepared['$name-sha256'], hashes[name]);
    }
    expect(result['csrfTraceVersion'], 3);
    expect(result['rawHeaders']['Cookie'], '[redacted]');
    expect(result['rawHeaders']['X-CSRF-Token'], '[redacted]');
    for (final secret in ['raw-session', 'raw-clearance', 'raw-csrf-token']) {
      expect(exported, isNot(contains(secret)));
    }
    expect(trace['csrfTraceVersion'], 2);
    expect(hashes.containsKey('cookie'), isTrue);
    expect(trace['corePreparedRequest']['header_hashes'], hashes);
  });
  test('Rails 同一真实令牌的不同随机掩码关联到同一上下文', () {
    expect(
      CsrfSessionTrace.tokenFingerprint(masked(17)),
      CsrfSessionTrace.tokenFingerprint(masked(91)),
    );
    expect(
      CsrfSessionTrace.tokenFingerprint(masked(17)),
      isNot(CsrfSessionTrace.tokenFingerprint('other')),
    );
  });
  test('刷新响应的会话与后续适配器入口 Cookie 做关联，不记录凭据明文', () {
    final fetch = RequestOptions(
      path: '/session/csrf',
      baseUrl: 'https://linux.do',
      headers: {'Cookie': '_forum_session=before%2Fsession'},
      extra: {CsrfSessionTrace.refreshKey: 'refresh-1'},
    );
    setRequestAdapterLogName(fetch, 'core');
    CsrfSessionTrace.captureDispatch(fetch);
    CsrfSessionTrace.bindRefresh(
      Response<dynamic>(
        requestOptions: fetch,
        headers: Headers.fromMap({
          'set-cookie': ['_forum_session=after%2Fsession; Path=/; HttpOnly'],
        }),
      ),
      masked(17),
    );
    final post = RequestOptions(
      path: '/topics/timings',
      baseUrl: 'https://linux.do',
      method: 'POST',
      headers: {
        'Cookie': '_forum_session=after%2Fsession',
        'X-CSRF-Token': masked(91),
      },
    );
    final trace = CsrfSessionTrace.captureDispatch(post)!;
    expect(trace['csrfContextKnown'], isTrue);
    expect(trace['csrfCookieMatchesRefresh'], isTrue);
    expect(trace['csrfRefreshId'], 'refresh-1');
    expect(trace['csrfFetchAdapter'], 'core');
    final encoded = jsonEncode(trace);
    for (final secret in [
      'before/session',
      'after/session',
      masked(17),
      masked(91),
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
    post.headers['Cookie'] = '_forum_session=before%2Fsession';
    expect(
      CsrfSessionTrace.captureDispatch(post)!['csrfCookieMatchesRefresh'],
      isFalse,
    );
    final browser = CsrfSessionTrace.captureDispatch(
      post,
      browserManaged: true,
    )!;
    expect(browser.containsKey('csrfCookieMatchesRefresh'), isFalse);
    expect(browser.containsKey('sentForumSessionHash'), isFalse);
  });
  test('未知令牌和图片请求不伪造关联，刷新编号不被旧上下文覆盖', () {
    final request = RequestOptions(
      path: '/topics/timings',
      method: 'POST',
      headers: {'X-CSRF-Token': 'unknown'},
    );
    expect(
      CsrfSessionTrace.captureDispatch(request)!['csrfContextKnown'],
      isFalse,
    );
    request.path = '/image.png';
    request.method = 'GET';
    expect(CsrfSessionTrace.captureDispatch(request), isNull);
    expect(request.extra.containsKey(CsrfSessionTrace.extraKey), isFalse);
  });
}
