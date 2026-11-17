import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notification.dart';
import '../utils/paged_async_notifier.dart';
import '../utils/pagination_helper.dart';
import 'core_providers.dart';
import 'message_bus_providers.dart';

/// 通知列表的已读状态筛选，[query] 为服务端 `filter` 参数
enum NotificationReadFilter {
  all(null),
  unread('unread'),
  read('read');

  const NotificationReadFilter(this.query);
  final String? query;
}

/// 通知列表 Notifier (支持分页和刷新，用于历史通知页面)
/// autoDispose：离开页面后自动清除，下次进入重新加载
class NotificationListNotifier
    extends AsyncNotifier<List<DiscourseNotification>>
    with PagedAsyncNotifierMixin<DiscourseNotification> {
  NotificationListNotifier(this.filter);

  final NotificationReadFilter filter;
  int _totalRows = 0;

  /// 分页助手
  static final _paginationHelper =
      PaginationHelpers.forNotifications<DiscourseNotification>(
        keyExtractor: (n) => n.id,
      );

  Future<PagedPage<DiscourseNotification>> _loadFirstPage() async {
    final service = ref.read(discourseServiceProvider);
    final response = await service.getNotifications(filter: filter.query);
    _totalRows = response.totalRowsNotifications;
    return PagedPage(
      items: response.notifications,
      hasMore: response.notifications.length < _totalRows,
    );
  }

  @override
  Future<List<DiscourseNotification>> build() async {
    resetPagingState();
    return completePagedRefresh(await _loadFirstPage());
  }

  /// 刷新列表
  Future<void> refresh() async {
    await runPagedRefresh(_loadFirstPage);
  }

  /// 加载更多
  Future<void> loadMore() async {
    await runPagedLoadMore((currentList, _) async {
      final offset = currentList.length;

      final service = ref.read(discourseServiceProvider);
      final response = await service.getNotifications(
        offset: offset,
        filter: filter.query,
      );

      final currentState = PaginationState(items: currentList);
      final paginationResult = _paginationHelper.processLoadMore(
        currentState,
        PaginationResult(items: response.notifications, totalRows: _totalRows),
      );

      return PagedPage(
        items: paginationResult.items,
        hasMore: response.notifications.isNotEmpty && paginationResult.hasMore,
      );
    });
  }

  /// 手动重试加载更多
  Future<void> retryLoadMore() {
    return retryPagedLoadMore(loadMore);
  }

  /// 标记所有为已读
  Future<void> markAllAsRead() async {
    final service = ref.read(discourseServiceProvider);
    await service.markAllNotificationsRead();

    // 重置通知计数
    ref.read(notificationCountStateProvider.notifier).markAllRead();

    // 更新本地状态
    state.whenData((list) {
      state = AsyncValue.data(list.map((n) => n.copyWith(read: true)).toList());
    });
  }

  /// 标记单个通知为已读。「未读」筛选下也只改样式不移除，避免列表跳动。
  void markAsRead(int notificationId) {
    state.whenData((list) {
      state = AsyncValue.data(
        list.map((n) {
          if (n.id == notificationId && !n.read) {
            return n.copyWith(read: true);
          }
          return n;
        }).toList(),
      );
    });
  }
}

final notificationListProvider = AsyncNotifierProvider.family
    .autoDispose<
      NotificationListNotifier,
      List<DiscourseNotification>,
      NotificationReadFilter
    >(NotificationListNotifier.new);
