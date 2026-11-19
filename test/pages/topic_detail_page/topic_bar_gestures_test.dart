import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bar_gestures.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_bar.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_detail_overlay.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_filter_controls.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_scrub_indicator.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late ValueNotifier<int> current;
  late List<int> commits;
  late List<ProgressGestureAction> actions;
  var replyTaps = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    current = ValueNotifier(10000);
    commits = [];
    actions = [];
    replyTaps = 0;
  });
  tearDown(() => current.dispose());

  int? preview(WidgetTester tester) => tester
      .widget<TopicBarGestures>(find.byType(TopicBarGestures))
      .scrubIndexNotifier
      .value;

  Future<Rect> showBar(
    WidgetTester tester, {
    Size viewport = const Size(390, 720),
    double? paneWidth,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = viewport;
    addTearDown(tester.view.reset);
    final bar = TopicBottomBar(
      streamIndexListenable: current,
      totalCount: 10000,
      replyEntryState: TopicReplyEntryState.reply,
      onReplyEntryTap: () => replyTaps++,
      onOpenTimeline: () {},
      bookmarked: false,
      onBookmark: () {},
      onGestureAction: actions.add,
      onScrubCommit: (index) {
        commits.add(index);
        current.value = index;
      },
      filter: const TopicFilterControls(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              bottomNavigationBar: paneWidth == null
                  ? bar
                  : Align(
                      alignment: Alignment.centerRight,
                      heightFactor: 1,
                      child: SizedBox(width: paneWidth, child: bar),
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.getRect(find.byType(TopicBarGestures));
  }

  testWidgets('渐变留在帖子分栏下方，退场时再次横拖可接着操作', (tester) async {
    final bar = await showBar(
      tester,
      viewport: const Size(960, 720),
      paneWidth: 420,
    );
    final indicator = find.byType(TopicScrubIndicator);
    expect(indicator, findsNothing);
    final finger = await tester.startGesture(bar.center);
    await finger.moveBy(const Offset(-80, 0));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: indicator,
      matching: find.byWidgetPredicate(
        (widget) => switch (widget) {
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter),
            ),
          ) =>
            true,
          _ => false,
        },
      ),
    );
    final bounds = tester.getRect(field);
    expect(bounds.left, closeTo(bar.left, 1));
    expect(bounds.right, closeTo(bar.right, 1));
    expect(bounds.top, greaterThan(bar.top / 2));
    expect(bounds.contains(bar.center), isTrue);
    final target = preview(tester)!;
    await finger.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(commits, [target]);
    expect(preview(tester), isNull);
    expect(
      tester.widget<TopicScrubIndicator>(indicator).visibility.value,
      inExclusiveRange(0, 1),
    );
    final next = await tester.startGesture(bar.center);
    await next.moveBy(const Offset(90, 0));
    await tester.pumpAndSettle();
    expect(indicator, findsOneWidget);
    expect(tester.widget<TopicScrubIndicator>(indicator).visibility.value, 1);
    tester.view.physicalSize = const Size(960, 320);
    await tester.pump();
    expect(field, findsNothing);
    await next.cancel();
    await tester.pumpAndSettle();
    expect(commits, [target]);
    expect(indicator, findsNothing);
  });

  testWidgets('开启减少动效时渐变直接显隐', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final bar = await showBar(tester);
    final finger = await tester.startGesture(bar.center);
    await finger.moveBy(const Offset(90, 0));
    await tester.pump();
    final indicator = find.byType(TopicScrubIndicator);
    expect(tester.widget<TopicScrubIndicator>(indicator).visibility.value, 1);
    await finger.up();
    await tester.pump();
    expect(indicator, findsNothing);
  });

  testWidgets('由末楼横拖到首楼，上移换档并回到第 2 楼，松手提交一次', (tester) async {
    final bar = await showBar(tester);
    final gesture = await tester.startGesture(
      Offset(bar.right - 24, bar.center.dy),
    );
    await gesture.moveTo(Offset(bar.left + 24, bar.center.dy));
    await tester.pump();
    expect(preview(tester), 1, reason: '底栏范围 $bar');
    await gesture.moveBy(const Offset(2, -38));
    await tester.pump();
    expect(find.text('附近'), findsOneWidget);
    await gesture.moveBy(const Offset(3, -38));
    await tester.pump();
    expect(find.text('逐楼'), findsOneWidget);
    expect(preview(tester), 1);
    await gesture.moveBy(const Offset(14, 0));
    await tester.pump();
    expect(preview(tester), 2);
    expect(commits, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(commits, [2]);
    expect(actions, isEmpty);
    expect(find.text('逐楼'), findsNothing);
  });

  testWidgets('从握柄上移可直接逐楼，系统取消会收起预览', (tester) async {
    final bar = await showBar(tester);
    final finger = await tester.startGesture(
      Offset(bar.right - 24, bar.top + 4),
    );
    await finger.moveBy(const Offset(-3, -76));
    await tester.pump();
    expect(find.text('逐楼'), findsOneWidget);
    await finger.moveBy(const Offset(-14, 0));
    await tester.pump();
    expect(preview(tester), 9999);
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
    expect(actions, isEmpty);
    expect(find.text('逐楼'), findsNothing);
  });

  testWidgets('筛选按钮按下仍可起拖，原地点按松手打开菜单', (tester) async {
    await showBar(tester);
    final button = find.byType(TopicFilterButton);
    final menuItem = find.text(tester.element(button).l10n.nested_title);
    final finger = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 160));
    expect(menuItem, findsNothing);
    await finger.up();
    await tester.pumpAndSettle();
    expect(menuItem, findsOneWidget);
    await tester.tap(menuItem);
    await tester.pumpAndSettle();
    expect(menuItem, findsNothing);
    expect(commits, isEmpty);
  });

  testWidgets('普通区域的上滑、按钮点按和屏幕侧边各走原入口', (tester) async {
    final bar = await showBar(tester);
    await tester.tap(find.byType(TopicReplyEntry));
    expect(replyTaps, 1);
    final swipe = await tester.startGesture(bar.center);
    await swipe.moveBy(const Offset(0, -30));
    await swipe.moveBy(const Offset(0, -70));
    await swipe.up();
    await tester.pumpAndSettle();
    expect(actions, [ProgressGestureAction.jumpToUnread]);
    final edge = await tester.startGesture(Offset(3, bar.center.dy));
    await edge.moveBy(const Offset(120, 0));
    await edge.up();
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
  });

  testWidgets('底栏首次可见才展示引导，拖动后打开其他话题也不再弹出', (tester) async {
    final visible = ValueNotifier(false);
    final back = ValueNotifier(false);
    addTearDown(visible.dispose);
    addTearDown(back.dispose);
    Future<void> showTopic(int id) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              home: Scaffold(
                body: TopicDetailOverlay(
                  key: ValueKey(id),
                  showBottomBarListenable: visible,
                  showBackToTopListenable: back,
                  streamIndexListenable: current,
                  totalCount: 10000,
                  hasMoreBefore: false,
                  replyEntryState: TopicReplyEntryState.reply,
                  onReplyEntryTap: () {},
                  onScrollToTop: () {},
                  onOpenTimeline: () {},
                  bookmarked: false,
                  onBookmark: () {},
                  onGestureAction: actions.add,
                  onScrubCommit: commits.add,
                  filter: const TopicFilterControls(),
                  replyEntryKey: GlobalKey(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final hint = find.descendant(
      of: find.byKey(const ValueKey('bar_gesture_hint')),
      matching: find.byType(AnimatedOpacity),
    );
    double opacity() => tester.widget<AnimatedOpacity>(hint).opacity;
    await showTopic(1);
    expect(opacity(), 0);
    visible.value = true;
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    final finger = await tester.startGesture(
      tester.getCenter(find.byType(TopicBarGestures)),
    );
    await finger.moveBy(const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(opacity(), 0);
    await finger.up();
    await showTopic(2);
    expect(opacity(), 0);
  });
}
