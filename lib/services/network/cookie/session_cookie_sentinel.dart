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
  /// 详见 §5.1 接口契约。
  Future<SweepResult> sweep(
    String url,
    String name, {
    SweepIntent intent = SweepIntent.ensureUnique,
  }) async {
    if (!criticalCookieNames.contains(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Cookie name not in criticalCookieNames',
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

  /// 对所有 critical names 并发执行 sweep。
  Future<List<SweepResult>> sweepAll(String url) async {
    final futures = criticalCookieNames.map((name) => sweep(url, name));
    return await Future.wait(futures);
  }

  /// 触发 Nuclear Reset：清空 WV 所有 critical cookies + 从 jar 重灌 + 校验。
  Future<NuclearResetResult> nuclearReset(String url) async {
    final stopwatch = Stopwatch()..start();
    Duration? primingDuration;
    try {
      // 1. 清空 WV 中所有 critical names 的变体
      for (final name in criticalCookieNames) {
        await _executeDelete(url, name);
      }

      // 2. 从 jar 重灌（避免循环依赖 Priming，这里直接走 RawCookieWriter）
      final primingStart = stopwatch.elapsed;
      final uri = Uri.parse(url);
      final jarCookies = await _jar.loadCanonicalCookiesForRequest(uri);
      for (final cookie in jarCookies.where(
        (c) => criticalCookieNames.contains(c.name),
      )) {
        if (cookie.value.isEmpty) continue;
        if (cookie.expiresAt != null &&
            cookie.expiresAt!.isBefore(DateTime.now())) {
          continue;
        }
        await _writer.setRawCookie(url, _buildRawHeader(cookie));
      }
      primingDuration = stopwatch.elapsed - primingStart;

      // 3. 校验：所有 critical names 变体数 ≤ 1
      var allOk = true;
      for (final name in criticalCookieNames) {
        final count = await _writer.countCookiesByName(url, name);
        if (count > 1) {
          allOk = false;
          break;
        }
      }

      return NuclearResetResult(
        success: allOk,
        elapsed: stopwatch.elapsed,
        primingDuration: primingDuration,
        error: allOk ? null : 'Variants still > 1 after reset',
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
  bool wasRecentlySwept(
    String name, {
    Duration within = _throttleWindow,
  }) {
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
    if (after == 0) {
      _markSweepSuccess(name);
      final result = SweepResult(
        name: name,
        status: SweepStatus.swept,
        variantsBefore: variantsBefore,
        variantsAfter: 0,
        elapsed: stopwatch.elapsed,
      );
      _eventController.add(SweepCompleted(result: result));
      CookieLogger.sweep(
        event: 'swept',
        url: url,
        name: name,
        intent: 'delete',
        variantsBefore: variantsBefore,
        variantsAfter: 0,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return result;
    }

    return await _doNuclearReset(url, name, variantsBefore, stopwatch);
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

    await _executeDelete(url, name);

    if (winnerResult != null) {
      await _writeWinnerToWebView(url, winnerResult.cookieInfo);
    }

    final after = await _writer.countCookiesByName(url, name);
    if (after <= 1) {
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

    return await _doNuclearReset(url, name, variantsBefore, stopwatch);
  }

  /// 执行删除：穷举 (domain, path) 组合。
  Future<int> _executeDelete(String url, String name) async {
    final uri = Uri.parse(url);
    final host = uri.host.toLowerCase();

    final domainCandidates = <String?>{
      null,
      host,
      '.$host',
    };
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
  /// 规则按优先级（设计文档 §5.1.1）：
  /// 1. 与 jar.canonical value 一致 → 胜（最强信号）
  /// 2. value 非空 > 空
  /// 3. 未过期 > 已过期
  /// 4. host-only > domain cookie（字段可用时）
  /// 5. expires 更远 > 更近
  /// 6. value 更长 > 更短
  ///
  /// Android 旧设备字段缺失时自动降级（只剩 1/2/6 三条规则可用）。
  Future<_WinnerInfo?> _pickWinner(
    String name,
    List<CookieFullInfo> variants,
  ) async {
    if (variants.isEmpty) return null;

    // 规则 1: 与 jar.canonical 一致
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
      if (jarMatch != null) {
        return _WinnerInfo(cookieInfo: jarMatch, source: 'jar');
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

  /// 将 winner 重写到 WV（规范 host-only 形式）。
  Future<void> _writeWinnerToWebView(
    String url,
    CookieFullInfo winner,
  ) async {
    final uri = Uri.parse(url);
    final attrs = <String>['${winner.name}=${winner.value}'];
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
    await _writer.setRawCookie(url, attrs.join('; '));
  }

  /// 从 CanonicalCookie 构造规范 Set-Cookie 头。
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

  /// 反向同步 winner 到 jar（路径 B 场景）。
  Future<void> _syncWinnerToJar(String url, CookieFullInfo winner) async {
    try {
      await _jar.setCookie(
        winner.name,
        winner.value,
        url: url,
        path: winner.path ?? _pathDefault,
        expires: winner.expiresMillis != null
            ? DateTime.fromMillisecondsSinceEpoch(
                winner.expiresMillis!,
                isUtc: true,
              )
            : null,
        secure: winner.isSecure ?? true,
        httpOnly: winner.isHttpOnly ?? true,
        // 不传 domain → host-only（规范形式）
      );
    } catch (e) {
      debugPrint('[Sentinel] _syncWinnerToJar failed: $e');
    }
  }

  /// 升级 Nuclear Reset，并构造 SweepResult。
  Future<SweepResult> _doNuclearReset(
    String url,
    String name,
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
    final status = nuclear.success ? SweepStatus.nuclearReset : SweepStatus.failed;
    final result = SweepResult(
      name: name,
      status: status,
      variantsBefore: variantsBefore,
      variantsAfter: after,
      elapsed: stopwatch.elapsed,
    );
    _eventController.add(SweepCompleted(result: result));
    if (!nuclear.success) {
      CookieLogger.sweep(
        event: 'failed',
        url: url,
        name: name,
        variantsBefore: variantsBefore,
        variantsAfter: after,
        reason: 'nuclear reset failed: ${nuclear.error}',
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
  String toString() => 'CookieSweepException: $message'
      '${cause != null ? ' (caused by $cause)' : ''}';
}

/// 内部：winner 信息（cookie + 来源）。
class _WinnerInfo {
  _WinnerInfo({required this.cookieInfo, required this.source});
  final CookieFullInfo cookieInfo;
  final String source;
}
