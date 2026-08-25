import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bookmarks_reconciler.dart';
import 'bookmarks_repository.dart';
import 'user_content_providers.dart';

/// 书签同步阶段。
enum BookmarkSyncPhase { idle, syncing, failed }

/// 全局书签同步状态:与列表数据([BookmarksNotifier])彻底解耦,
/// 列表的 loading 永远不因对账而转圈。
class BookmarkSyncState {
  const BookmarkSyncState({
    this.phase = BookmarkSyncPhase.idle,
    this.mode,
    this.isInitialSync = false,
  });

  final BookmarkSyncPhase phase;

  /// syncing 时的对账模式。
  final ReconcileMode? mode;

  /// 是否"本地为空的首次同步"(同步中/失败时有意义):书签页空态据此
  /// 区分「正在同步」「同步失败可重试」「真没有书签」三种展示。
  final bool isInitialSync;

  bool get isSyncing => phase == BookmarkSyncPhase.syncing;
  bool get isFailed => phase == BookmarkSyncPhase.failed;
}

/// 书签同步控制器(全局、非 autoDispose)。
///
/// 对账的触发时机、节流窗口、24h 全量判定、失败态全部收口在这里;
/// [BookmarksNotifier] 只管本地 hydrate + 分页。此前对账状态寄生在
/// autoDispose 的列表 notifier 里:页面进出各自开跑对账、对账中途
/// 切页要靠 keepAlive 续命、同步转圈还串到列表 footer 上,全是状态
/// 放错层的连锁反应。
class BookmarkSyncController extends Notifier<BookmarkSyncState> {
  /// 增量对账节流:距上次成功对账不足该间隔时,进页面不再重复开跑。
  static const Duration kIncrementalThrottle = Duration(minutes: 5);

  /// 首次(本地空)同步失败后的自动重试间隔:防断网时每次进页面都
  /// 从头全量翻页;空态「重试」按钮走 force 不受此限。
  static const Duration kInitialRetryBackoff = Duration(seconds: 30);

  /// 各账号上次成功对账(增量或全量)的时间,作节流依据。
  final Map<String, DateTime> _lastFreshAt = {};
  final Map<String, DateTime> _lastInitialAttemptAt = {};
  Future<void>? _inFlight;
  bool _pullInFlight = false;

  @override
  BookmarkSyncState build() => const BookmarkSyncState();

  /// 进页面时的数据保鲜:本地空 → 全量(首次);全量到期(24h)→ 全量;
  /// 否则增量,且带节流窗口。进行中重复调用直接跳过。
  Future<void> ensureFreshness({bool force = false}) async {
    if (_inFlight != null) return;
    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      await _ensureFreshness(force: force);
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  Future<void> _ensureFreshness({required bool force}) async {
    final accountId = await _accountId();
    if (accountId == null || !ref.mounted) return;
    final reconciler = await ref.read(bookmarksReconcilerProvider.future);
    if (!ref.mounted) return;
    final repo = ref.read(bookmarksRepositoryProvider);
    final localEmpty = (await repo.idsOrderedByUpdated(accountId)).isEmpty;
    if (!ref.mounted) return;
    final now = DateTime.now();

    if (localEmpty) {
      final lastAttempt = _lastInitialAttemptAt[accountId];
      if (!force &&
          lastAttempt != null &&
          now.difference(lastAttempt) < kInitialRetryBackoff) {
        return;
      }
      _lastInitialAttemptAt[accountId] = now;
      await _run(accountId, reconciler, mode: ReconcileMode.full, initial: true);
      return;
    }

    if (reconciler.isFullReconcileDue(accountId)) {
      await _run(accountId, reconciler, mode: ReconcileMode.full, initial: false);
      return;
    }

    final lastFresh = _lastFreshAt[accountId];
    if (!force &&
        lastFresh != null &&
        now.difference(lastFresh) < kIncrementalThrottle) {
      return;
    }
    await _run(
      accountId,
      reconciler,
      mode: ReconcileMode.incremental,
      initial: false,
    );
  }

  /// 手动全量对账(工具栏 sync 按钮):无视节流;已有对账进行中时返回 null。
  Future<ReconcileReport?> manualFullSync() async {
    if (_inFlight != null) return null;
    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      final accountId = await _accountId();
      if (accountId == null || !ref.mounted) return null;
      final reconciler = await ref.read(bookmarksReconcilerProvider.future);
      if (!ref.mounted) return null;
      final localEmpty = (await ref
              .read(bookmarksRepositoryProvider)
              .idsOrderedByUpdated(accountId))
          .isEmpty;
      if (!ref.mounted) return null;
      return await _run(
        accountId,
        reconciler,
        mode: ReconcileMode.full,
        initial: localEmpty,
      );
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  /// 拉第一页 upsert:下拉刷新手势与"添加/编辑书签成功后的静默保鲜"共用。
  ///
  /// 服务端按 updated_at DESC 返回,刚增改的条目必在第一页——所以增改
  /// 不需要客户端拼 payload 写穿(列表 entry 的 payload 只有列表接口
  /// 给得全),静默拉一页即可让书签列表立刻反映变化。
  Future<void> pullFirstPage() async {
    if (_pullInFlight) return;
    if (state.isSyncing) return; // 对账进行中,其结果自然覆盖
    _pullInFlight = true;
    try {
      final accountId = await _accountId();
      if (accountId == null || !ref.mounted) return;
      final reconciler = await ref.read(bookmarksReconcilerProvider.future);
      await reconciler.pullToRefresh(accountId);
    } catch (_) {
      // 静默保鲜失败无害:下次对账会补上
    } finally {
      _pullInFlight = false;
    }
  }

  /// 删除书签的本地写穿(全入口统一收口):服务端 DELETE 成功后调用,
  /// 立刻删掉 Hive 对应条目——否则要等下次对账才消失,期间书签列表
  /// 仍展示已删条目。
  Future<void> purgeLocal(int bookmarkId) async {
    try {
      final accountId = await _accountId();
      if (accountId == null || !ref.mounted) return;
      await ref
          .read(bookmarksRepositoryProvider)
          .deleteOne(accountId, bookmarkId);
    } catch (_) {
      // 缓存清理失败无害:下次全量对账会纠正
    }
  }

  /// 登出重置:清掉节流时间戳与失败态。
  void reset() {
    _lastFreshAt.clear();
    _lastInitialAttemptAt.clear();
    state = const BookmarkSyncState();
  }

  Future<ReconcileReport?> _run(
    String accountId,
    BookmarksReconciler reconciler, {
    required ReconcileMode mode,
    required bool initial,
  }) async {
    state = BookmarkSyncState(
      phase: BookmarkSyncPhase.syncing,
      mode: mode,
      isInitialSync: initial,
    );
    ReconcileReport? report;
    try {
      report = mode == ReconcileMode.full
          ? await reconciler.fullReconcile(accountId)
          : await reconciler.incrementalReconcile(accountId);
    } catch (_) {
      report = null;
    }
    final failed =
        report == null || report.stopReason == ReconcileStopReason.errored;
    if (!ref.mounted) return report;
    if (failed) {
      state = BookmarkSyncState(
        phase: BookmarkSyncPhase.failed,
        isInitialSync: initial,
      );
    } else {
      _lastFreshAt[accountId] = DateTime.now();
      state = const BookmarkSyncState();
    }
    return report;
  }

  Future<String?> _accountId() async {
    try {
      return await ref.read(currentUsernameProvider.future);
    } catch (_) {
      return null;
    }
  }
}

/// 全局书签同步控制器 Provider。
final bookmarkSyncControllerProvider =
    NotifierProvider<BookmarkSyncController, BookmarkSyncState>(
      BookmarkSyncController.new,
    );
