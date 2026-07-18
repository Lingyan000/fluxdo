import 'dart:async';

import 'package:collection/collection.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import '../../auth_session.dart';
import 'cookie_full_info.dart';
import 'cookie_jar_service.dart';
import 'cookie_logger.dart';
import 'raw_cookie_writer.dart';

/// Cookie 变体清扫内核（"Sweep" 操作）。
///
/// 核心职责：保证 WV 中每个 critical cookie name 的变体数 ≤ 1
/// （[SweepIntent.delete] 时变体数 == 0）。
///
/// 设计依据：`docs/cookie-sync-design-v0.4.0.md` §5.1
///
/// 关键不变量：
/// - 任一 [sweep] / [sweepAll] 调用返回后，对应 name 的变体数满足后置条件
/// - 同一 name 全局串行（per-name [Lock]），不同 name 可并行
/// - sweep 进行中遇到 [AuthSession.generation] 变化或 [cancelAllSweeps] 调用，
///   在下个 CHECK 点退出（返回 [SweepStatus.cancelled]）
class SessionCookieSentinel {
  SessionCookieSentinel._();
  static final SessionCookieSentinel instance = SessionCookieSentinel._();

  /// criticalCookieNames，复用 [CookieJarService] 的定义保持单一来源。
  static Set<String> get criticalCookieNames =>
      CookieJarService.criticalCookieNames;

  // ---------------------------------------------------------------------------
  // 可注入依赖（@visibleForTesting 用 setter 替换）
  // ---------------------------------------------------------------------------

  RawCookieWriter _writer = RawCookieWriter.instance;
  CookieJarService _jar = CookieJarService();
  AuthSession _auth = AuthSession();

  /// 仅测试用：替换内部依赖。
  @visibleForTesting
  void replaceDependenciesForTest({
    RawCookieWriter? writer,
    CookieJarService? jar,
    AuthSession? auth,
  }) {
    if (writer != null) _writer = writer;
    if (jar != null) _jar = jar;
    if (auth != null) _auth = auth;
  }

  // ---------------------------------------------------------------------------
  // 内部状态
  // ---------------------------------------------------------------------------

  static const Duration _lockTimeout = Duration(seconds: 10);
  static const Duration _throttleWindow = Duration(seconds: 1);
  static const int _maxConsecutiveLockTimeouts = 3;
  static const String _pathDefault = '/';

  final Map<String, Lock> _locks = {};
  final Map<String, DateTime> _lastSweptAt = {};
  final Map<String, int> _consecutiveLockTimeouts = {};

  /// 登出时设为 true，所有 in-flight sweep 在下个 CHECK 点退出。
  bool _globalCancelled = false;

  final StreamController<SweepEvent> _eventController =
      StreamController<SweepEvent>.broadcast();

  Stream<SweepEvent> get events => _eventController.stream;

  // ---------------------------------------------------------------------------
  // 公开 API
  // ---------------------------------------------------------------------------

  /// 对指定 url 的 cookie name 执行 sweep。
  ///
  /// 详见 §5.1 接口契约。接受任意 name —— 不再限定 critical 列表,
  /// 配合 Priming/AppCookieManager 全量同步使用。
  ///
  /// [force] 为 false 时, ensureUnique 意图在 [_throttleWindow] 内对同名
  /// cookie 重复调用会直接返回 noop, 省掉高频响应路径上的重复 WV IPC。
  /// 权衡: 窗口内 WV 新产生的变体会推迟到下一次该 name 的 sweep 处理
  /// (sweep 本就是最终一致的兜底)。delete 意图与 [sweepAll]（boundary
  /// sync / priming 等关键路径）不节流。
  Future<SweepResult> sweep(
    String url,
    String name, {
    SweepIntent intent = SweepIntent.ensureUnique,
    bool force = false,
  }) async {
    if (!force &&
        intent == SweepIntent.ensureUnique &&
        wasRecentlySwept(name)) {
      return SweepResult(
        name: name,
        status: SweepStatus.noop,
        variantsBefore: 0,
        variantsAfter: 0,
        elapsed: Duration.zero,
      );
    }
    final entryGen = _auth.generation;
    final lock = _locks.putIfAbsent(name, () => Lock());

    try {
      // package:synchronized 3.4.0 的 synchronized<T> 支持 timeout 参数
      // (验证项 V11 已在 Phase 3 验证)
      return await lock.synchronized<SweepResult>(
        () => _sweepInternal(url, name, intent, entryGen),
        timeout: _lockTimeout,
      );
    } on TimeoutException {
      return _handleLockTimeout(name);
    } catch (e, s) {
      debugPrint('[Sentinel] sweep $name @ $url failed: $e\n$s');
      return SweepResult(
        name: name,
        status: SweepStatus.failed,
        variantsBefore: 0,
        variantsAfter: 0,
        elapsed: Duration.zero,
      );
    }
  }

  /// 对当前 url 适用的所有 cookie name 并发执行 sweep。
  ///
  /// name 集合 = jar 中适用 cookie 的 name ∪ WV 中已有 cookie 的 name。
  /// 这样既同步 jar 已有的, 也清理 WV 中孤儿/重复的。
  Future<List<SweepResult>> sweepAll(String url) async {
    final uri = Uri.parse(url);
    final names = <String>{};
    try {
      final jarCookies = await _jar.loadCanonicalCookiesForRequest(uri);
      names.addAll(jarCookies.map((c) => c.name));
    } catch (e) {
      debugPrint('[Sentinel] sweepAll jar lookup failed: $e');
    }
    try {
      final wvCookies = await _writer.getAllCookieInfos(url);
      names.addAll(wvCookies.map((c) => c.name));
    } catch (e) {
      debugPrint('[Sentinel] sweepAll wv lookup failed: $e');
    }
    if (names.isEmpty) return const [];
    final futures = names.map((name) => sweep(url, name, force: true));
    return await Future.wait(futures);
  }

  /// 触发 Nuclear Reset：清空 WV 中 url 适用域下所有 cookie + 从 jar 重灌 + 校验。
  ///
  /// 不再按 criticalCookieNames 过滤,全量处理:
  /// - 先 nuke jar+WV 联合 name set 的所有 variant
  /// - 从 jar 把适用 cookie 全量重灌
  /// - 校验每个 jar cookie 在 WV 中变体数 ≤ 1
  Future<NuclearResetResult> nuclearReset(String url) async {
    final stopwatch = Stopwatch()..start();
    Duration? primingDuration;
    try {
      final uri = Uri.parse(url);
      await _jar.enforceAuthCookiePolicy(reason: 'nuclear_reset');
      final jarCookies = await _jar.loadCanonicalCookiesForRequest(uri);

      // 1. 清空 WV: jar+WV 联合 name set 的所有 variant
      final namesToNuke = <String>{};
      namesToNuke.addAll(jarCookies.map((c) => c.name));
      try {
        final wvCookies = await _writer.getAllCookieInfos(url);
        namesToNuke.addAll(wvCookies.map((c) => c.name));
      } catch (e) {
        debugPrint('[Sentinel] nuclearReset wv lookup failed: $e');
      }
      for (final name in namesToNuke) {
        await _executeDelete(url, name);
      }

      // 2. 从 jar 全量重灌
      final primingStart = stopwatch.elapsed;
      for (final cookie in jarCookies) {
        if (cookie.value.isEmpty) continue;
        if (cookie.expiresAt != null &&
            cookie.expiresAt!.isBefore(DateTime.now())) {
          continue;
        }
        // cf_clearance 单向流(WV→jar):它只在 WebView 中由 CF 签发/更新,
        // Dio 侧不产新值。回灌经 toSetCookieHeader 会丢 Partitioned,在 WV
        // 里复制出一枚 CF 从未签发的非分区副本(双变体来源),一律不回写。
        if (cookie.name == 'cf_clearance') continue;
        // 用 toSetCookieHeader 保留 hostOnly/Domain/SameSite, 避免与 WV
        // 网络层写入的同名 cookie 共存 (详见 _writeWinnerToWebView 注释)
        await _writer.setRawCookie(
          url,
          cookie.toSetCookieHeader(),
          writeSharedStorage: cookie.name != 'cf_clearance',
        );
      }
      primingDuration = stopwatch.elapsed - primingStart;

      // 3. 校验：每个 jar cookie 在 WV 中变体数 ≤ 1
      var allOk = true;
      String? duplicatedName;
      int? duplicatedCount;
      for (final cookie in jarCookies) {
        if (cookie.value.isEmpty) continue;
        final count = await _writer.countCookiesByName(url, cookie.name);
        if (count > 1) {
          allOk = false;
          duplicatedName = cookie.name;
          duplicatedCount = count;
          break;
        }
      }

      return NuclearResetResult(
        success: allOk,
        elapsed: stopwatch.elapsed,
        primingDuration: primingDuration,
        error: allOk
            ? null
            : '$duplicatedName variants still $duplicatedCount after reset',
      );
    } catch (e) {
      return NuclearResetResult(
        success: false,
        elapsed: stopwatch.elapsed,
        primingDuration: primingDuration,
        error: e,
      );
    }
  }

  /// 取消所有进行中的 sweep。
  ///
  /// 设置全局 cancelled flag。短暂等待让 in-flight sweep 在 CHECK 点退出，
  /// 然后清除 flag（不影响后续 sweep）。
  Future<void> cancelAllSweeps() async {
    _globalCancelled = true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _globalCancelled = false;
  }

  /// 该 name 最近 [within] 时长内是否 sweep 过。
  bool wasRecentlySwept(String name, {Duration within = _throttleWindow}) {
    final last = _lastSweptAt[name];
    if (last == null) return false;
    return DateTime.now().difference(last) < within;
  }

  /// 仅测试用：重置内部状态。
  @visibleForTesting
  void resetForTest() {
    _locks.clear();
    _lastSweptAt.clear();
    _consecutiveLockTimeouts.clear();
    _globalCancelled = false;
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  Future<SweepResult> _sweepInternal(
    String url,
    String name,
    SweepIntent intent,
    int entryGen,
  ) async {
    final stopwatch = Stopwatch()..start();
    _eventController.add(SweepInvoked(url: url, name: name, intent: intent));
    CookieLogger.sweep(
      event: 'invoked',
      url: url,
      name: name,
      intent: intent.name,
      entryGeneration: entryGen,
    );

    // CHECK 1: generation
    if (_isCancelled(entryGen)) {
      return _emitCancelled(url, name, entryGen, stopwatch);
    }

    final variantsBefore = await _writer.countCookiesByName(url, name);

    if (intent == SweepIntent.delete) {
      return await _sweepDelete(
        url: url,
        name: name,
        entryGen: entryGen,
        variantsBefore: variantsBefore,
        stopwatch: stopwatch,
      );
    }

    return await _sweepEnsureUnique(
      url: url,
      name: name,
      entryGen: entryGen,
      variantsBefore: variantsBefore,
      stopwatch: stopwatch,
    );
  }

  Future<SweepResult> _sweepDelete({
    required String url,
    required String name,
    required int entryGen,
    required int variantsBefore,
    required Stopwatch stopwatch,
  }) async {
    if (variantsBefore == 0) {
      final result = SweepResult(
        name: name,
        status: SweepStatus.noop,
        variantsBefore: 0,
        variantsAfter: 0,
        elapsed: stopwatch.elapsed,
      );
      _eventController.add(SweepCompleted(result: result));
      CookieLogger.sweep(
        event: 'noop',
        url: url,
        name: name,
        intent: 'delete',
        variantsBefore: 0,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return result;
    }

    await _executeDelete(url, name);

    if (_isCancelled(entryGen)) {
      return _emitCancelled(url, name, entryGen, stopwatch);
    }

    final after = await _writer.countCookiesByName(url, name);
    if (after == 0 || await _residualIsAcceptable(url, name, 0)) {
      _markSweepSuccess(name);
      final result = SweepResult(
        name: name,
        status: SweepStatus.swept,
        variantsBefore: variantsBefore,
        variantsAfter: after,
        elapsed: stopwatch.elapsed,
      );
      _eventController.add(SweepCompleted(result: result));
      CookieLogger.sweep(
        event: 'swept',
        url: url,
        name: name,
        intent: 'delete',
        variantsBefore: variantsBefore,
        variantsAfter: after,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return result;
    }

    return await _doNuclearReset(
      url,
      name,
      SweepIntent.delete,
      variantsBefore,
      stopwatch,
    );
  }

  Future<SweepResult> _sweepEnsureUnique({
    required String url,
    required String name,
    required int entryGen,
    required int variantsBefore,
    required Stopwatch stopwatch,
  }) async {
    if (variantsBefore <= 1) {
      _markSweepSuccess(name);
      final result = SweepResult(
        name: name,
        status: SweepStatus.noop,
        variantsBefore: variantsBefore,
        variantsAfter: variantsBefore,
        elapsed: stopwatch.elapsed,
      );
      _eventController.add(SweepCompleted(result: result));
      CookieLogger.sweep(
        event: 'noop',
        url: url,
        name: name,
        intent: 'ensureUnique',
        variantsBefore: variantsBefore,
        variantsAfter: variantsBefore,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return result;
    }

    // CHECK 2: generation
    if (_isCancelled(entryGen)) {
      return _emitCancelled(url, name, entryGen, stopwatch);
    }

    // pick winner
    final allInfos = await _writer.getAllCookieInfos(url);
    final variants = allInfos
        .where((c) => c.name == name)
        .toList(growable: false);
    final winnerResult = await _pickWinner(name, variants);

    // CHECK 3: generation (在副作用前)
    if (_isCancelled(entryGen)) {
      return _emitCancelled(url, name, entryGen, stopwatch);
    }

    // cf_clearance 单向流(WV→jar):WV 是它唯一的产地,app 绝不删除/重写
    // WV 里的 cf_clearance——删+重写会经 toSetCookieHeader 丢掉 Partitioned,
    // 在 WV 里造出一枚 CF 从未签发的非分区副本(双变体来源)。这里退化为
    // 只读:_pickWinner 已按 expiresDate 取最新那枚,只把它同步进 jar 供
    // native 使用,WV 一概不动(多变体交给 CF 自身与自然过期收敛)。
    if (name == 'cf_clearance') {
      if (winnerResult != null && winnerResult.source == 'webview') {
        await _syncWinnerToJar(url, winnerResult.cookieInfo);
      }
      _markSweepSuccess(name);
      final result = SweepResult(
        name: name,
        status: SweepStatus.swept,
        variantsBefore: variantsBefore,
        variantsAfter: variantsBefore,
        winnerSource: winnerResult?.source,
        elapsed: stopwatch.elapsed,
      );
      _eventController.add(SweepCompleted(result: result));
      CookieLogger.sweep(
        event: 'swept',
        url: url,
        name: name,
        intent: 'ensureUnique',
        variantsBefore: variantsBefore,
        variantsAfter: variantsBefore,
        winnerSource: winnerResult?.source,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return result;
    }

    await _executeDelete(url, name);

    if (winnerResult != null) {
      await _writeWinnerToWebView(url, winnerResult);
    }

    final after = await _writer.countCookiesByName(url, name);
    if (after <= 1 || await _residualIsAcceptable(url, name, 1)) {
      _markSweepSuccess(name);

      // 反向同步 jar（仅当 winner 来自 webview，避免覆写 jar 的最新值）
      if (winnerResult != null && winnerResult.source == 'webview') {
        await _syncWinnerToJar(url, winnerResult.cookieInfo);
      }

      final result = SweepResult(
        name: name,
        status: SweepStatus.swept,
        variantsBefore: variantsBefore,
        variantsAfter: after,
        winnerSource: winnerResult?.source,
        elapsed: stopwatch.elapsed,
      );
      _eventController.add(SweepCompleted(result: result));
      CookieLogger.sweep(
        event: 'swept',
        url: url,
        name: name,
        intent: 'ensureUnique',
        variantsBefore: variantsBefore,
        variantsAfter: after,
        winnerSource: winnerResult?.source,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return result;
    }

    return await _doNuclearReset(
      url,
      name,
      SweepIntent.ensureUnique,
      variantsBefore,
      stopwatch,
    );
  }

  /// 会被 CF 设为 Partitioned(CHIPS)的 cookie 名单:分区那份在 Android WebView
  /// 删不掉(Chromium partition-key bug)、又是合法的跨站共存,不应被当"重复"反复清。
  static const _chipsCookieNames = {'cf_clearance'};

  /// 删除/去重后仍有残留时,判断是否为"可接受的不可删残留"(CHIPS 分区)。
  /// 是则视为成功,停止 sweep_failed 与 nuclear reset 空转——不删除、不影响功能,
  /// 分区那份本就是 CF Turnstile 需要的合法 cookie。
  Future<bool> _residualIsAcceptable(
    String url,
    String name,
    int expectedMaxAfter,
  ) async {
    if (!_chipsCookieNames.contains(name)) return false;
    final variants = (await _writer.getAllCookieInfos(url))
        .where((c) => c.name == name)
        .toList(growable: false);
    if (variants.isEmpty) return true;
    final partitioned = variants.where((c) => c.isPartitioned == true).length;
    final nonPartitioned = variants.length - partitioned;
    // ① 精确(WebView 提供 Partitioned 属性时):分区那份豁免,非分区变体已达标 → 接受。
    final acceptByPartition = nonPartitioned <= expectedMaxAfter;
    // ② 兜底(WebView 未给 Partitioned 属性时):残留全部同值,视为同一 clearance 的
    //    不可删副本(CHIPS 分区 / CF 未轮换)→ 接受。覆盖 getCookieInfo 不带属性的设备。
    final firstVal = variants.first.value;
    final acceptBySameValue = variants.every((c) => c.value == firstVal);
    final accepted = acceptByPartition || acceptBySameValue;
    if (accepted) {
      debugPrint(
        '[Sentinel] residual $name accepted: total=${variants.length} '
        'partitioned=$partitioned nonPartitioned=$nonPartitioned '
        'byPartition=$acceptByPartition bySameValue=$acceptBySameValue',
      );
    }
    return accepted;
  }

  /// 执行删除：穷举 (domain, path) 组合。
  Future<int> _executeDelete(String url, String name) async {
    final uri = Uri.parse(url);
    final host = uri.host.toLowerCase();

    final domainCandidates = <String?>{null, host, '.$host'};
    final reg = _registrableDomain(host);
    if (reg != null && reg != host) {
      domainCandidates.add(reg);
      domainCandidates.add('.$reg');
    }

    final pathCandidates = <String>{_pathDefault};
    try {
      final jarCookies = await _jar.loadCanonicalCookiesForRequest(uri);
      for (final c in jarCookies.where((c) => c.name == name)) {
        if (c.path.isNotEmpty) pathCandidates.add(c.path);
      }
    } catch (e) {
      debugPrint('[Sentinel] _executeDelete jar lookup failed: $e');
    }

    return _writer.nukeAllVariants(
      url: url,
      name: name,
      domainCandidates: domainCandidates.toList(growable: false),
      pathCandidates: pathCandidates.toList(growable: false),
    );
  }

  /// 从 host 提取 registrable domain（简化版：取最后两段）。
  ///
  /// 不处理多级公共后缀（如 .co.uk），项目实际场景为 linux.do / connect.linux.do
  /// 这种 2 级域，简化够用。
  String? _registrableDomain(String host) {
    final parts = host.split('.');
    if (parts.length < 2) return null;
    if (parts.length == 2) return host;
    return parts.sublist(parts.length - 2).join('.');
  }

  /// 从多个变体中选择 winner。
  ///
  /// 规则按优先级:
  /// 1. 与 jar.canonical value 一致 **且** variants 数 == 1 → 胜
  ///    (已唯一,认定 jar 是 source of truth)
  /// 1b. 与 jar.canonical 一致 **且** variants > 1 →
  ///    **winner 选非 jar match 的那条**, 因为 variants > 1 通常意味着
  ///    WV 自己又写了新 cookie (CF 旋转 cf_clearance / 服务器更新 session),
  ///    jar canonical 是滞后的旧值。强行用 jar 覆盖会把 WV 新 cookie 抹掉,
  ///    在 CF 验证场景下会形成 "challenge → 拿新 token → sweep 抹掉 → 又 challenge"
  ///    循环 bug。
  /// 2. value 非空 > 空
  /// 3. 未过期 > 已过期
  /// 4. host-only > domain cookie (字段可用时)
  /// 5. expires 更远 > 更近 (= 更新的 cookie 通常 expires 更远)
  /// 6. value 更长 > 更短
  ///
  /// Android 旧设备字段缺失时自动降级 (只剩 1/2/6 三条规则可用)。
  Future<_WinnerInfo?> _pickWinner(
    String name,
    List<CookieFullInfo> variants,
  ) async {
    if (variants.isEmpty) return null;

    CanonicalCookie? jarCookie;
    try {
      jarCookie = await _jar.getCanonicalCookie(name);
    } catch (e) {
      debugPrint('[Sentinel] _pickWinner jar lookup failed: $e');
    }

    if (jarCookie != null && jarCookie.value.isNotEmpty) {
      final jarValue = jarCookie.value;
      final jarValueDecoded = CookieValueCodec.decode(jarValue);
      final jarMatch = variants.firstWhereOrNull(
        (v) => v.value == jarValue || v.value == jarValueDecoded,
      );

      // Auth cookies are server-authoritative. A WebView snapshot can contain
      // stale host/domain variants, so never pick a non-jar value merely
      // because it differs from the jar value.
      if (CookieJarService.authCookieNames.contains(name)) {
        return _WinnerInfo(
          cookieInfo:
              jarMatch ?? CookieFullInfo(name: name, value: jarCookie.value),
          source: 'jar',
          canonical: jarCookie,
        );
      }

      if (jarMatch != null) {
        // 规则 1: 唯一且与 jar 一致, 直接用 jar canonical
        if (variants.length == 1) {
          return _WinnerInfo(
            cookieInfo: jarMatch,
            source: 'jar',
            canonical: jarCookie,
          );
        }

        // 规则 1b: variants > 1, jar 是滞后旧值, winner 选非 jar match
        // 在剩余 variants 里走规则 2-6 选最优。
        // 关键: 仍带上 canonical, 让 _writeWinnerToWebView 用 canonical
        // 提供 domain/path/sameSite 等元字段, value 用新的 — 这样在 Android
        // (getAllCookieInfos 返回字段全 null) 上也能写出准确 Set-Cookie。
        final others = variants
            .where((v) => v.value != jarValue && v.value != jarValueDecoded)
            .toList(growable: false);
        if (others.isNotEmpty) {
          final sorted = [...others];
          sorted.sort((a, b) => _compareCookieVariants(a, b));
          return _WinnerInfo(
            cookieInfo: sorted.first,
            source: 'webview',
            canonical: jarCookie,
          );
        }
        // 所有 variants 都 == jar value (理论上不该出现,因为是 4-tuple 共存)
        return _WinnerInfo(
          cookieInfo: jarMatch,
          source: 'jar',
          canonical: jarCookie,
        );
      }
    }

    // 规则 2-6
    final sorted = [...variants];
    sorted.sort((a, b) => _compareCookieVariants(a, b));
    return _WinnerInfo(cookieInfo: sorted.first, source: 'webview');
  }

  /// 比较两个变体，返回负值表示 a 更优。
  int _compareCookieVariants(CookieFullInfo a, CookieFullInfo b) {
    // 2. value 非空 > 空
    final aEmpty = a.value.isEmpty;
    final bEmpty = b.value.isEmpty;
    if (aEmpty != bEmpty) return aEmpty ? 1 : -1;

    // 3. 未过期 > 已过期
    final now = DateTime.now().millisecondsSinceEpoch;
    final aExpired = a.expiresMillis != null && a.expiresMillis! < now;
    final bExpired = b.expiresMillis != null && b.expiresMillis! < now;
    if (aExpired != bExpired) return aExpired ? 1 : -1;

    // 4. host-only > domain cookie（字段可用时才比较）
    if (a.domain != null && b.domain != null) {
      if (a.isHostOnly != b.isHostOnly) return a.isHostOnly ? -1 : 1;
    }

    // 5. expires 更远 > 更近
    final aExp = a.expiresMillis ?? 0;
    final bExp = b.expiresMillis ?? 0;
    if (aExp != bExp) return bExp.compareTo(aExp);

    // 6. value 更长 > 更短
    return b.value.length.compareTo(a.value.length);
  }

  /// 将 winner 重写到 WV。
  ///
  /// 三种场景:
  /// - winner.source='jar', canonical 非 null: 直接用 jar canonical
  ///   (WV 中 value 已经 == jar, 写回保持一致)
  /// - winner.source='webview', canonical 非 null (规则 1b 场景):
  ///   jar 是滞后旧值, WV 有更新的 value, 用 canonical 提供 domain/path/
  ///   sameSite 等元字段, value 用 winner 的新值 (在 Android 上 winner 字段
  ///   全 null 时这是唯一的字段来源)
  /// - winner.source='webview', canonical 为 null: 完全用 winner 字段
  ///   fallback (Apple 平台字段可靠, Android 上会丢字段)
  Future<void> _writeWinnerToWebView(
    String url,
    _WinnerInfo winnerResult,
  ) async {
    final canonical = winnerResult.canonical;
    if (canonical != null) {
      final winnerValue = winnerResult.cookieInfo.value;
      // 如果 winner value 跟 canonical 一致 (source='jar'), 直接用 canonical
      // 否则 (source='webview' 规则 1b), 用 canonical 元字段 + winner 新 value
      final cookieToWrite = winnerValue == canonical.value
          ? canonical
          : canonical.copyWith(value: winnerValue);
      await _writer.setRawCookie(
        url,
        cookieToWrite.toSetCookieHeader(),
        writeSharedStorage: cookieToWrite.name != 'cf_clearance',
      );
      return;
    }

    final winner = winnerResult.cookieInfo;
    final uri = Uri.parse(url);
    final attrs = <String>['${winner.name}=${winner.value}'];
    // winner.domain 非空且不等于 host (去 dot 后), 视为 domain cookie, 保留 Domain
    final winnerDomain = winner.domain;
    if (winnerDomain != null && winnerDomain.isNotEmpty) {
      final normalizedWinnerDomain =
          (winnerDomain.startsWith('.')
                  ? winnerDomain.substring(1)
                  : winnerDomain)
              .toLowerCase();
      final host = uri.host.toLowerCase();
      if (normalizedWinnerDomain != host) {
        attrs.add('Domain=$winnerDomain');
      }
    }
    attrs.add('Path=${winner.path ?? _pathDefault}');
    if (uri.scheme == 'https' || (winner.isSecure ?? true)) {
      attrs.add('Secure');
    }
    if (winner.isHttpOnly ?? true) {
      attrs.add('HttpOnly');
    }
    if (winner.expiresMillis != null) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        winner.expiresMillis!,
        isUtc: true,
      );
      attrs.add('Expires=${_formatHttpDate(date)}');
    }
    // 保留 SameSite — 关键: CF 验证 cookie (cf_clearance) 通常是
    // SameSite=None; Secure 用于 third-party iframe (CF Turnstile widget),
    // 丢字段会导致 iframe 上下文不发送 cookie, CF 验证失败循环。
    final sameSite = winner.sameSite;
    if (sameSite != null && sameSite.isNotEmpty) {
      attrs.add('SameSite=$sameSite');
    }
    await _writer.setRawCookie(
      url,
      attrs.join('; '),
      writeSharedStorage: winner.name != 'cf_clearance',
    );
  }

  /// 反向同步 winner 到 jar（路径 B 场景）。
  ///
  /// 跟随 winner 自身 domain 字段写入 jar:
  /// - winner.domain 非空且 ≠ host (去 dot 后): 视为 domain cookie, 透传 domain
  /// - 否则: host-only (不传 domain)
  ///
  /// 这样下次 Priming 从 jar 重灌时,会跟服务器实际 4-tuple 一致,
  /// 与 WV 网络层重写同名 cookie 时覆盖而非共存。
  Future<void> _syncWinnerToJar(String url, CookieFullInfo winner) async {
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      final isAuthCookie = CookieJarService.hostOnlyCookieNames.contains(
        winner.name,
      );
      String? domainToWrite;
      final winnerDomain = winner.domain;
      if (!isAuthCookie && winnerDomain != null && winnerDomain.isNotEmpty) {
        final normalized =
            (winnerDomain.startsWith('.')
                    ? winnerDomain.substring(1)
                    : winnerDomain)
                .toLowerCase();
        if (normalized != host) {
          domainToWrite = winnerDomain;
        }
      }

      await _jar.setCookie(
        winner.name,
        winner.value,
        url: url,
        domain: domainToWrite,
        path: isAuthCookie ? _pathDefault : winner.path ?? _pathDefault,
        expires: winner.expiresMillis != null
            ? DateTime.fromMillisecondsSinceEpoch(
                winner.expiresMillis!,
                isUtc: true,
              )
            : null,
        secure: winner.isSecure ?? true,
        httpOnly: isAuthCookie ? true : winner.isHttpOnly ?? true,
        trusted: isAuthCookie,
      );
    } catch (e) {
      debugPrint('[Sentinel] _syncWinnerToJar failed: $e');
    }
  }

  /// 升级 Nuclear Reset，并构造 SweepResult。
  Future<SweepResult> _doNuclearReset(
    String url,
    String name,
    SweepIntent intent,
    int variantsBefore,
    Stopwatch stopwatch,
  ) async {
    debugPrint('[Sentinel] nuclear reset for $name @ $url');
    CookieLogger.nuclearReset(
      event: 'triggered',
      url: url,
      reason: 'sweep verify failed for $name',
    );
    final nuclear = await nuclearReset(url);
    CookieLogger.nuclearReset(
      event: 'completed',
      url: url,
      primingDurationMs: nuclear.primingDuration?.inMilliseconds,
      totalElapsedMs: nuclear.elapsed.inMilliseconds,
    );
    final after = await _writer.countCookiesByName(url, name);
    final expectedMaxAfter = intent == SweepIntent.delete ? 0 : 1;
    final targetSatisfied =
        after <= expectedMaxAfter || await _residualIsAcceptable(url, name, expectedMaxAfter);
    final status = targetSatisfied
        ? SweepStatus.nuclearReset
        : SweepStatus.failed;
    final result = SweepResult(
      name: name,
      status: status,
      variantsBefore: variantsBefore,
      variantsAfter: after,
      elapsed: stopwatch.elapsed,
    );
    _eventController.add(SweepCompleted(result: result));
    if (targetSatisfied) {
      CookieLogger.sweep(
        event: 'swept',
        url: url,
        name: name,
        intent: intent.name,
        variantsBefore: variantsBefore,
        variantsAfter: after,
        reason: nuclear.success
            ? 'nuclear reset restored target'
            : 'target restored; global reset check failed: ${nuclear.error}',
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    } else {
      CookieLogger.sweep(
        event: 'failed',
        url: url,
        name: name,
        intent: intent.name,
        variantsBefore: variantsBefore,
        variantsAfter: after,
        reason:
            'target variants after reset=$after, expected <= $expectedMaxAfter'
            '${nuclear.error != null ? '; global error: ${nuclear.error}' : ''}',
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }
    return result;
  }

  /// 是否被取消（_globalCancelled 或 generation 不匹配）。
  bool _isCancelled(int entryGen) =>
      _globalCancelled || !_auth.isValid(entryGen);

  SweepResult _emitCancelled(
    String url,
    String name,
    int entryGen,
    Stopwatch stopwatch,
  ) {
    final cur = _auth.generation;
    _eventController.add(
      SweepCancelled(
        url: url,
        name: name,
        entryGeneration: entryGen,
        currentGeneration: cur,
      ),
    );
    CookieLogger.sweep(
      event: 'cancelled',
      url: url,
      name: name,
      entryGeneration: entryGen,
      currentGeneration: cur,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
    return SweepResult(
      name: name,
      status: SweepStatus.cancelled,
      variantsBefore: 0,
      variantsAfter: 0,
      elapsed: stopwatch.elapsed,
    );
  }

  void _markSweepSuccess(String name) {
    _lastSweptAt[name] = DateTime.now();
    _consecutiveLockTimeouts.remove(name);
  }

  SweepResult _handleLockTimeout(String name) {
    final cur = (_consecutiveLockTimeouts[name] ?? 0) + 1;
    _consecutiveLockTimeouts[name] = cur;
    debugPrint(
      '[Sentinel] lock timeout for $name (consecutive=$cur, '
      'max=$_maxConsecutiveLockTimeouts)',
    );
    CookieLogger.lockTimeout(name: name, consecutiveCount: cur);
    return SweepResult(
      name: name,
      status: SweepStatus.failed,
      variantsBefore: 0,
      variantsAfter: 0,
      elapsed: _lockTimeout,
    );
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

/// sweep 意图。
enum SweepIntent {
  /// 保证唯一：清掉多变体，保留一个 winner。
  ensureUnique,

  /// 删除：清掉所有变体，不重写。
  ///
  /// 服务器下发 `value=del` / 空值 / 已过期时使用。
  delete,
}

/// sweep 结果状态。
enum SweepStatus {
  /// 无需操作（variants 已满足前置条件）。
  noop,

  /// 已执行清理。
  swept,

  /// 升级为 Nuclear Reset。
  nuclearReset,

  /// 操作失败。
  failed,

  /// 因 `AuthSession.generation` 不匹配或外部取消而退出。
  cancelled,
}

/// sweep 操作结果。
class SweepResult {
  SweepResult({
    required this.name,
    required this.status,
    required this.variantsBefore,
    required this.variantsAfter,
    this.winnerSource,
    required this.elapsed,
  });

  final String name;
  final SweepStatus status;
  final int variantsBefore;

  /// ensureUnique 时必然 ≤ 1；delete 时必然 == 0；除非 failed。
  final int variantsAfter;

  /// winner 来源：'jar' / 'webview' / null。
  final String? winnerSource;

  final Duration elapsed;

  @override
  String toString() {
    return 'SweepResult(name=$name, status=$status, '
        'before=$variantsBefore, after=$variantsAfter, '
        'winner=$winnerSource, elapsed=${elapsed.inMilliseconds}ms)';
  }
}

/// Nuclear Reset 操作结果。
class NuclearResetResult {
  NuclearResetResult({
    required this.success,
    required this.elapsed,
    this.primingDuration,
    this.error,
  });

  final bool success;
  final Duration elapsed;
  final Duration? primingDuration;
  final Object? error;
}

/// Sentinel 事件基类。
sealed class SweepEvent {
  const SweepEvent();
}

/// sweep 入口事件。
class SweepInvoked extends SweepEvent {
  const SweepInvoked({
    required this.url,
    required this.name,
    required this.intent,
  });
  final String url;
  final String name;
  final SweepIntent intent;
}

/// sweep 完成事件。
class SweepCompleted extends SweepEvent {
  const SweepCompleted({required this.result});
  final SweepResult result;
}

/// sweep 因 generation 不匹配取消事件。
class SweepCancelled extends SweepEvent {
  const SweepCancelled({
    required this.url,
    required this.name,
    required this.entryGeneration,
    required this.currentGeneration,
  });
  final String url;
  final String name;
  final int entryGeneration;
  final int currentGeneration;
}

/// sweep 失败时抛出。
class CookieSweepException implements Exception {
  CookieSweepException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'CookieSweepException: $message'
      '${cause != null ? ' (caused by $cause)' : ''}';
}

/// 内部：winner 信息（cookie + 来源 + 可选的 jar canonical 引用）。
///
/// [canonical] 仅在 winner 来源于 jar（source='jar'）时可用,作为
/// 写回 WV 时的规范化 source of truth(完整的 hostOnly/Domain/SameSite
/// 等字段)。winner 来自 WV 时为 null,fallback 到 [cookieInfo]。
class _WinnerInfo {
  _WinnerInfo({required this.cookieInfo, required this.source, this.canonical});
  final CookieFullInfo cookieInfo;
  final String source;
  final CanonicalCookie? canonical;
}
