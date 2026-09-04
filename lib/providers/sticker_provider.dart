import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';

import '../models/sticker.dart';
import '../services/app_logger.dart';
import '../services/sticker_market_service.dart';
import '../services/sticker_thumbnail_provider.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

/// 表情包市场服务 Provider
final stickerMarketServiceProvider = Provider<StickerMarketService>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return StickerMarketService(prefs);
});

/// 分组详情（按 groupId 懒加载）
///
/// 加载完成后,异步批量 precache 第一屏 sticker 的 thumbnail —
/// 这样用户实际打开 sticker panel / 切到这个 group 时,首屏多数 sticker 已经
/// 在 PNG cache,只需 Flutter 内置 codec 几 ms 解出,不用等动图解码。
///
/// 同时把 name/icon 回填到已订阅分组的元信息缓存:老版本升级上来的订阅只有
/// id、没有元信息,tab 栏先显示占位,详情到手即自愈;分组在市场侧改了名字
/// 或图标也从这里跟上。
final stickerGroupDetailProvider =
    FutureProvider.family<StickerGroupDetail, String>((ref, groupId) async {
      final service = ref.watch(stickerMarketServiceProvider);
      try {
        final detail = await service.getGroupDetail(groupId);
        unawaited(_prefetchFirstScreenThumbnails(groupId, detail.emojis));
        unawaited(
          ref
              .read(subscribedStickerGroupsProvider.notifier)
              .refreshMetaFromDetail(groupId, detail),
        );
        return detail;
      } catch (e, st) {
        AppLogger.error(
          '加载表情包分组详情失败',
          tag: 'Sticker',
          error: e,
          stackTrace: st,
          fields: {'groupId': groupId, 'baseUrl': service.baseUrl},
        );
        rethrow;
      }
    });

/// 当前活跃 prefetch 的 groupId。每次新组进来就覆盖,旧组 task 通过
/// `_activePrefetchGroupId != myGroupId` 自我作废,避免用户快速切组后
/// 老组的 30 张 thumbnail 还在后台占 CPU + ImageCache。
String? _activePrefetchGroupId;

/// sticker panel 是否处于打开状态(默认 true 乐观允许,只在显式 close 时 false)。
/// panel 关闭时,正在跑的 prefetch batch 通过 `shouldContinue` 立即停下来,
/// 避免主 isolate 在 panel 关闭后仍被后台 decode + marshalling 占用,
/// 造成"关闭面板还掉帧"的现象。
///
/// 由 [stickerPanelOpened] / [stickerPanelClosed] 在 StickerPicker
/// initState / dispose 调用。
bool _stickerPanelOpen = true;

void stickerPanelOpened() {
  _stickerPanelOpen = true;
}

void stickerPanelClosed() {
  _stickerPanelOpen = false;
  // 同时主动 "作废" 所有正在跑的 prefetch group(即使 groupId 没变)
  _activePrefetchGroupId = null;
}

/// 后台异步批量预解 sticker thumbnail。
///
/// **关键优化:用 [StickerThumbnailProvider.precacheBatch] 一次解 30 张,
/// 把 30 个 `Isolate.run` 摊薄成 ~4 个**(chunked,每 chunk 8 张)。
/// Isolate spawn 是几十 ms 量级开销,30× 累加起来主线程会感知卡顿;
/// chunk 化后 spawn 开销可控,且 chunk 间能 cancel(切组 / 关 panel)。
Future<void> _prefetchFirstScreenThumbnails(
  String groupId,
  List<StickerItem> emojis,
) async {
  // sticker_picker grid 用 maxCrossAxisExtent=80,8 列 × 4 行 ≈ 32 张同屏。
  // 预解 30 张覆盖首屏 + 一点滚动 buffer。
  const prefetchCount = 30;
  // 与 sticker_picker `_StickerItemWidget` 的 memCacheWidth=160 一致。
  const targetSize = 160;
  final visible = emojis.length <= prefetchCount
      ? emojis
      : emojis.sublist(0, prefetchCount);

  _activePrefetchGroupId = groupId;

  try {
    await StickerThumbnailProvider.precacheBatch(
      visible.map((s) => s.url).toList(growable: false),
      targetSize: targetSize,
      shouldContinue: () =>
          _stickerPanelOpen && _activePrefetchGroupId == groupId,
    );
  } catch (e) {
    debugPrint('[sticker_prefetch] batch failed (group=$groupId): $e');
  }
}

/// 市场分类（topic）列表（市场面板的分类 chips 数据源）
///
/// 唯一来源是服务端 topics.json，分类增删不需要发版。
final marketTopicsProvider =
    FutureProvider.autoDispose<List<StickerMarketTopic>>((ref) async {
      final service = ref.watch(stickerMarketServiceProvider);
      return service.getTopics();
    });

/// 市场分组分页加载（供市场浏览面板使用）
///
/// 两种模式：
/// - 浏览模式：按页懒加载当前分类（topic）的分组，滚动到底自动翻页；
/// - 搜索模式：查询非空时先按已加载结果即时过滤，同时并行拉全当前
///   分类的剩余页再全量过滤（全市场 ~300 组，全量拉取代价可忽略，
///   页数据本就有 24h 缓存）。
final marketGroupsProvider =
    StateNotifierProvider.autoDispose<
      MarketGroupsNotifier,
      AsyncValue<List<StickerGroup>>
    >((ref) {
      final service = ref.watch(stickerMarketServiceProvider);
      return MarketGroupsNotifier(service);
    });

class MarketGroupsNotifier
    extends StateNotifier<AsyncValue<List<StickerGroup>>> {
  MarketGroupsNotifier(this._service) : super(const AsyncValue.loading()) {
    _loadFirstPage();
  }

  final StickerMarketService _service;

  /// 当前分类 id（'all' = 全部）
  String _topic = 'all';
  String _query = '';
  int _loadedPages = 0;
  int _totalPages = 0;
  bool _isLoadingMore = false;
  bool _isLoadMoreFailed = false;

  /// 浏览模式下已加载的分组（未过滤；搜索过滤在其上进行）
  List<StickerGroup> _groups = [];

  /// 数据世代：分类切换 / refresh 时递增。首页加载与翻页都带世代出门，
  /// 回来发现世代变了就整包丢弃 —— 旧分类的页混进新分类不仅内容错，
  /// 还会打乱 `_loadedPages/_totalPages` 游标，把后续翻页导向不存在的
  /// `{topic}-page-N.json`。
  int _dataSeq = 0;

  /// 搜索世代：仅搜索补页用。搜索是在同一份数据上过滤，**不能**作废
  /// 在飞的首页加载，因此必须与 [_dataSeq] 分开计数。
  int _querySeq = 0;

  bool get isSearchMode => _query.isNotEmpty;
  bool get hasMore => !isSearchMode && _loadedPages < _totalPages;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;

  void _emit(List<StickerGroup> groups, {bool loading = false}) {
    if (!mounted) return;
    state = loading
        ? const AsyncValue.loading()
        : AsyncValue.data(List<StickerGroup>.of(groups));
  }

  List<StickerGroup> _applyQuery() {
    if (_query.isEmpty) return _groups;
    final q = _query.toLowerCase();
    return _groups.where((g) => g.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _loadFirstPage() async {
    // 世代由调用方（构造/setTopic/refresh）负责递增，这里只读取快照。
    final dataSeq = _dataSeq;
    _emit(const [], loading: true);
    try {
      final (groups, totalPages) = await _service.getGroupsPageWithMeta(
        1,
        topic: _topic,
      );
      if (dataSeq != _dataSeq || !mounted) return;
      _groups = groups;
      _loadedPages = 1;
      _totalPages = totalPages;
      _isLoadMoreFailed = false;
      _emit(_applyQuery());
      // 首屏 loading 期间就输入了搜索词：此时缺页还没补，补齐后才是完整结果。
      if (isSearchMode) await _ensureAllPagesLoaded();
    } catch (e, st) {
      if (dataSeq != _dataSeq || !mounted) return;
      AppLogger.error(
        '加载表情包市场首页失败',
        tag: 'Sticker',
        error: e,
        stackTrace: st,
        fields: {'baseUrl': _service.baseUrl, 'topic': _topic},
      );
      state = AsyncValue.error(e, st);
    }
  }

  /// 补齐当前分类剩余页。搜索要在全量数据上过滤才不会漏结果；
  /// 全市场 ~300 组、页数据本就有 24h 缓存，全量拉取代价可忽略。
  Future<void> _ensureAllPagesLoaded() async {
    if (_loadedPages == 0 || _loadedPages >= _totalPages) return;
    final dataSeq = _dataSeq;
    final querySeq = ++_querySeq;
    try {
      final missingPages = [
        for (var p = _loadedPages + 1; p <= _totalPages; p++) p,
      ];
      final fetched = await Future.wait(
        missingPages.map((p) => _service.getGroupsPage(p, topic: _topic)),
      );
      if (dataSeq != _dataSeq || querySeq != _querySeq || !mounted) return;
      for (final pageGroups in fetched) {
        _groups.addAll(pageGroups);
      }
      _loadedPages = _totalPages;
    } catch (e, st) {
      if (dataSeq != _dataSeq || querySeq != _querySeq || !mounted) return;
      AppLogger.warning(
        '表情包市场搜索拉全量页失败，按已加载结果过滤',
        tag: 'Sticker',
        fields: {
          'topic': _topic,
          'query': _query,
          'error': e.toString(),
          'stackTrace': st.toString(),
        },
      );
    }
    _emit(_applyQuery());
  }

  /// 切换分类。清空搜索词（UI 侧同步清空输入框），重载该分类第一页。
  Future<void> setTopic(String topic) async {
    if (topic == _topic) return;
    _dataSeq++; // 作废在飞的首页加载 / 翻页
    _querySeq++; // 作废在飞的搜索补页
    _topic = topic;
    _query = '';
    _groups = [];
    _loadedPages = 0;
    _totalPages = 0;
    _isLoadingMore = false;
    _isLoadMoreFailed = false;
    await _loadFirstPage();
  }

  /// 设置搜索词。空串退出搜索模式回到浏览态；非空先即时过滤已加载
  /// 结果，缺页时后台拉全再全量过滤。
  Future<void> setQuery(String rawQuery) async {
    final query = rawQuery.trim();
    if (query == _query) return;
    _query = query;
    if (_query.isEmpty) {
      _querySeq++; // 作废在飞的补页
      _emit(_groups);
      return;
    }

    // 先展示已加载部分的过滤结果（首键即有反馈）
    _emit(_applyQuery());
    await _ensureAllPagesLoaded();
  }

  Future<void> loadMore() async {
    if (_isLoadingMore ||
        !hasMore ||
        state is! AsyncData ||
        _isLoadMoreFailed) {
      return;
    }
    final dataSeq = _dataSeq;
    _isLoadingMore = true;
    _isLoadMoreFailed = false;
    _emit(_applyQuery());
    try {
      final nextPage = _loadedPages + 1;
      final (newGroups, totalPages) = await _service.getGroupsPageWithMeta(
        nextPage,
        topic: _topic,
      );
      if (dataSeq != _dataSeq || !mounted) return;
      _loadedPages = nextPage;
      _totalPages = totalPages;
      _groups.addAll(newGroups);

      // 单次提交新页面，避免滚动过程中连续多次 rebuild 整个列表。
      _emit(_applyQuery());
    } catch (e, st) {
      if (dataSeq != _dataSeq || !mounted) return;
      _isLoadMoreFailed = true;
      AppLogger.warning(
        '加载表情包市场分页失败',
        tag: 'Sticker',
        fields: {
          'page': _loadedPages + 1,
          'topic': _topic,
          'baseUrl': _service.baseUrl,
          'error': e.toString(),
          'stackTrace': st.toString(),
        },
      );
    } finally {
      // 世代已变说明 setTopic/refresh 早已重置过这些字段，不能再回写。
      if (dataSeq == _dataSeq) {
        _isLoadingMore = false;
        _emit(_applyQuery());
      }
    }
  }

  Future<void> retryLoadMore() async {
    if (!_isLoadMoreFailed) return;
    _isLoadMoreFailed = false;
    _emit(_applyQuery());
    await loadMore();
  }

  /// 重载当前分类第一页（错误重试入口）。同时退出搜索模式。
  Future<void> refresh() async {
    _dataSeq++; // 作废在飞的首页加载 / 翻页
    _querySeq++; // 作废在飞的搜索补页
    _query = '';
    _groups = [];
    _loadedPages = 0;
    _totalPages = 0;
    _isLoadingMore = false;
    _isLoadMoreFailed = false;
    await _loadFirstPage();
  }
}

/// 已订阅的分组（响应式，含 tab 栏所需的 name/icon）
///
/// 单一数据源：订阅态判定与 tab 栏渲染都从这里派生，不再有「id 一份、
/// 元信息另一份」两套状态。初值是 prefs 同步读，面板首帧即可用，
/// 不发任何请求。
final subscribedStickerGroupsProvider =
    StateNotifierProvider<SubscribedStickerGroupsNotifier, List<StickerGroup>>((
      ref,
    ) {
      final service = ref.watch(stickerMarketServiceProvider);
      return SubscribedStickerGroupsNotifier(service);
    });

class SubscribedStickerGroupsNotifier
    extends StateNotifier<List<StickerGroup>> {
  final StickerMarketService _service;

  SubscribedStickerGroupsNotifier(this._service)
    : super(_service.getSubscribedGroups());

  Future<void> subscribe(StickerGroup group) async {
    await _service.subscribe(group);
    state = _service.getSubscribedGroups();
  }

  Future<void> unsubscribe(String groupId) async {
    await _service.unsubscribe(groupId);
    state = _service.getSubscribedGroups();
  }

  bool isSubscribed(String groupId) => state.any((g) => g.id == groupId);

  /// 从分组详情回填元信息（升级迁移 + 改名换图自愈）。
  ///
  /// 详情只带 id/name/icon，order/topic/isArchived 沿用已有缓存值；
  /// emojiCount 用详情里的实际条数（比市场列表的快照更准）。
  /// 未订阅的分组不写盘 —— 详情会被市场面板之外的路径拉到。
  Future<void> refreshMetaFromDetail(
    String groupId,
    StickerGroupDetail detail,
  ) async {
    if (!_service.isSubscribed(groupId)) return;
    final existing = state.firstWhere(
      (g) => g.id == groupId,
      orElse: () => StickerGroup(
        id: groupId,
        name: '',
        icon: '',
        order: 0,
        emojiCount: 0,
        isArchived: false,
      ),
    );
    final merged = existing.copyWith(
      name: detail.name,
      icon: detail.icon,
      emojiCount: detail.emojis.length,
    );
    if (_service.isSubscribedMetaFresh(merged)) return;
    await _service.cacheSubscribedGroupMeta(merged);
    if (!mounted) return;
    state = _service.getSubscribedGroups();
  }
}

/// 最近使用的表情包（响应式）
final recentStickersProvider =
    StateNotifierProvider<RecentStickersNotifier, List<StickerItem>>((ref) {
      final service = ref.watch(stickerMarketServiceProvider);
      return RecentStickersNotifier(service);
    });

class RecentStickersNotifier extends StateNotifier<List<StickerItem>> {
  final StickerMarketService _service;

  RecentStickersNotifier(this._service) : super(_service.getRecentStickers());

  Future<void> add(StickerItem sticker) async {
    await _service.addRecentSticker(sticker);
    state = _service.getRecentStickers();
  }
}
