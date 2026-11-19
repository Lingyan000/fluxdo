import 'dart:async';

import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/topic_post_excerpt.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_position_info.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_bar.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_filter_controls.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_progress_track.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_reading_rail.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_timeline.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final timeline = find.byType(TopicTimelineTrack);
  final track = find.byType(TopicProgressTrack);
  late TopicPositionInfoSource info;
  late ValueNotifier<int> current;
  late TopicExcerptFetcher fetch;
  late List<int> jumps;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    jumps = [];
    current = ValueNotifier(51);
    final detail = TopicDetail.fromJson({
      'id': 1,
      'title': '时间线',
      'posts_count': 101,
      'last_read_post_id': 76,
      'post_stream': {
        'stream': [for (var i = 1; i <= 101; i++) i],
        'posts': [
          {
            'id': 51,
            'post_number': 51,
            'username': '读者',
            'created_at': '2026-10-07T09:30:00Z',
            'cooked': '<p>已经加载的楼层</p>',
          },
        ],
      },
    });
    fetch = (_, ids) async => [
      for (final id in ids)
        TopicPostExcerpt(postId: id, username: '读者', text: '楼层摘要 $id'),
    ];
    info = TopicPositionInfoSource(
      topicId: 1,
      detailGetter: () => detail,
      fetchExcerpts: (topic, ids) => fetch(topic, ids),
    );
  });
  tearDown(() {
    info.dispose();
    current.dispose();
  });

  void jump(int index) {
    jumps.add(index);
    current.value = index;
  }

  Future<void> show(WidgetTester tester, Widget body) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(body: body),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> showRail(WidgetTester tester) => show(
    tester,
    Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: TopicReadingRail.width,
        height: 430,
        child: TopicReadingRail(
          streamIndexListenable: current,
          totalCount: 101,
          infoSource: info,
          lastReadIndex: 76,
          onJumpToIndex: jump,
          replyEntryState: TopicReplyEntryState.reply,
          onReplyEntryTap: () {},
          filter: const TopicFilterControls(),
          quickActions: const [ProgressGestureAction.share],
          onAction: (_) {},
        ),
      ),
    ),
  );

  testWidgets('右栏摘要靠在竖轨左侧，日期和工具位置固定，松手或取消各自生效', (tester) async {
    await showRail(tester);
    final idle = tester.widget<TopicProgressTrack>(track);
    final travel = idle.thumbTravel;
    expect(idle.surface, TopicProgressSurface.sidebar);
    expect(idle.lastRead, .75);
    final rail = tester.getRect(track);
    final reply = find.byType(TopicReplyEntry);
    final filter = find.byType(TopicFilterButton);
    final replyAtRest = tester.getRect(reply);
    final filterAtRest = tester.getRect(filter);
    final share = find.byTooltip(
      tester.element(timeline).l10n.progressGesture_action_share,
    );
    final shareAtRest = tester.getRect(share);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 40));
    await mouse.moveTo(rail.center);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TopicProgressTrack>(track).expansion,
      inExclusiveRange(0, 1),
    );
    expect(find.byType(TopicTimelineSpeedLabel), findsNothing);
    expect(travel.value, 0);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    final finger = await tester.startGesture(rail.center);
    await finger.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(travel.value, greaterThan(0));
    await finger.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(travel.value, lessThan(0));
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.widget<TopicProgressTrack>(track).expansion,
      inExclusiveRange(0, 1),
    );
    await finger.moveTo(rail.bottomCenter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));
    await tester.pump();
    expect(tester.getRect(track), rail);
    expect(tester.widget<TopicTimelineTrack>(timeline).selectedIndex, 101);
    expect(travel.value, 0);
    await finger.moveBy(const Offset(72, 0));
    await tester.pump();
    expect(find.text('×1/4'), findsOneWidget);
    expect(travel.value, 0);
    await finger.moveBy(const Offset(72, -1));
    await tester.pump();
    expect(find.text('×1/16'), findsOneWidget);
    final text = find.textContaining('楼层摘要 101', findRichText: true);
    expect(tester.getRect(text).right, lessThan(rail.center.dx));
    final leftField = find.byWidgetPredicate(
      (w) =>
          w is TopicProgressGradient &&
          w.gradient.begin == Alignment.centerRight,
    );
    final field = tester.getRect(leftField);
    expect(field.right, closeTo(tester.getRect(timeline).left, .01));
    final railField = tester.widget<TopicProgressGradient>(
      find.descendant(
        of: timeline,
        matching: find.byWidgetPredicate(
          (w) =>
              w is TopicProgressGradient &&
              w.gradient.begin == Alignment.centerLeft,
        ),
      ),
    );
    expect(
      tester.widget<TopicProgressGradient>(leftField).gradient.colors.first,
      railField.gradient.colors.first,
    );
    expect(field.width, greaterThan(TopicReadingRail.width));
    expect(field.top, closeTo(rail.top, .01));
    expect(field.bottom, closeTo(rail.bottom, .01));
    expect(
      tester
          .getTopLeft(
            find.text(tester.element(timeline).l10n.topic_timelineLastRead),
          )
          .dx,
      greaterThan(rail.center.dx),
    );
    expect(tester.getRect(reply), replyAtRest, reason: '摘要出现时回复入口应固定');
    expect(tester.getRect(filter), filterAtRest);
    expect(tester.getRect(share), shareAtRest);
    expect(jumps, isEmpty);
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(jumps, isEmpty);
    expect(leftField, findsNothing);
    expect(tester.getRect(reply), replyAtRest);
    expect(tester.widget<TopicProgressTrack>(track).progress, .5);
    expect(tester.widget<TopicProgressTrack>(track).expansion, 0);
    final next = await tester.startGesture(rail.center);
    await next.moveBy(const Offset(0, -25));
    await next.moveTo(rail.topCenter);
    await next.up();
    await tester.pumpAndSettle();
    expect(jumps, [1]);
    await tester.tapAt(rail.bottomCenter - const Offset(0, 2));
    await tester.pumpAndSettle();
    expect(jumps, [1, 101]);
    expect(travel.value, 0);
  });

  testWidgets('竖轨远离握柄起拖按位移选楼，原地点按仍按位置跳转', (tester) async {
    await showRail(tester);
    final bounds = tester.getRect(track);
    final idle = tester.widget<TopicProgressTrack>(track);
    final extent = bounds.height - idle.startInset - idle.endInset;
    final down = Offset(
      bounds.center.dx,
      bounds.top + idle.startInset + extent * .15,
    );
    final finger = await tester.startGesture(down);
    await finger.moveBy(const Offset(0, 26));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TopicTimelineTrack>(timeline).selectedIndex,
      (51 + 26 / extent * 100).round(),
    );
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(jumps, isEmpty);
    await tester.tapAt(down);
    await tester.pumpAndSettle();
    expect(jumps, [16]);
  });

  testWidgets('快扫和点按不取摘要，滑过或松手后晚到的摘要不会串楼', (tester) async {
    final calls = <Completer<List<TopicPostExcerpt>>>[];
    fetch = (_, ids) {
      final request = Completer<List<TopicPostExcerpt>>();
      calls.add(request);
      return request.future;
    };
    await showRail(tester);
    final rail = tester.getRect(track);
    final reply = find.byType(TopicReplyEntry);
    final rest = tester.getRect(reply);
    final text = find.textContaining('延迟摘要', findRichText: true);
    await tester.tapAt(rail.topCenter + const Offset(0, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, isEmpty);
    final finger = await tester.startGesture(
      rail.topCenter + const Offset(0, 2),
    );
    for (final fraction in [.4, .7, 1.0, .5, 1.0]) {
      await finger.moveTo(
        Offset(rail.center.dx, rail.top + rail.height * fraction),
      );
      await tester.pump(const Duration(milliseconds: 45));
      expect(calls, isEmpty);
      expect(text, findsNothing);
      expect(tester.getRect(reply), rest);
    }
    await tester.pump(const Duration(milliseconds: 330));
    expect(calls, hasLength(1));
    await finger.moveTo(rail.topCenter);
    await tester.pump();
    calls.first.complete([
      TopicPostExcerpt(postId: 101, username: '旧楼', text: '延迟摘要 101'),
    ]);
    await tester.pump(const Duration(milliseconds: 360));
    expect(calls, hasLength(2));
    expect(text, findsNothing);
    await finger.up();
    await tester.pumpAndSettle();
    calls.last.complete([
      TopicPostExcerpt(postId: 1, username: '新楼', text: '延迟摘要 1'),
    ]);
    await tester.pumpAndSettle();
    expect(text, findsNothing);
    expect(tester.getRect(reply), rest);
  });

  testWidgets('弹框点选和拖动只改预览，确认才跳转，仍可精确输入楼层', (tester) async {
    await show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showTopicTimelineSheet(
            context: context,
            infoSource: info,
            currentIndex: current.value,
            onJumpToIndex: jump,
          ),
          child: const Text('打开时间线'),
        ),
      ),
    );
    await tester.tap(find.text('打开时间线'));
    await tester.pumpAndSettle();
    final idle = tester.widget<TopicProgressTrack>(track);
    expect(idle.surface, TopicProgressSurface.sheet);
    final rail = tester.getRect(track);
    await tester.tapAt(rail.bottomCenter - const Offset(0, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.widget<TopicProgressTrack>(track).progress,
      inExclusiveRange(.5, 1),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TopicProgressTrack>(track).progress, 1);
    final finger = await tester.startGesture(
      rail.bottomCenter - Offset(0, idle.endInset),
    );
    await finger.moveBy(const Offset(0, -24));
    await finger.moveTo(rail.topCenter);
    await tester.pumpAndSettle();
    expect(tester.widget<TopicProgressTrack>(track).progress, 0);
    expect(tester.widget<TopicProgressTrack>(track).expansion, 1);
    await finger.up();
    await tester.pumpAndSettle();
    expect(jumps, isEmpty);
    await tester.tap(find.text('1 / 101', findRichText: true));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '37');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.widget<TopicTimelineTrack>(timeline).selectedIndex, 37);
    final confirm = tester.element(timeline).l10n.topic_jump;
    await tester.tap(find.text(confirm));
    await tester.pumpAndSettle();
    expect(jumps, [37]);
    expect(timeline, findsNothing);
  });
}
