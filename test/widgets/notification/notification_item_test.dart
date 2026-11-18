import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/widgets/common/emoji_text.dart';
import 'package:fluxdo/widgets/notification/notification_card.dart';
import 'package:fluxdo/widgets/notification/notification_item.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.zh);
  });

  DiscourseNotification buildNotification({
    required int id,
    required NotificationType type,
    required bool read,
    String username = 'sparkssssssss',
    String? topicTitle = '应用日志反馈',
    String? badgeName,
  }) {
    return DiscourseNotification(
      id: id,
      userId: 1,
      notificationType: type,
      read: read,
      highPriority: type == NotificationType.privateMessage,
      createdAt: DateTime.utc(2026, 11, 18, 2, 0),
      topicId: topicTitle == null ? null : 100,
      postNumber: 1,
      data: NotificationData(
        displayUsername: username,
        topicTitle: topicTitle,
        badgeName: badgeName,
      ),
    );
  }

  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(body: child),
        ),
      ),
    );
  }

  testWidgets('未读与已读条目拉开主次层级，并按需渲染缩进细分隔线', (tester) async {
    final unread = buildNotification(
      id: 1,
      type: NotificationType.privateMessage,
      read: false,
    );
    final read = buildNotification(
      id: 2,
      type: NotificationType.reaction,
      read: true,
      username: 'ciarany',
      topicTitle: 'FluxDO 客户端体验反馈',
    );

    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            NotificationItem(notification: unread, onTap: () {}),
            NotificationItem(
              notification: read,
              showTopDivider: true,
              onTap: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final inks = tester.widgetList<Ink>(find.byType(Ink)).toList();
    expect(inks.length, 2);
    final context = tester.element(find.byType(NotificationItem).first);
    expect(
      (inks[0].decoration as BoxDecoration?)?.color,
      context.emphasis.selected.withValues(alpha: 0.055),
    );
    expect((inks[1].decoration as BoxDecoration?)?.color, Colors.transparent);

    // 角标统一走当前主题单色体系：未读取主题选中色，已读退回中性次要色，不引入杂色
    expect(find.textContaining('回应了你的帖子'), findsOneWidget);
    final unreadBadgeIcon = tester.widget<Icon>(
      find.byIcon(Symbols.mail_rounded),
    );
    final readBadgeIcon = tester.widget<Icon>(
      find.byIcon(Symbols.add_reaction_rounded),
    );
    expect(unreadBadgeIcon.fill, isNull);
    expect(unreadBadgeIcon.color, context.emphasis.selected);
    expect(readBadgeIcon.fill, isNull);
    expect(readBadgeIcon.color, Theme.of(context).colorScheme.onSurfaceVariant);

    // 话题标题在未读时采用中粗强调，已读退回常规字重
    final emojiTexts = tester
        .widgetList<EmojiText>(find.byType(EmojiText))
        .toList();
    expect(emojiTexts[0].style?.fontWeight, FontWeight.w500);
    expect(emojiTexts[1].style?.fontWeight, FontWeight.w400);
  });

  testWidgets('通知列表页 NotificationCard 同步高亮未读状态', (tester) async {
    final unread = buildNotification(
      id: 10,
      type: NotificationType.replied,
      read: false,
    );
    final read = buildNotification(
      id: 11,
      type: NotificationType.replied,
      read: true,
    );

    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            NotificationCard(
              notification: unread,
              position: (index: 0, count: 2),
              onTap: () {},
            ),
            NotificationCard(
              notification: read,
              position: (index: 1, count: 2),
              onTap: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final items = tester
        .widgetList<SegmentedCardItem>(find.byType(SegmentedCardItem))
        .toList();
    expect(items[0].color, isNot(equals(items[1].color)));
  });
}
