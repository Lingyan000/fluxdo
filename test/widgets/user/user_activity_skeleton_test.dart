import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/widgets/common/skeleton.dart';
import 'package:fluxdo/widgets/common/smart_avatar.dart';
import 'package:fluxdo/widgets/user/activity_post_card.dart';
import 'package:fluxdo/widgets/user/activity_card_layout.dart';
import 'package:fluxdo/widgets/user/user_profile_skeleton.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final (width, scale) in [(390.0, 1.0), (320.0, 2.0), (1440.0, 1.0)]) {
    for (final type in UserActivitySkeletonType.values) {
      testWidgets('活动骨架与内容对齐 $width/$scale/$type', (tester) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: navigatorKey,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Column(
                    children: [
                      Expanded(
                        child: UserActionListSkeleton(itemCount: 2, type: type),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          children: [
                            ActivityPostCard(
                              position: (index: 0, count: 2),
                              title: '标题',
                              actionLabel: '动作',
                              actionActor:
                                  type == UserActivitySkeletonType.receivedLike
                                  ? TopicUser(
                                      id: 2,
                                      username: 'a',
                                      avatarTemplate: '',
                                    )
                                  : null,
                              bodyFirst: type == UserActivitySkeletonType.reply,
                              excerpt: type == UserActivitySkeletonType.reply
                                  ? '<p>正文<br>正文</p>'
                                  : null,
                              occurredAt: DateTime.now().toUtc(),
                              author: TopicUser(
                                id: 1,
                                username: 'Lin',
                                avatarTemplate: '',
                              ),
                              categoryId: 1,
                              categories: {
                                1: Category(
                                  id: 1,
                                  name: '分类',
                                  color: '0088cc',
                                  textColor: 'ffffff',
                                  slug: 'test',
                                ),
                              },
                              onTap: () {},
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final skeleton = find.byType(UserActionItemSkeleton).first;
        final actual = find.byType(ActivityPostCard);
        final skeletonFrame = find.ancestor(
          of: skeleton,
          matching: find.byType(ActivityCardFrame),
        );
        final skeletonRect = tester.getRect(skeletonFrame);
        final actualRect = tester.getRect(actual);
        expect(skeletonRect.left, actualRect.left);
        expect(skeletonRect.right, actualRect.right);
        final boxes = find.descendant(
          of: skeleton,
          matching: find.byType(SkeletonBox),
        );
        final avatar = find.descendant(
          of: skeleton,
          matching: find.byType(SkeletonCircle),
        );
        expect(
          ((tester.getCenter(avatar) - skeletonRect.topLeft) -
                  (tester.getCenter(find.byType(SmartAvatar)) -
                      actualRect.topLeft))
              .distance,
          lessThan(1),
        );
        for (final (placeholder, content) in [
          (
            find.descendant(
              of: skeleton,
              matching: find.byKey(
                const ValueKey('activity-skeleton-metadata'),
              ),
            ),
            find.text('动作'),
          ),
          (
            find.descendant(
              of: skeleton,
              matching: find.byKey(const ValueKey('activity-skeleton-title')),
            ),
            find.text('标题'),
          ),
        ]) {
          final offset = tester.getTopLeft(placeholder) - skeletonRect.topLeft;
          final contentOffset = tester.getTopLeft(content) - actualRect.topLeft;
          expect(offset.dx, contentOffset.dx);
          expect(offset.dy, closeTo(contentOffset.dy, 1));
          expect(
            tester.getSize(placeholder).height,
            closeTo(tester.getSize(content).height, 1),
          );
        }
        final skeletonShell = tester.widget<SegmentedCardItem>(
          find
              .ancestor(of: skeleton, matching: find.byType(SegmentedCardItem))
              .first,
        );
        final actualShell = tester.widget<SegmentedCardItem>(
          find.descendant(of: actual, matching: find.byType(SegmentedCardItem)),
        );
        expect(skeletonShell.color, actualShell.color);
        expect(skeletonShell.gap, actualShell.gap);
        expect(skeletonShell.index, actualShell.index);
        expect(skeletonShell.count, actualShell.count);
        final placeholders = tester.widgetList<SkeletonBox>(boxes);
        expect(
          placeholders.where((box) => box.width == 28).length,
          type == UserActivitySkeletonType.reaction ? 1 : 0,
        );
        expect(
          placeholders.where((box) => box.width == 200).length,
          type == UserActivitySkeletonType.boost ? 1 : 0,
        );
        expect(
          placeholders.where((box) => box.width == 44).length,
          type == UserActivitySkeletonType.topic ? 3 : 0,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('徽章骨架使用分组双行条目', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UserBadgeListSkeleton())),
    );
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.all(20),
    );
    expect(find.byType(UserActionItemSkeleton), findsNothing);
    expect(find.byType(SegmentedCardGroup), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(4));
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
      expect(
        tile.contentPadding,
        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      );
      expect(tile.subtitle, isNotNull);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
