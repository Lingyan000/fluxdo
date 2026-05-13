import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_providers.dart';
import 'bookmark_name_suggestions_provider.dart';
import 'notification_list_provider.dart';
import 'topic_list/topic_list_provider.dart';
import 'topic_list/filter_provider.dart';
import 'topic_list/sort_provider.dart';
import 'topic_list/tab_state_provider.dart';
import 'pinned_categories_provider.dart';
import 'user_content_providers.dart';
import 'category_provider.dart';
import 'message_bus/notification_providers.dart';
import 'message_bus/topic_tracking_providers.dart';
import 'ldc_providers.dart';
import 'cdk_providers.dart';

class AppStateRefresher {
  AppStateRefresher._();

  static DateTime? _lastRefreshTime;

  static void refreshAll(WidgetRef ref) {
    // 去抖：2 秒内重复调用直接跳过（如 authStateProvider listener + _goToLogin 同时触发）
    final now = DateTime.now();
    if (_lastRefreshTime != null && now.difference(_lastRefreshTime!) < const Duration(seconds: 2)) {
      return;
    }
    _lastRefreshTime = now;

    // 第一批：主页渲染必需（用户信息 + 分类 + 话题列表）
    for (final refresh in _coreRefreshers) {
      refresh(ref);
    }
    _refreshTopicTabs(ref);
    // 第二批：延迟 1 秒执行，避免并发请求过多触发风控
    Future.delayed(const Duration(seconds: 1), () {
      for (final refresh in _deferredRefreshers) {
        refresh(ref);
      }
    });
  }

  static Future<void> resetForLogout(WidgetRef ref) async {
    ref.read(currentUserProvider.notifier).clearCache();
    ref.read(userSummaryProvider.notifier).clearCache();
    ref.read(bookmarkNameSuggestionsProvider.notifier).clearCache();
    // 登出时 invalidate 所有（不会发请求，因为数据被清空了）
    for (final refresh in _coreRefreshers) {
      refresh(ref);
    }
    for (final refresh in _deferredRefreshers) {
      refresh(ref);
    }
    // 重置筛选/排序/标签（会通过 signal listener 触发话题列表刷新，
    // 无需再手动 invalidate 话题列表）
    ref.read(topicFilterProvider.notifier).setFilter(TopicListFilter.latest);
    ref.read(topicSortOrderProvider.notifier).setOrder(TopicSortOrder.defaultOrder);
    ref.read(topicSortAscendingProvider.notifier).setAscending(false);
    final pinnedIds = ref.read(pinnedCategoriesProvider);
    ref.read(tabTagsProvider(null).notifier).state = [];
    for (final id in pinnedIds) {
      ref.read(tabTagsProvider(id).notifier).state = [];
    }
    ref.read(activeCategorySlugsProvider.notifier).reset();
    await ref.read(ldcUserInfoProvider.notifier).disable();
    await ref.read(cdkUserInfoProvider.notifier).disable();
  }

  /// 刷新话题列表各 tab
  /// 只刷新当前 tab，非活跃 tab 标记 stale，切换到时才刷新
  static void _refreshTopicTabs(WidgetRef ref) {
    final currentCategoryId = ref.read(currentTabCategoryIdProvider);
    ref.invalidate(topicListProvider(currentCategoryId));

    // 非当前 tab 标记 stale，不发请求
    final pinnedIds = ref.read(pinnedCategoriesProvider);
    final staleTabs = <int?>{};
    for (final categoryId in [null, ...pinnedIds]) {
      if (categoryId == currentCategoryId) continue;
      staleTabs.add(categoryId);
    }
    ref.read(staleTabsProvider.notifier).state = staleTabs;
  }

  /// 第一批：主页渲染必需的 provider
  /// 用户信息、分类列表（tab 栏依赖）
  static final List<void Function(WidgetRef ref)> _coreRefreshers = [
    (ref) => ref.invalidate(currentUserProvider),
    (ref) => ref.invalidate(categoriesProvider),
    (ref) => ref.invalidate(topicTrackingStateMetaProvider),
    (ref) => ref.invalidate(topicTrackingStateProvider),
  ];

  /// 第二批：非首屏必需，延迟执行以降低并发请求量
  static final List<void Function(WidgetRef ref)> _deferredRefreshers = [
    (ref) => ref.invalidate(userSummaryProvider),
    (ref) => ref.invalidate(notificationListProvider),
    (ref) => ref.invalidate(tagsProvider),
    (ref) => ref.invalidate(canTagTopicsProvider),
    (ref) {
      final activeSlugs = ref.read(activeCategorySlugsProvider);
      for (final slug in activeSlugs) {
        ref.invalidate(categoryTopicsProvider(slug));
      }
    },
    (ref) => ref.invalidate(browsingHistoryProvider),
    (ref) => ref.invalidate(bookmarksProvider),
    (ref) => ref.invalidate(myTopicsProvider),
    (ref) => ref.invalidate(notificationCountStateProvider),
    (ref) => ref.invalidate(notificationChannelProvider),
    (ref) => ref.invalidate(notificationAlertChannelProvider),
    (ref) => ref.invalidate(latestChannelProvider),
    (ref) => ref.invalidate(messageBusInitProvider),
    (ref) => ref.invalidate(ldcUserInfoProvider),
    (ref) => ref.invalidate(cdkUserInfoProvider),
  ];
}
