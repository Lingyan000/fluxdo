import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/notification_providers.dart';
import 'package:fluxdo/providers/notification_list_provider.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';
import 'package:fluxdo/utils/notification_navigation.dart';

final _unreadNotification = DiscourseNotification(
  id: 1001,
  userId: 42,
  notificationType: NotificationType.privateMessage,
  read: false,
  highPriority: true,
  createdAt: DateTime.utc(2026, 5, 12, 1, 2, 3),
  data: NotificationData(
    topicTitle: '有一条新私信',
    username: 'tester',
  ),
);

void main() {
  test('本地标记单条通知已读时同步刷新列表与角标计数', () async {
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(_FakeCurrentUserNotifier.new),
        recentNotificationsProvider.overrideWith(
          _FakeRecentNotificationsNotifier.new,
        ),
        notificationListProvider.overrideWith(
          _FakeNotificationListNotifier.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);
    await container.read(recentNotificationsProvider.future);
    await container.read(notificationListProvider.future);

    expect(container.read(notificationCountStateProvider).allUnread, 1);
    expect(container.read(notificationCountStateProvider).highPriority, 1);
    expect(
      container.read(recentNotificationsProvider).requireValue.single.read,
      isFalse,
    );
    expect(
      container.read(notificationListProvider).requireValue.single.read,
      isFalse,
    );

    syncNotificationReadLocallyWithNotifiers(
      notification: _unreadNotification,
      countNotifier: container.read(notificationCountStateProvider.notifier),
      recentNotifier: container.read(recentNotificationsProvider.notifier),
      listNotifier: container.read(notificationListProvider.notifier),
    );

    expect(container.read(notificationCountStateProvider).allUnread, 0);
    expect(container.read(notificationCountStateProvider).unread, 0);
    expect(container.read(notificationCountStateProvider).highPriority, 0);
    expect(
      container.read(recentNotificationsProvider).requireValue.single.read,
      isTrue,
    );
    expect(
      container.read(notificationListProvider).requireValue.single.read,
      isTrue,
    );
  });
}

class _FakeCurrentUserNotifier extends CurrentUserNotifier {
  @override
  FutureOr<User?> build() {
    return User(
      id: 42,
      username: 'tester',
      trustLevel: 2,
      unreadNotifications: 1,
      unreadHighPriorityNotifications: 1,
      allUnreadNotificationsCount: 1,
      seenNotificationId: 1000,
      notificationChannelPosition: 1,
    );
  }
}

class _FakeRecentNotificationsNotifier
    extends RecentNotificationsNotifier {
  @override
  Future<List<DiscourseNotification>> build() async => [_unreadNotification];
}

class _FakeNotificationListNotifier
    extends NotificationListNotifier {
  @override
  Future<List<DiscourseNotification>> build() async => [_unreadNotification];
}
