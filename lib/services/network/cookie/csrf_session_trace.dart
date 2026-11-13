import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'cookie_value_codec.dart';

import '../adapters/adapter_log_metadata.dart';

/// 关联 CSRF 刷新与实际发送的会话。只保存短哈希和长度，不保存凭据明文。
/// Cookie 密文哈希不同只表示 wire 值不同，不直接证明解密后的 Rails 会话不同。
class CsrfSessionTrace {
  static const extraKey = '_csrfSessionDispatch';
  static const refreshKey = '_csrfRefreshTrace';
  static int _sequence = 0;
  static final Map<String, Map<String, dynamic>> _bindings = {};

  static String nextRefreshId() => 'csrf-${++_sequence}';

  static String? _header(Map<String, dynamic> headers, String name) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == name) return e.value?.toString();
    }
    return null;
  }

  static String? _digest(String? value) => value == null || value.isEmpty
      ? null
      : sha256.convert(utf8.encode(value)).toString().substring(0, 16);

  static const _tracedHeaders = {
    'cookie',
    'x-csrf-token',
    'origin',
    'referer',
    'user-agent',
    'content-type',
    'content-length',
  };

  static Map<String, List<String>> _headerHashes(Map<String, dynamic> headers) {
    final hashes = <String, List<String>>{};
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (!_tracedHeaders.contains(name) || entry.value == null) continue;
      final values = entry.value is Iterable
          ? entry.value as Iterable
          : [entry.value];
      for (final value in values) {
        if (value == null) continue;
        hashes
            .putIfAbsent(name, () => [])
            .add(
              sha256
                  .convert(utf8.encode(value.toString()))
                  .toString()
                  .substring(0, 16),
            );
      }
    }
    return hashes;
  }

  /// 浏览器 Cookie 存储的只读快照，不代表网络抓包；保留多变体以识别歧义。
  static void captureBrowserCookies(
    RequestOptions options,
    Iterable<MapEntry<String, String>> cookies,
  ) {
    final trace = options.extra[extraKey];
    if (trace is! Map || trace['csrfCookieAuthority'] != 'webview') return;
    const names = {'_forum_session', '_t', 'cf_clearance'};
    final browser = <String, List<String?>>{};
    final input = <String, List<String?>>{};
    for (final cookie in cookies) {
      if (names.contains(cookie.key)) {
        browser.putIfAbsent(cookie.key, () => []).add(_digest(cookie.value));
      }
    }
    for (final part in (_header(options.headers, 'cookie') ?? '').split(';')) {
      final equal = part.indexOf('=');
      if (equal < 0) continue;
      final name = part.substring(0, equal).trim();
      if (names.contains(name)) {
        input
            .putIfAbsent(name, () => [])
            .add(_digest(part.substring(equal + 1).trim()));
      }
    }
    trace['browserCookieSnapshotStage'] = 'store-before-fetch';
    trace['browserCookieSnapshotAvailable'] = true;
    trace['browserStoreCookieHashes'] = browser;
    trace['adapterInputCookieHashes'] = input;
  }

  static String? _session(String? header) {
    for (final part in (header ?? '').split(';')) {
      final equal = part.indexOf('=');
      if (equal > 0 && part.substring(0, equal).trim() == '_forum_session') {
        final value = part.substring(equal + 1).trim();
        try {
          return CookieValueCodec.decode(value);
        } on FormatException {
          return value;
        }
      }
    }
    return null;
  }

  static String? tokenFingerprint(String? token) {
    if (token == null || token.isEmpty) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(token));
      if (bytes.length == 64) {
        return sha256
            .convert(List<int>.generate(32, (i) => bytes[i] ^ bytes[i + 32]))
            .toString()
            .substring(0, 16);
      }
    } catch (_) {
      // 老版本或测试令牌不一定是 Rails 32+32 字节格式。
    }
    return _digest(token);
  }

  static Map<String, dynamic>? captureDispatch(
    RequestOptions options, {
    bool browserManaged = false,
  }) {
    final token = _header(options.headers, 'x-csrf-token');
    if (options.uri.path != '/session/csrf' &&
        (token == null ||
            token.isEmpty ||
            options.method.toUpperCase() == 'GET')) {
      options.extra.remove(extraKey);
      return null;
    }
    final fingerprint = tokenFingerprint(token);
    final binding = _bindings[fingerprint];
    final sentSession = _digest(_session(_header(options.headers, 'cookie')));
    final fields = <String, dynamic>{
      'csrfTraceVersion': 2,
      'csrfTraceStage': 'adapter-input',
      'csrfDispatchId': 'dispatch-${++_sequence}',
      'csrfCookieAuthority': browserManaged ? 'webview' : 'request-header',

      'csrfTokenHash': fingerprint,
      if (!browserManaged) 'sentForumSessionHash': sentSession,
      'csrfContextKnown': binding != null,
      if (binding != null) ...binding,
      'csrfRefreshId': options.extra[refreshKey] ?? binding?['csrfRefreshId'],
      if (!browserManaged && binding?['csrfEffectiveSessionHash'] != null)
        'csrfCookieMatchesRefresh':
            sentSession == binding!['csrfEffectiveSessionHash'],
      'sentHeaderNames':
          options.headers.keys.map((k) => k.toLowerCase()).toList()..sort(),
      'sentContentLength': _header(options.headers, 'content-length'),
      'csrfInputHeaderHashes': _headerHashes(options.headers),
    };
    options.extra[extraKey] = fields;
    return fields;
  }

  static Map<String, dynamic> bindRefresh(
    Response<dynamic> response,
    String token,
  ) {
    final dispatch = response.requestOptions.extra[extraKey];
    final sent = dispatch is Map
        ? dispatch['sentForumSessionHash'] as String?
        : null;
    String? returned;
    bool sessionSet = false;
    for (final header in response.headers['set-cookie'] ?? const <String>[]) {
      final first = header.split(';').first;
      if (first.startsWith('_forum_session=')) {
        sessionSet = true;
        returned = _digest(_session(first));
      }
    }
    final fields = <String, dynamic>{
      'csrfRefreshId': response.requestOptions.extra[refreshKey],
      'csrfFetchDispatchId': dispatch is Map
          ? dispatch['csrfDispatchId']
          : null,
      'csrfFetchAdapter': getRequestAdapterLogName(response.requestOptions),
      'csrfFetchSessionHash': sent,
      'csrfResponseSessionHash': returned,
      'csrfEffectiveSessionHash': sessionSet ? returned : sent,
      'csrfTokenHash': tokenFingerprint(token),
    };
    final key = tokenFingerprint(token);
    if (key != null) {
      _bindings.remove(key);
      _bindings[key] = fields;
      while (_bindings.length > 16) {
        _bindings.remove(_bindings.keys.first);
      }
    }
    return fields;
  }

  /// 日志字段明确标识摘要，避免 Cookie/Token 的原始头名触发二次脱敏。
  /// 核心原始快照仍保留头名，供适配器入口与核心准备阶段逐项比较。
  static Map<String, dynamic> forLog(Map trace) {
    final fields = Map<String, dynamic>.from(trace);
    fields['csrfTraceVersion'] = 3;
    final inputHashes = fields['csrfInputHeaderHashes'];
    if (inputHashes is Map) {
      fields['csrfInputHeaderHashes'] = _namedHeaderHashes(inputHashes);
    }
    final prepared = fields['corePreparedRequest'];
    if (prepared is Map && prepared['header_hashes'] is Map) {
      fields['corePreparedRequest'] = {
        ...prepared,
        'header_hashes': _namedHeaderHashes(prepared['header_hashes'] as Map),
      };
    }
    return fields;
  }

  static Map<String, dynamic> _namedHeaderHashes(Map hashes) => {
    for (final entry in hashes.entries) '${entry.key}-sha256': entry.value,
  };

  static void clear() => _bindings.clear();
}
