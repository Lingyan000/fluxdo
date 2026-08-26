import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/auth_session.dart';
import 'core_providers.dart';
import 'bookmark_name_suggestions_provider.dart';
import 'bookmark_sync_controller.dart';
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
import 'chat/chat_channels_provider.dart';
import 'cdk_providers.dart';

class AppStateRefresher {
  AppStateRefresher._();

  static DateTime? _lastRefreshTime;
  static int _refreshEpoch = 0;

  /// 调用方用 [ProviderScope.containerOf] 取 container 后传入，
  /// 避免 [Future.delayed] 闭包持有的 [WidgetRef] 在延迟期间随 widget unmount 失效，
  /// 进而抛 StateError 中断后续 invalidate（曾导致登录后 ProfilePage 卡 loading）。
  static void refreshAll(ProviderContainer container, {bool force = false}) {
    // 去抖：2 秒内重复调用直接跳过（如 authStateProvider listener + _goToLogin 同时触发）。
    // 多账号切换等关键路径用 force=true 绕过去抖，确保切换后状态必然刷新。
    final now = DateTime.now();
    if (!force &&
        _lastRefreshTime != null &&
        now.difference(_lastRefreshTime!) < const Duration(seconds: 2)) {
      return;
    }
    _lastRefreshTime = now;
    final refreshEpoch = ++_refreshEpoch;

    // 第一批：主页渲染必需（用户信息 + 分类 + 话题列表）
    for (final refresh in _coreRefreshers) {
      refresh(container);
    }
    _refreshTopicTabs(container);
    // 第二批：延迟 1 秒执行，避免并发请求过多触发风控
    Future.delayed(const Duration(seconds: 1), () {
      // 切换账号后，上一轮延迟刷新不能再把旧账号请求重新唤醒。
      if (refreshEpoch != _refreshEpoch) return;
      for (final refresh in _deferredRefreshers) {
        refresh(container);
      }
    });
  }

  static Future<void> resetForLogout(ProviderContainer container) async {
    // 先使已有的延迟刷新失效，避免退出/重新登录窗口中的旧闭包重新
    // invalidate provider，把旧账号请求带入新会话。
    _refreshEpoch++;
    final generation = AuthSession().generation;
    await Future.wait([
      container.read(currentUserProvider.notifier).clearCache(),
      container.read(userSummaryProvider.notifier).clearCache(),
    ]);
    if (!AuthSession().isValid(generation)) return;
    container.read(bookmarkNameSuggestionsProvider.notifier).clearCache();
    container.read(bookmarkSyncControllerProvider.notifier).reset();
    container.invalidate(currentUsernameProvider);
    // 登出时 invalidate 所有（不会发请求，因为数据被清空了）
    for (final refresh in _coreRefreshers) {
      refresh(container);
    }
    for (final refresh in _deferredRefreshers) {
      refresh(container);
    }
    // 重置筛选/排序/标签（会通过 signal listener 触发话题列表刷新，
    // 无需再手动 invalidate 话题列表）
    container
        .read(topicFilterProvider.notifier)
        .setFilter(TopicListFilter.latest);
    container
        .read(topicSortOrderProvider.notifier)
        .setOrder(TopicSortOrder.defaultOrder);
    container.read(topicSortAscendingProvider.notifier).setAscending(false);
    final pinnedIds = container.read(pinnedCategoriesProvider);
    container.read(tabTagsProvider(null).notifier).state = [];
    for (final id in pinnedIds) {
      container.read(tabTagsProvider(id).notifier).state = [];
    }
    container.read(activeCategorySlugsProvider.notifier).reset();
    await container.read(ldcUserInfoProvider.notifier).disable();
    await container.read(cdkUserInfoProvider.notifier).disable();
  }

  /// 多账号切换后调用：清掉与「上一个账号」绑定的本地缓存并整体刷新。
  ///
  /// 与 [resetForLogout] 的差别：不重置筛选/排序、不禁用 LDC/CDK
  /// （新账号可能仍在用），只做身份缓存清理 + 全量 invalidate。
  static Future<void> resetForAccountSwitch(ProviderContainer container) async {
    // 清理尚未执行的上一账号延迟刷新；refreshAll 完成后会再建立新 epoch。
    _refreshEpoch++;
    final generation = AuthSession().generation;
    await Future.wait([
      container.read(currentUserProvider.notifier).clearCache(),
      container.read(userSummaryProvider.notifier).clearCache(),
    ]);
    if (!AuthSession().isValid(generation)) return;
    container.read(bookmarkNameSuggestionsProvider.notifier).clearCache();
    container.read(bookmarkSyncControllerProvider.notifier).reset();
    container.invalidate(currentUsernameProvider);
    refreshAll(container, force: true);
  }

  /// 刷新话题列表各 tab
  /// 只刷新当前 tab，非活跃 tab 标记 stale，切换到时才刷新
  static void _refreshTopicTabs(ProviderContainer container) {
    final currentCategoryId = container.read(currentTabCategoryIdProvider);
    container.invalidate(topicListProvider(currentCategoryId));

    // 非当前 tab 标记 stale，不发请求
    final pinnedIds = container.read(pinnedCategoriesProvider);
    final staleTabs = <int?>{};
    for (final categoryId in [null, ...pinnedIds]) {
      if (categoryId == currentCategoryId) continue;
      staleTabs.add(categoryId);
    }
    container.read(staleTabsProvider.notifier).state = staleTabs;
  }

  /// 第一批：主页渲染必需的 provider
  /// 用户信息、分类列表（tab 栏依赖）
  static final List<void Function(ProviderContainer container)>
  _coreRefreshers = [
    (c) => c.invalidate(currentUserProvider),
    (c) => c.invalidate(categoriesProvider),
    (c) => c.invalidate(topicTrackingStateMetaProvider),
    (c) => c.invalidate(topicTrackingStateProvider),
  ];

  /// 第二批：非首屏必需，延迟执行以降低并发请求量
  static final List<void Function(ProviderContainer container)>
  _deferredRefreshers = [
    (c) => c.invalidate(userSummaryProvider),
    (c) => c.invalidate(notificationListProvider),
    (c) => c.invalidate(tagsProvider),
    (c) => c.invalidate(canTagTopicsProvider),
    (c) {
      final activeSlugs = c.read(activeCategorySlugsProvider);
      for (final slug in activeSlugs) {
        c.invalidate(categoryTopicsProvider(slug));
      }
    },
    (c) => c.invalidate(browsingHistoryProvider),
    (c) => c.invalidate(bookmarksProvider),
    (c) => c.invalidate(myTopicsProvider),
    (c) => c.invalidate(notificationCountStateProvider),
    (c) => c.invalidate(notificationChannelProvider),
    (c) => c.invalidate(notificationAlertChannelProvider),
    (c) => c.invalidate(latestChannelProvider),
    (c) => c.invalidate(messageBusInitProvider),
    (c) => c.invalidate(ldcUserInfoProvider),
    (c) => c.invalidate(cdkUserInfoProvider),
    // 多账号切换相关：私信收件箱/已发送、聊天频道列表都是按账号返回的
    (c) => c.invalidate(pmInboxProvider),
    (c) => c.invalidate(pmSentProvider),
    (c) => c.invalidate(chatChannelsProvider),
  ];
}
