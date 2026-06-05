import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';

import '../models/sticker.dart';
import '../services/avif_image_provider.dart';
import '../services/discourse_cache_manager.dart' show StickerCacheManager;
import '../services/sticker_market_service.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

/// 表情包市场服务 Provider
final stickerMarketServiceProvider = Provider<StickerMarketService>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return StickerMarketService(prefs);
});

/// 市场全部非归档分组
final stickerGroupsProvider = FutureProvider<List<StickerGroup>>((ref) async {
  final service = ref.watch(stickerMarketServiceProvider);
  return service.getAllGroups();
});

/// 分组详情（按 groupId 懒加载）
///
/// 加载完成后,异步(idle 优先级)批量 precache 第一屏 sticker 的 thumbnail —
/// 这样用户实际打开 sticker panel / 切到这个 group 时,首屏多数 sticker 已经
/// 在 PNG cache,只需 Flutter 内置 codec 几 ms 解出,不用等 AVIF 解码。
final stickerGroupDetailProvider =
    FutureProvider.family<StickerGroupDetail, String>((ref, groupId) async {
      final service = ref.watch(stickerMarketServiceProvider);
      final detail = await service.getGroupDetail(groupId);
      unawaited(_prefetchFirstScreenThumbnails(groupId, detail.emojis));
      return detail;
    });

/// 当前活跃 prefetch 的 groupId。每次新组进来就覆盖,旧组 task 通过
/// `_activePrefetchGroupId != myGroupId` 自我作废,避免用户快速切组后
/// 老组的 30 张 thumbnail 还在后台占 CPU + ImageCache。
///
/// SchedulerBinding.scheduleTask 本身没有 cancel API,task 一旦 schedule
/// 就会跑;但 task 内部 short-circuit 就够了 —— 没解码 = 没成本。
String? _activePrefetchGroupId;

/// 后台 idle 时预解 sticker thumbnail。
///
/// 用 [SchedulerBinding.scheduleTask] + [Priority.idle],只在 Flutter 帧
/// 渲染空闲间隙跑,不抢主线程。配合 [AvifImageProvider.precacheThumbnail]
/// 内部去重(已预热过的 URL 立即跳过),即使 panel 已经 open 也不会重复 work。
Future<void> _prefetchFirstScreenThumbnails(
  String groupId,
  List<StickerItem> emojis,
) async {
  // sticker_picker grid 用 maxCrossAxisExtent=80,8 列 × 4 行 ≈ 32 张同屏。
  // 预解 30 张覆盖首屏 + 一点滚动 buffer。
  const prefetchCount = 30;
  // 与 sticker_picker `_StickerItemWidget` 的 memCacheWidth=160 一致。
  const targetSize = 160;
  final cache = StickerCacheManager();
  final visible = emojis.length <= prefetchCount
      ? emojis
      : emojis.sublist(0, prefetchCount);

  _activePrefetchGroupId = groupId;

  for (final sticker in visible) {
    SchedulerBinding.instance.scheduleTask<void>(
      () async {
        if (_activePrefetchGroupId != groupId) return;
        try {
          await AvifImageProvider.precacheThumbnail(
            sticker.url,
            targetSize: targetSize,
            cacheManager: cache,
          );
        } catch (e) {
          // prefetch 失败不影响用户实际访问时的兜底解码
          debugPrint('[sticker_prefetch] ${sticker.url}: $e');
        }
      },
      Priority.idle,
    );
  }
}

/// 市场分组分页加载（供市场浏览面板使用）
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
  final StickerMarketService _service;
  int _loadedPages = 0;
  int _totalPages = 0;
  bool _isLoadingMore = false;

  MarketGroupsNotifier(this._service) : super(const AsyncValue.loading()) {
    _loadFirstPage();
  }

  bool get hasMore => _loadedPages < _totalPages;

  Future<void> _loadFirstPage() async {
    try {
      // 并行请求索引和第一页
      final results = await Future.wait([
        _service.getIndex(),
        _service.getGroupsPage(1),
      ]);
      _totalPages = (results[0] as StickerMarketIndex).totalPages;
      _loadedPages = 1;
      state = AsyncValue.data(results[1] as List<StickerGroup>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || !hasMore || state is! AsyncData) return;
    _isLoadingMore = true;
    try {
      final nextPage = _loadedPages + 1;
      final newGroups = await _service.getGroupsPage(nextPage);
      _loadedPages = nextPage;
      if (!mounted) return;

      // 单次提交新页面，避免滚动过程中连续多次 rebuild 整个列表。
      state = AsyncValue.data([...state.value!, ...newGroups]);
    } catch (e) {
      debugPrint('[MarketGroups] 加载第${_loadedPages + 1}页失败: $e');
    } finally {
      _isLoadingMore = false;
    }
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    _loadedPages = 0;
    _totalPages = 0;
    await _loadFirstPage();
  }
}

/// 已订阅的分组 ID 列表（响应式）
final subscribedStickerIdsProvider =
    StateNotifierProvider<SubscribedStickerIdsNotifier, List<String>>((ref) {
      final service = ref.watch(stickerMarketServiceProvider);
      return SubscribedStickerIdsNotifier(service);
    });

class SubscribedStickerIdsNotifier extends StateNotifier<List<String>> {
  final StickerMarketService _service;

  SubscribedStickerIdsNotifier(this._service)
    : super(_service.getSubscribedGroupIds());

  Future<void> subscribe(String groupId) async {
    await _service.subscribe(groupId);
    state = _service.getSubscribedGroupIds();
  }

  Future<void> unsubscribe(String groupId) async {
    await _service.unsubscribe(groupId);
    state = _service.getSubscribedGroupIds();
  }

  bool isSubscribed(String groupId) => state.contains(groupId);
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
