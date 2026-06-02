import 'dart:async';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import 'cookie_jar_service.dart';
import 'cookie_logger.dart';
import 'raw_cookie_writer.dart';
import 'session_cookie_sentinel.dart';

/// WV 启动重灌服务。
///
/// 取代 v0.3.0 的 `RawSetCookieQueue` 持久化队列。
/// 在 WV 即将被使用前，从 jar 重灌所有 critical cookies。
///
/// 设计依据：`docs/cookie-sync-design-v0.4.0.md` §5.2
///
/// 关键不变量：
/// - 任何 WV 使用者在使用 WV 前必须 await [prime]
/// - prime 是幂等的（[isPrimed] 为 true 时立即返回）
/// - 同一 url 并发调用 [prime] 会去重（共享同一个 Future）
class WebViewCookiePriming {
  WebViewCookiePriming._();
  static final WebViewCookiePriming instance = WebViewCookiePriming._();

  // ---------------------------------------------------------------------------
  // 可注入依赖
  // ---------------------------------------------------------------------------

  RawCookieWriter _writer = RawCookieWriter.instance;
  CookieJarService _jar = CookieJarService();
  SessionCookieSentinel _sentinel = SessionCookieSentinel.instance;

  /// 仅测试用：替换内部依赖。
  @visibleForTesting
  void replaceDependenciesForTest({
    RawCookieWriter? writer,
    CookieJarService? jar,
    SessionCookieSentinel? sentinel,
  }) {
    if (writer != null) _writer = writer;
    if (jar != null) _jar = jar;
    if (sentinel != null) _sentinel = sentinel;
  }

  // ---------------------------------------------------------------------------
  // 内部状态
  // ---------------------------------------------------------------------------

  static const String _pathDefault = '/';

  bool _isPrimed = false;

  /// 当前进行中的 prime Future（用于同 url 并发去重）。
  Future<void>? _primingFuture;
  String? _primingUrl;

  // ---------------------------------------------------------------------------
  // 公开 API
  // ---------------------------------------------------------------------------

  /// 当前 WV 是否已就绪。
  bool get isPrimed => _isPrimed;

  /// 确保 WV 中的 critical cookies 与 jar 同步。
  ///
  /// 详见 §5.2 接口契约。
  Future<void> prime(String url) async {
    if (_isPrimed) return;

    // 同 url 并发去重
    final existing = _primingFuture;
    if (existing != null && _primingUrl == url) {
      return existing;
    }

    final future = _primeInternal(url);
    _primingFuture = future;
    _primingUrl = url;

    try {
      await future;
    } finally {
      if (identical(_primingFuture, future)) {
        _primingFuture = null;
        _primingUrl = null;
      }
    }
  }

  /// 标记 WV 状态为"未就绪"。
  void invalidate() {
    _isPrimed = false;
  }

  /// 等待当前正在进行的 priming 完成（如有）。
  Future<void> awaitReady() async {
    final future = _primingFuture;
    if (future != null) await future;
  }

  /// 仅测试用：重置内部状态。
  @visibleForTesting
  void resetForTest() {
    _isPrimed = false;
    _primingFuture = null;
    _primingUrl = null;
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  Future<void> _primeInternal(String url) async {
    final stopwatch = Stopwatch()..start();
    CookieLogger.priming(event: 'invoked', url: url, isPrimed: _isPrimed);
    try {
      // 1. 确保 jar 已初始化（兜底，调用方应该已经初始化）
      if (!_jar.isInitialized) {
        await _jar.initialize();
      }

      // 2. 从 jar 读 critical cookies
      final uri = Uri.parse(url);
      final jarCookies = await _jar.loadCanonicalCookiesForRequest(uri);
      final critical = jarCookies
          .where(
            (c) => SessionCookieSentinel.criticalCookieNames.contains(c.name),
          )
          .toList(growable: false);

      // 3. 快速检查：WV 中是否已有所有 critical cookies
      var allPresent = true;
      for (final cookie in critical) {
        if (cookie.value.isEmpty) continue;
        if (_isExpired(cookie)) continue;
        final count = await _writer.countCookiesByName(url, cookie.name);
        if (count == 0) {
          allPresent = false;
          break;
        }
      }

      if (allPresent && critical.isNotEmpty) {
        // 都在，只兜底 sweep 一遍保证唯一性
        await _sentinel.sweepAll(url);
        _isPrimed = true;
        debugPrint(
          '[Priming] WV cookies already present, sweepAll only ($url)',
        );
        CookieLogger.priming(
          event: 'completed',
          url: url,
          cookiesInjected: 0,
          durationMs: stopwatch.elapsedMilliseconds,
        );
        return;
      }

      // 4. 全量重灌
      var injected = 0;
      for (final cookie in critical) {
        if (cookie.value.isEmpty) continue;
        if (_isExpired(cookie)) continue;
        final ok = await _writer.setRawCookie(url, _buildRawHeader(cookie));
        if (ok) injected++;
      }

      // 5. sweep 兜底（确保变体唯一）
      await _sentinel.sweepAll(url);

      _isPrimed = true;
      debugPrint(
        '[Priming] WV primed: $injected cookies injected for $url',
      );
      CookieLogger.priming(
        event: 'completed',
        url: url,
        cookiesInjected: injected,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e, s) {
      debugPrint('[Priming] prime $url failed: $e\n$s');
      _isPrimed = false;
      CookieLogger.priming(
        event: 'failed',
        url: url,
        reason: '$e',
        durationMs: stopwatch.elapsedMilliseconds,
      );
      throw WebViewPrimingException('prime failed for $url: $e', e);
    }
  }

  bool _isExpired(CanonicalCookie cookie) {
    final expiresAt = cookie.expiresAt;
    return expiresAt != null && expiresAt.isBefore(DateTime.now());
  }

  /// 从 [CanonicalCookie] 构造规范 Set-Cookie 头（host-only）。
  String _buildRawHeader(CanonicalCookie cookie) {
    final attrs = <String>['${cookie.name}=${cookie.value}'];
    attrs.add('Path=${cookie.path.isEmpty ? _pathDefault : cookie.path}');
    if (cookie.secure) attrs.add('Secure');
    if (cookie.httpOnly) attrs.add('HttpOnly');
    if (cookie.expiresAt != null) {
      attrs.add('Expires=${_formatHttpDate(cookie.expiresAt!)}');
    }
    return attrs.join('; ');
  }

  /// RFC 1123 HTTP-date 格式。
  String _formatHttpDate(DateTime date) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final utc = date.toUtc();
    return '${weekdays[utc.weekday - 1]}, '
        '${utc.day.toString().padLeft(2, '0')} '
        '${months[utc.month - 1]} '
        '${utc.year} '
        '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')}:'
        '${utc.second.toString().padLeft(2, '0')} GMT';
  }
}

/// WV priming 失败时抛出。
class WebViewPrimingException implements Exception {
  WebViewPrimingException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'WebViewPrimingException: $message'
      '${cause != null ? ' (caused by $cause)' : ''}';
}
