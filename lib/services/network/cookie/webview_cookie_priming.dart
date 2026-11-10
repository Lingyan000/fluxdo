import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth_session.dart';
import 'cookie_jar_service.dart';
import 'cookie_logger.dart';
import 'cookie_store_observer.dart';
import 'raw_cookie_writer.dart';
import 'session_cookie_sentinel.dart';

/// WebView 使用前，对齐当前会话的客户端 Cookie 与浏览器存储。
/// 同站点共享在途任务，已一致的 Cookie 直接保留。
class WebViewCookiePriming {
  WebViewCookiePriming._();
  static final instance = WebViewCookiePriming._();

  RawCookieWriter _writer = RawCookieWriter.instance;
  CookieJarService _jar = CookieJarService();
  SessionCookieSentinel _sentinel = SessionCookieSentinel.instance;

  final Map<String, ({String url, int generation, Future<void> future})>
  _tasks = {};
  bool _isPrimed = false;
  int? _readyGeneration;

  bool get isPrimed =>
      _isPrimed && _readyGeneration == AuthSession().generation;

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

  Future<void> prime(String url) async {
    final uri = Uri.parse(url);
    final normalizedUrl = uri.replace(query: '', fragment: '').toString();
    final origin = uri.origin;
    while (_tasks.containsKey(origin)) {
      final task = _tasks[origin]!;
      try {
        await task.future;
      } catch (_) {
        if (task.generation == AuthSession().generation) rethrow;
      }
      if (task.url == normalizedUrl &&
          task.generation == AuthSession().generation) {
        return;
      }
    }
    final generation = AuthSession().generation;
    late final Future<void> future;
    future = _primeInternal(normalizedUrl, generation).whenComplete(() {
      if (identical(_tasks[origin]?.future, future)) _tasks.remove(origin);
    });
    _tasks[origin] = (
      url: normalizedUrl,
      generation: generation,
      future: future,
    );
    return future;
  }

  void invalidate() {
    _isPrimed = false;
    _writer.invalidateReads();
  }

  Future<void> awaitReady() =>
      Future.wait(_tasks.values.map((task) => task.future));

  @visibleForTesting
  void resetForTest() {
    _tasks.clear();
    _isPrimed = false;
    _readyGeneration = null;
  }

  Future<void> _primeInternal(String url, int generation) async {
    final watch = Stopwatch()..start();
    CookieLogger.priming(event: 'invoked', url: url, isPrimed: isPrimed);
    CookieStoreObserver.instance.registerUrl(url);
    _isPrimed = false;
    try {
      if (!_jar.isInitialized) await _jar.initialize();
      await _jar.enforceAuthCookiePolicy(reason: 'webview_priming');
      final uri = Uri.parse(url);
      final initial = await _jar.loadCanonicalCookiesForRequest(uri);
      if (!AuthSession().isValid(generation)) throw StateError('预热所属会话已结束');
      await _writer.clearSharedAuthCookieCopies(
        url,
        initial
            .where((cookie) => !cookie.isExpired && cookie.value.isNotEmpty)
            .map((cookie) => cookie.name),
      );
      var injected = 0;
      // 写入期间 jar 可能轮换。最多再核对一轮，避免持续变化造成无界任务。
      for (var pass = 0; pass < 2; pass++) {
        if (!AuthSession().isValid(generation)) throw StateError('预热所属会话已结束');
        final snapshot = await _writer.getAllCookieInfos(url);
        final expected = await _jar.loadCanonicalCookiesForRequest(uri);
        final names = expected
            .where(
              (cookie) =>
                  cookie.name != 'cf_clearance' &&
                  cookie.value.isNotEmpty &&
                  !cookie.isExpired,
            )
            .map((cookie) => cookie.name)
            .toSet();

        for (final name in names) {
          if (!AuthSession().isValid(generation)) throw StateError('预热所属会话已结束');
          final wanted = expected
              .where((cookie) => cookie.name == name)
              .toList();
          final existing = snapshot
              .where((cookie) => cookie.name == name)
              .toList();
          if (SessionCookieSentinel.matchesSnapshot(url, existing, wanted)) {
            continue;
          }
          final result = await _sentinel.syncFromJar(url, name);
          if (result.status == SweepStatus.failed ||
              result.status == SweepStatus.cancelled) {
            throw StateError('Cookie 同步未完成: $name (${result.status.name})');
          }
          if (result.status == SweepStatus.swept) injected++;
        }
        // 最终仅做一次快照读取，验证值及可用的作用域元数据。
        final stored = await _writer.getAllCookieInfos(url);
        final current = await _jar.loadCanonicalCookiesForRequest(uri);
        final currentNames = current
            .where(
              (cookie) =>
                  cookie.name != 'cf_clearance' &&
                  cookie.value.isNotEmpty &&
                  !cookie.isExpired,
            )
            .map((cookie) => cookie.name)
            .toSet();

        final consistent = currentNames.every(
          (name) => SessionCookieSentinel.matchesSnapshot(
            url,
            stored.where((cookie) => cookie.name == name).toList(),
            current.where((cookie) => cookie.name == name).toList(),
          ),
        );
        if (!AuthSession().isValid(generation)) throw StateError('预热所属会话已结束');
        if (consistent) {
          _readyGeneration = generation;
          _isPrimed = true;
          CookieLogger.priming(
            event: 'completed',
            url: url,
            cookiesInjected: injected,
            durationMs: watch.elapsedMilliseconds,
          );
          return;
        }
      }
      throw StateError('Cookie 核对仍不一致');
    } catch (error) {
      _isPrimed = false;
      CookieLogger.priming(
        event: 'failed',
        url: url,
        reason: '$error',
        durationMs: watch.elapsedMilliseconds,
      );
      throw WebViewPrimingException('prime failed for $url', error);
    }
  }
}

class WebViewPrimingException implements Exception {
  WebViewPrimingException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'WebViewPrimingException: $message (cause: $cause)';
}
