import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/notification_providers.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';
import 'package:fluxdo/providers/notification_list_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

/// 通知计数 provider:冷启动渐进 emit(缓存用户无计数 → 接口终态带
/// 计数)下徽章不得被首个 emit 钉死;实时更新后服务端旧值不得回刷。
class _FakeCurrentUser extends CurrentUserNotifier {
  _FakeCurrentUser(this._initial);
  final User? _initial;

  @override
  Future<User?> build() async => _initial;

  void emit(User? user) => state = AsyncValue.data(user);
}

User _user({required int id, int allUnread = 0}) => User(
  id: id,
  username: 'u$id',
  trustLevel: 1,
  allUnreadNotificationsCount: allUnread,
  unreadNotifications: allUnread,
);

class _NotificationsService extends Fake implements DiscourseService {
  final firstCategory = Completer<NotificationListResponse>();
  final firstRecent = Completer<NotificationListResponse>();
  final categoryRequested = Completer<void>();
  final nextHistoryPage = Completer<NotificationListResponse>();
  bool markedAll = false;
  final recentSilent = <bool>[];

  NotificationListResponse response({required bool read}) =>
      NotificationListResponse.fromJson({
        'notifications': [
          {'id': 1, 'user_id': 1, 'notification_type': 2, 'read': read},
          if (read)
            {'id': 2, 'user_id': 1, 'notification_type': 2, 'read': false},
        ],
      });

  @override
  Future<NotificationListResponse> getRecentNotifications({
    List<String>? types,
    bool silent = false,
  }) async {
    if (types == null) {
      recentSilent.add(silent);
      if (recentSilent.length == 1) return firstRecent.future;
    } else if (!categoryRequested.isCompleted) {
      categoryRequested.complete();
      return firstCategory.future;
    }
    return response(read: true);
  }

  @override
  Future<void> markAllNotificationsRead() async => markedAll = true;

  @override
  Future<NotificationListResponse> getNotifications({
    int? offset,
    String? filter,
  }) async {
    if (offset != null) return nextHistoryPage.future;
    final page = response(read: markedAll);
    return NotificationListResponse(
      notifications: page.notifications,
      totalRowsNotifications: 2,
      seenNotificationId: 1,
    );
  }

  @override
  Future<void> markNotificationsReadByTypes(List<String> types) async {}
}

void main() {
  test('看过面板后仍按全部分类统计未读，缺少分类数据时回退', () async {
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(
          () => _FakeCurrentUser(_user(id: 1, allUnread: 4)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(currentUserProvider.future);
    expect(container.read(notificationCountStateProvider).totalUnread, 4);
    final counts = container.read(notificationCountStateProvider.notifier);
    counts.update(allUnread: 0, grouped: {2: 50, 5: 3});
    expect(container.read(notificationCountStateProvider).totalUnread, 53);
    counts.markAllRead();
    expect(container.read(notificationCountStateProvider).totalUnread, 0);
  });

  test('历史页全部已读后，晚到的分页响应不会覆盖新通知', () async {
    final service = _NotificationsService();
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(() => _FakeCurrentUser(_user(id: 1))),
        discourseServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    final history = notificationListProvider(NotificationReadFilter.all);
    container.listen(history, (_, _) {});
    await container.read(currentUserProvider.future);
    await container.read(history.future);
    final pending = container.read(history.notifier).loadMore();
    await container
        .read(notificationCountStateProvider.notifier)
        .markAllNotificationsRead();
    await container.read(history.future);
    service.nextHistoryPage.complete(service.response(read: false));
    await pending;
    expect(
      [for (final n in container.read(history).requireValue) (n.id, n.read)],
      [(1, true), (2, false)],
    );
    expect(service.recentSilent, isEmpty);
  });

  for (final global in [true, false]) {
    test('${global ? "全部" : "分类"}标已读时丢弃晚到的旧响应，保留随后新增的未读', () async {
      final service = _NotificationsService();
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWith(
            () => _FakeCurrentUser(_user(id: 1)),
          ),
          discourseServiceProvider.overrideWithValue(service),
          siteNotificationTypesProvider.overrideWith(
            (ref) async => {'replied': 2},
          ),
        ],
      );
      addTearDown(container.dispose);
      final replies = categorizedNotificationsProvider(
        NotificationPanelTab.replies,
      );
      container.listen(replies, (_, _) {});
      container.listen(recentNotificationsProvider, (_, _) {});
      await service.categoryRequested.future;
      await container.read(currentUserProvider.future);
      if (global) {
        await container
            .read(notificationCountStateProvider.notifier)
            .markAllNotificationsRead();
      } else {
        await container.read(replies.notifier).markAllAsRead();
      }
      await container.pump();
      final category = await container.read(replies.future);
      final recent = await container.read(recentNotificationsProvider.future);
      service.firstCategory.complete(service.response(read: false));
      service.firstRecent.complete(service.response(read: false));
      await container.pump();
      for (final list in [
        category,
        recent,
        container.read(replies).requireValue,
        container.read(recentNotificationsProvider).requireValue,
      ]) {
        expect(
          [for (final item in list) (item.id, item.read)],
          [(1, true), (2, false)],
        );
      }
      expect(service.recentSilent, [false, true]);
    }, timeout: const Timeout(Duration(seconds: 10)));
  }

  test('冷启动渐进 emit:缓存用户(计数0)后到达的真实计数生效', () async {
    final fake = _FakeCurrentUser(_user(id: 1, allUnread: 0));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith(() => fake)],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);
    expect(container.read(notificationCountStateProvider).allUnread, 0);

    // 同一 id,接口终态带真实计数(渐进 emit 第二拍)
    fake.emit(_user(id: 1, allUnread: 7));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 7);
  });

  test('实时更新后,服务端过期值不再回刷徽章', () async {
    final fake = _FakeCurrentUser(_user(id: 1, allUnread: 3));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith(() => fake)],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);
    expect(container.read(notificationCountStateProvider).allUnread, 3);

    // MessageBus 实时推送 5
    container
        .read(notificationCountStateProvider.notifier)
        .update(allUnread: 5);
    expect(container.read(notificationCountStateProvider).allUnread, 5);

    // refreshSilently 带过期值 3 → 不得覆盖实时值
    fake.emit(_user(id: 1, allUnread: 3));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 5);
  });

  test('markAllRead 后服务端旧值不复活徽章;换账号重置', () async {
    final fake = _FakeCurrentUser(_user(id: 1, allUnread: 9));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith(() => fake)],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);
    container.read(notificationCountStateProvider.notifier).markAllRead();
    expect(container.read(notificationCountStateProvider).allUnread, 0);

    fake.emit(_user(id: 1, allUnread: 9));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 0);

    // 切换账号:新账号服务端计数生效
    fake.emit(_user(id: 2, allUnread: 4));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 4);
  });
}
