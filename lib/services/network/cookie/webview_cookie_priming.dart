import 'dart:async';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import 'cookie_jar_service.dart';
import 'cookie_logger.dart';
import 'cookie_store_observer.dart';
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

  bool _isPrimed = false;

  static const Duration _variantCleanupRetryDelay = Duration(milliseconds: 120);
  static const int _variantCleanupMaxAttempts = 2;

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
    // 注册 url 到 observer, 后续 WV 外部 cookie 变化时会对该 url sweep
    CookieStoreObserver.instance.registerUrl(url);
    try {
      // 1. 确保 jar 已初始化（兜底，调用方应该已经初始化）
      if (!_jar.isInitialized) {
        await _jar.initialize();
      }
      await _jar.enforceAuthCookiePolicy(reason: 'webview_priming');

      // 2. 从 jar 读"当前 url 适用的所有 cookie" (RFC 6265 domain matching)
      // 不再按 criticalCookieNames 过滤 — 该列表 hard-code 维护不可持续
      // (每次发现新业务 cookie 如 LDC/CDK 没同步就要追加, 永远列不全)。
      // jar 是 source of truth, loadCanonicalCookiesForRequest 已经按
      // RFC 6265 domain matching 选出"该 url 适用的全部 cookie", 直接
      // 全量同步到 WV 即可。
      final uri = Uri.parse(url);
      final jarCookies = await _jar.loadCanonicalCookiesForRequest(uri);

      // 3. per-cookie 严格 "先 nuke 后写" 流程, 保证写入后 each name 恰好 1 条:
      //
      // 旧流程 "先全部 setRawCookie 后 sweepAll 兜底" 对 Apple 平台行为
      // 不够鲁棒 — 实测 macOS 上同 (name, domain, path) 写入未必覆盖
      // (可能 sourceScheme / sourcePort / SameSite 等隐藏字段差异导致 4-tuple
      // 不全等), 残留多条 variant。
      //
      // 新流程 per-cookie:
      //   a) sweep(intent: delete) — 暴力删除当前 url 域下该 name 所有 variant
      //   b) setRawCookie(jar canonical) — 写入 1 条规范形式
      //   c) verify count — 不等于 1 时 dump 所有 variant 字段到日志
      var injected = 0;
      var attempted = 0;
      var skippedEmpty = 0;
      var skippedExpired = 0;
      var skippedRaceRemoved = 0;
      final mismatched = <String, int>{};
      for (final initialCookie in jarCookies) {
        if (initialCookie.value.isEmpty) {
          skippedEmpty++;
          continue;
        }
        if (_isExpired(initialCookie)) {
          skippedExpired++;
          continue;
        }
        // cf_clearance 单向流(WV→jar):它只会在 WebView 中由 CF 签发/更新,
        // Dio 侧永远不产新值。jar→WV 回灌会经 toSetCookieHeader 丢失
        // Partitioned 属性,把 CF 原生的分区 cookie 复制成一枚非分区副本
        // → WebView 存储出现双变体(browser 侧从不会有)。因此回灌一律
        // 跳过 cf_clearance,WebView 里永远只有 CF 自己写的那份。
        if (initialCookie.name == 'cf_clearance') {
          continue;
        }

        // Race-safe check: Priming 整体 unawaited 跑, 期间外部 (如
        // cf_challenge_service.showVerifyForChallenge) 可能并发删/改 jar
        // 中的 cookie。如果还按 T0 快照 setRawCookie, 会把外部刚删的
        // cookie 又写回 WV — 这正是 CF 第一次验证失败的根因 (CF 看到
        // Priming 写回的旧 cf_clearance 直接放行不显示盾, fallback
        // 找不到 fresh cookie 关闭挑战页)。
        //
        // 写入前重新 getCanonicalCookie:
        // - jar 已删 (返回 null): 跳过, 不再写回 WV
        // - value 变了: 用最新值 (新值更准)
        // - value 未变: 用原快照 (最常见)
        final fresh = await _jar.getCanonicalCookie(initialCookie.name);
        if (fresh == null || fresh.value.isEmpty) {
          skippedRaceRemoved++;
          debugPrint('[Priming] ${initialCookie.name} 在 priming 期间被外部删除, 跳过');
          continue;
        }
        if (_isExpired(fresh)) {
          skippedExpired++;
          continue;
        }
        final cookie = fresh;

        attempted++;

        // a) 再次 race check: 上面读取是 async, 期间外部又可能删 cookie
        // 例如 sweep 跑到一半 cf_challenge_service 介入, 我们要尊重那个删除
        final reFresh = await _jar.getCanonicalCookie(cookie.name);
        if (reFresh == null || reFresh.value.isEmpty) {
          skippedRaceRemoved++;
          attempted--;
          debugPrint('[Priming] ${cookie.name} 在 sweep 期间被外部删除, 不写回');
          continue;
        }
        final writeCookie = reFresh;

        // b) nuke 同 name 所有 variant 后写入 jar canonical
        // (含 hostOnly/Domain/SameSite)。Apple WebKit cookie store 偶发会在
        // 删除/写入短窗口里留下同名变体，因此这里带一次重试收敛。
        final writeResult = await _writeCookieWithVariantCleanup(
          url,
          writeCookie,
        );
        if (writeResult.skipped) {
          skippedRaceRemoved++;
          attempted--;
          debugPrint('[Priming] ${writeCookie.name} 在 sweep 期间被外部删除, 不写回');
          continue;
        }
        final writtenCookie = writeResult.cookie ?? writeCookie;
        if (writeResult.written) injected++;

        // c) verify 是否恰好 1 条
        final postCount = writeResult.postCount;
        final observedPostCount = writeResult.observedPostCount ?? postCount;
        final isOk = postCount == 1;
        if (!isOk) mismatched[writtenCookie.name] = observedPostCount;
        debugPrint(
          '[Priming] ${writtenCookie.name} '
          '(hostOnly=${writtenCookie.hostOnly}, domain=${writtenCookie.domain}, '
          'len=${writtenCookie.value.length}) write=${writeResult.written} '
          'postCount=$observedPostCount attempts=${writeResult.attempts} '
          '${writeResult.acceptedDuplicate ? "acceptedDuplicate=true " : ""}'
          '${isOk ? "✓" : "⚠️ expected=1"}',
        );

        // c.1) 若 count != 1, dump WV 中该 name 所有 variant 完整字段
        if (!isOk) {
          final all = await _writer.getAllCookieInfos(url);
          final variants = all
              .where((c) => c.name == writtenCookie.name)
              .toList();
          debugPrint(
            '[Priming] ⚠️ ${writtenCookie.name} variants in WV '
            '($observedPostCount):',
          );
          for (var i = 0; i < variants.length; i++) {
            debugPrint('  [$i] ${variants[i]}');
          }
        }
      }

      // 4. verify pass (信息汇总, 不影响 _isPrimed)
      // 用 jar 最新状态 (而非 T0 快照) 避免把"期间被外部删除"误报为 missing
      var verified = 0;
      final missingNames = <String>[];
      final currentJar = await _jar.loadCanonicalCookiesForRequest(uri);
      for (final cookie in currentJar) {
        if (cookie.value.isEmpty || _isExpired(cookie)) continue;
        final count = await _writer.countCookiesByName(url, cookie.name);
        if (count >= 1) {
          verified++;
        } else {
          missingNames.add(cookie.name);
        }
      }

      _isPrimed = true;
      final hasMismatch = mismatched.isNotEmpty || missingNames.isNotEmpty;
      debugPrint(
        '[Priming] WV primed for $url: '
        'injected=$injected/$attempted, verified=$verified/$attempted '
        '(jarTotal=${jarCookies.length}, '
        'skippedEmpty=$skippedEmpty, skippedExpired=$skippedExpired, '
        'skippedRaceRemoved=$skippedRaceRemoved)'
        '${hasMismatch ? ", MISSING=$missingNames, COUNT_MISMATCH=$mismatched" : ""}',
      );
      CookieLogger.priming(
        event: hasMismatch ? 'failed' : 'completed',
        url: url,
        cookiesInjected: injected,
        durationMs: stopwatch.elapsedMilliseconds,
        reason: hasMismatch
            ? 'missing=$missingNames count_mismatch=$mismatched '
                  'verified=$verified/$attempted'
            : null,
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

  Future<_PrimeWriteResult> _writeCookieWithVariantCleanup(
    String url,
    CanonicalCookie cookie,
  ) async {
    var written = false;
    var postCount = 0;
    for (var attempt = 1; attempt <= _variantCleanupMaxAttempts; attempt++) {
      await _sentinel.sweep(
        url,
        cookie.name,
        intent: SweepIntent.delete,
        force: true,
      );
      final fresh = await _jar.getCanonicalCookie(cookie.name);
      if (fresh == null || fresh.value.isEmpty || _isExpired(fresh)) {
        postCount = await _writer.countCookiesByName(url, cookie.name);
        return _PrimeWriteResult(
          written: written,
          postCount: postCount,
          attempts: attempt,
          skipped: true,
        );
      }
      final ok = await _writer.setRawCookie(
        url,
        fresh.toSetCookieHeader(),
        writeSharedStorage: fresh.name != 'cf_clearance',
      );
      written = written || ok;
      postCount = await _writer.countCookiesByName(url, fresh.name);
      if (postCount == 1) {
        return _PrimeWriteResult(
          written: written,
          postCount: postCount,
          attempts: attempt,
          cookie: fresh,
        );
      }
      if (await _isAcceptableDuplicate(url, fresh, postCount)) {
        return _PrimeWriteResult(
          written: written,
          postCount: 1,
          observedPostCount: postCount,
          attempts: attempt,
          cookie: fresh,
          acceptedDuplicate: true,
        );
      }
      if (attempt == _variantCleanupMaxAttempts) {
        return _PrimeWriteResult(
          written: written,
          postCount: postCount,
          attempts: attempt,
          cookie: fresh,
        );
      }
      debugPrint('[Priming] ${cookie.name} 写入后仍有 $postCount 个变体，重试清理');
      await Future<void>.delayed(_variantCleanupRetryDelay);
    }
    return _PrimeWriteResult(
      written: written,
      postCount: postCount,
      attempts: _variantCleanupMaxAttempts,
      cookie: cookie,
    );
  }

  bool _isExpired(CanonicalCookie cookie) {
    final expiresAt = cookie.expiresAt;
    return expiresAt != null && expiresAt.isBefore(DateTime.now());
  }

  Future<bool> _isAcceptableDuplicate(
    String url,
    CanonicalCookie cookie,
    int postCount,
  ) async {
    if (cookie.name != 'cf_clearance' || postCount <= 1) return false;
    final variants = (await _writer.getAllCookieInfos(
      url,
    )).where((variant) => variant.name == cookie.name).toList(growable: false);
    if (variants.length <= 1) return false;
    final sameValue = variants.every(
      (variant) => variant.value == cookie.value,
    );
    if (!sameValue) return false;

    debugPrint(
      '[Priming] ${cookie.name} 存在 ${variants.length} 个同值变体，'
      '接受并跳过重试清理',
    );
    return true;
  }
}

class _PrimeWriteResult {
  const _PrimeWriteResult({
    required this.written,
    required this.postCount,
    required this.attempts,
    this.observedPostCount,
    this.cookie,
    this.skipped = false,
    this.acceptedDuplicate = false,
  });

  final bool written;
  final int postCount;
  final int attempts;
  final int? observedPostCount;
  final CanonicalCookie? cookie;
  final bool skipped;
  final bool acceptedDuplicate;
}

/// WV priming 失败时抛出。
class WebViewPrimingException implements Exception {
  WebViewPrimingException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'WebViewPrimingException: $message'
      '${cause != null ? ' (caused by $cause)' : ''}';
}
