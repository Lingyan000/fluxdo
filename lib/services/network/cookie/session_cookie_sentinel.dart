import 'dart:async';

/// Cookie 变体清扫内核（"Sweep" 操作）。
///
/// 核心职责：保证 WV 中每个 critical cookie name 的变体数 ≤ 1
/// （[SweepIntent.delete] 时变体数 == 0）。
///
/// 设计依据：`docs/cookie-sync-design-v0.4.0.md` §5.1
///
/// 关键不变量：
/// - 任一 [sweep] / [sweepAll] 调用返回后，对应 name 的变体数满足后置条件
/// - 同一 name 全局串行（per-name Lock），不同 name 可并行
/// - sweep 进行中遇到 `AuthSession.generation` 变化或 [cancelAllSweeps] 调用，
///   在下个 CHECK 点退出（返回 [SweepStatus.cancelled]）
///
/// 7 类触发源（详见设计文档 §4.3）：
/// 1. Dio onResponse 路径 A
/// 2. Dio onResponse 路径 B（反向同步）
/// 3. WV 导航前
/// 4. WebViewHttpAdapter fetch 前
/// 5. WV onLoadStop
/// 6. App foreground
/// 7. 401 自愈
class SessionCookieSentinel {
  SessionCookieSentinel._();
  static final SessionCookieSentinel instance = SessionCookieSentinel._();

  /// 对指定 url 的 cookie name 执行 sweep。
  ///
  /// 前置：[name] 必须 ∈ `criticalCookieNames`
  ///
  /// 后置：
  /// - [SweepIntent.ensureUnique]: WV 中该 name 的变体数 ≤ 1
  /// - [SweepIntent.delete]: WV 中该 name 的变体数 == 0
  ///
  /// 失败处理：
  /// - 内部自动尝试 Nuclear Reset
  /// - 仍失败抛 [CookieSweepException]
  Future<SweepResult> sweep(
    String url,
    String name, {
    SweepIntent intent = SweepIntent.ensureUnique,
  }) {
    throw UnimplementedError('Phase 3 实现');
  }

  /// 对所有 critical names 并发执行 sweep。
  ///
  /// 不同 name 间不共锁，可并行；同 name 仍串行。
  Future<List<SweepResult>> sweepAll(String url) {
    throw UnimplementedError('Phase 3 实现');
  }

  /// 触发 Nuclear Reset：清空 WV cookie + 从 jar 全量重灌 + 重新 sweep。
  ///
  /// 仅供 [sweep] 内部失败时升级调用。外部一般不直接调用。
  Future<NuclearResetResult> nuclearReset(String url) {
    throw UnimplementedError('Phase 3 实现');
  }

  /// 取消所有进行中的 sweep。
  ///
  /// 调用时机：用户登出。
  /// 设置全局 cancelled flag，正在执行的 sweep 在下个 CHECK 点退出。
  Future<void> cancelAllSweeps() {
    throw UnimplementedError('Phase 3 实现');
  }

  /// 该 name 最近 [within] 时长内是否 sweep 过。
  ///
  /// 触发源用于节流，避免短时间重复 sweep。
  /// 例外：self-healing 不查节流，必执行。
  bool wasRecentlySwept(
    String name, {
    Duration within = const Duration(seconds: 1),
  }) {
    throw UnimplementedError('Phase 3 实现');
  }

  /// Sentinel 事件流，用于日志和监控（参见 §11 可观察性）。
  Stream<SweepEvent> get events => throw UnimplementedError('Phase 3 实现');
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
