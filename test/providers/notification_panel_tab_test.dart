import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';

void main() {
  const siteTypes = {
    'mentioned': 1,
    'replied': 2,
    'quoted': 3,
    'liked': 5,
    'private_message': 6,
    'granted_badge': 12,
    'bookmark_reminder': 24,
    'assigned': 34,
  };

  test('分类只请求站点存在的类型', () {
    expect(NotificationPanelTab.all.typeNames(siteTypes), isNull);
    expect(NotificationPanelTab.replies.typeNames(siteTypes), [
      'mentioned',
      'quoted',
      'replied',
    ]);
    expect(NotificationPanelTab.likes.typeNames(siteTypes), ['liked']);
  });

  test('「其他」由站点类型减去其余分类推导', () {
    expect(NotificationPanelTab.other.typeNames(siteTypes), [
      'granted_badge',
      'assigned',
    ]);
    expect(NotificationPanelTab.other.typeNames(const {}), isEmpty);
  });

  test('分类未读数按类型 id 汇总', () {
    final grouped = parseGroupedUnread({'1': 2, '2': 3, '12': 1, 'x': 9});
    expect(grouped, {1: 2, 2: 3, 12: 1});
    expect(NotificationPanelTab.all.unreadCount(siteTypes, grouped), isNull);
    expect(NotificationPanelTab.replies.unreadCount(siteTypes, grouped), 5);
    expect(NotificationPanelTab.likes.unreadCount(siteTypes, grouped), 0);
    expect(NotificationPanelTab.other.unreadCount(siteTypes, grouped), 1);
  });
}
