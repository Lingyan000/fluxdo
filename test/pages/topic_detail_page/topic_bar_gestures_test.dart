import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bar_gestures.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_bar.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_detail_overlay.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_filter_controls.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_progress_track.dart';
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

  TestRecordingCanvas paintTrack(WidgetTester tester) {
    final paint = find.descendant(
      of: find.byType(TopicProgressTrack),
      matching: find.byType(CustomPaint),
    );
    final canvas = TestRecordingCanvas();
    tester
        .widget<CustomPaint>(paint)
        .painter!
        .paint(canvas, tester.getSize(paint));
    return canvas;
  }

  List<RRect> paintedCapsules(WidgetTester tester) => [
    for (final call in paintTrack(tester).invocations)
      if (call.invocation.memberName == #drawRRect)
        call.invocation.positionalArguments.first as RRect,
  ];

  List<double> dividerOpacities(WidgetTester tester) => [
    for (final call in paintTrack(tester).invocations)
      if (call.invocation.memberName == #drawRect)
        (call.invocation.positionalArguments.last as Paint).color.a,
  ];

  testWidgets('窄屏阅读线贴边，展开时两端淡出，松手后恢复整条分割线', (tester) async {
    final bar = await showBar(tester);
    final track = find.byType(TopicProgressTrack);
    for (final floor in [1, 5001, 10000]) {
      current.value = floor;
      await tester.pump();
      final shapes = paintedCapsules(tester);
      final bed = shapes.first, fill = shapes[1], grip = shapes.last;
      expect(bed.left, lessThanOrEqualTo(0));
      expect(bed.right, greaterThanOrEqualTo(bar.width));
      expect(tester.getTopLeft(track).dy + bed.top, closeTo(bar.top, .01));
      expect(fill.left, bed.left);
      expect(
        fill.right,
        closeTo((floor - 1) / 9999 * bar.width + bed.height / 2, .01),
      );
      expect(grip.width, TopicProgressSurface.docked.gripLength);
      if (floor == 1) expect(grip.left, 0);
      if (floor == 10000) expect(grip.right, bar.width);
    }
    final finger = await tester.startGesture(bar.center);
    await finger.moveBy(const Offset(35, 0));
    await tester.pump();
    expect(paintedCapsules(tester).first.left, lessThanOrEqualTo(0));
    await tester.pump(TopicProgressTrack.openDuration ~/ 2);
    final midLeft = paintedCapsules(tester)[1].left;
    final fading = dividerOpacities(tester);
    expect(fading, isNotEmpty);
    expect(fading, everyElement(inExclusiveRange(0.0, 1.0)));
    await tester.pump(TopicProgressTrack.openDuration);
    final open = paintedCapsules(tester);
    expect(midLeft, inExclusiveRange(0.0, open[1].left));
    expect(
      open.every((shape) => shape.left > 0 && shape.right < bar.width),
      isTrue,
    );
    expect(dividerOpacities(tester), isEmpty);
    expect(find.byType(TopicProgressLine), findsNothing);
    await finger.up();
    await tester.pump();
    await tester.pump(TopicProgressTrack.closeDuration ~/ 2);
    final returning = dividerOpacities(tester);
    expect(returning, isNotEmpty);
    expect(returning, everyElement(inExclusiveRange(0.0, 1.0)));
    await tester.pumpAndSettle();
    expect(find.byType(TopicProgressLine), findsOneWidget);
    expect(paintedCapsules(tester).first.left, lessThanOrEqualTo(0));
    expect(
      paintedCapsules(tester).first.right,
      greaterThanOrEqualTo(bar.width),
    );
  });

  testWidgets('窄屏拖动预览在深色图片上方渐入，摘要区有足够底色', (tester) async {
    final bar = await showBar(tester);
    final finger = await tester.startGesture(bar.center);
    await finger.moveBy(const Offset(-36, 0));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(TopicScrubIndicator),
      matching: find.byType(TopicProgressGradient),
    );
    final height = tester.getSize(field).height;
    final gradient = tester.widget<TopicProgressGradient>(field).gradient;
    final stops = gradient.stops!;
    final colors = gradient.colors;
    final readout = colors.indexWhere((c) => c.a >= .97);
    expect(colors.first.a, 0);
    expect(readout, greaterThan(0));
    expect(stops[readout] * height, greaterThan(175));
    for (var i = 1; i <= readout; i++) {
      final span = (stops[i] - stops[i - 1]) * height;
      final slope = (colors[i].a - colors[i - 1].a) / span;
      expect(slope, inInclusiveRange(0.0, .009));
    }
    await finger.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('横向握柄随拖动方向留尾，慢移、换档和停手时恢复圆形', (tester) async {
    current.value = 5001;
    final bar = await showBar(tester);
    final track = find.byType(TopicProgressTrack);
    final finger = await tester.startGesture(bar.center);
    await finger.moveBy(const Offset(30, 0));
    await tester.pumpAndSettle();
    final size = paintedCapsules(tester).last;
    Future<RRect> move(Offset offset) async {
      await finger.moveBy(offset);
      await tester.pump();
      return paintedCapsules(tester).last;
    }

    double centerX() {
      final widget = tester.widget<TopicProgressTrack>(track);
      return widget.startInset +
          widget.progress * (bar.width - widget.startInset - widget.endInset);
    }

    final right = await move(const Offset(45, 0));
    expect(right.width, greaterThan(size.width));
    expect(right.height, size.height);
    expect(centerX() - right.left, greaterThan(right.right - centerX()));
    final left = await move(const Offset(-70, 0));
    expect(left.height, size.height);
    expect(centerX() - left.left, lessThan(left.right - centerX()));
    await tester.pumpAndSettle();
    expect(paintedCapsules(tester).last.width, closeTo(size.width, .01));
    final level = preview(tester);
    final lifted = await move(const Offset(0, -80));
    expect(preview(tester), level);
    expect(lifted.width, closeTo(size.width, .01));
    final slow = await move(const Offset(1, 0));
    expect(slow.width - size.width, inInclusiveRange(0.0, .5));
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
  });

  testWidgets('悬浮渐变沿轨道从两端展开，读数与轨道相连，收回途中可以再拖', (tester) async {
    final bar = await showBar(
      tester,
      viewport: const Size(960, 720),
      paneWidth: 420,
    );
    final indicator = find.byType(TopicScrubIndicator);
    final track = find.byType(TopicProgressTrack);
    final rest = tester.widget<TopicProgressTrack>(track);
    expect(rest.surface, TopicProgressSurface.floating);
    expect(
      rest.startInset,
      greaterThanOrEqualTo(
        TopicBottomBarMetrics.floatingRadius + rest.surface.openThickness / 2,
      ),
    );
    expect(rest.endInset, rest.startInset);
    final restY = tester.getCenter(track).dy;
    expect(indicator, findsNothing);
    final finger = await tester.startGesture(bar.center);
    await finger.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(track, findsOneWidget);
    expect(tester.getCenter(track).dy, closeTo(restY, .01));
    await tester.pump(const Duration(milliseconds: 85));
    final mid = tester.widget<TopicProgressTrack>(track);
    expect(mid.expansion, inExclusiveRange(0, 1));
    expect(mid.startInset, rest.startInset);
    final midY = tester.getCenter(track).dy;
    expect(midY, lessThan(restY));
    await tester.pumpAndSettle();
    expect(tester.getCenter(track).dy, lessThan(midY));
    expect(tester.getRect(track).bottom, lessThanOrEqualTo(bar.top));
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
    expect(bounds.left, closeTo(bar.left, .01));
    expect(bounds.right, closeTo(bar.right, .01));
    expect(bounds.top, greaterThan(bar.top / 2));
    final axisY = tester.getCenter(track).dy;
    expect(bounds.contains(Offset(bar.left + rest.startInset, axisY)), isTrue);
    expect(bounds.contains(Offset(bar.right - rest.endInset, axisY)), isTrue);
    expect(bounds.bottom, closeTo(restY, .01));
    expect(bounds.bottom, lessThan(bar.center.dy));
    final target = preview(tester)!;
    await finger.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(commits, [target]);
    expect(preview(tester), isNull);
    expect(track, findsOneWidget);
    expect(
      tester.widget<TopicProgressTrack>(track).expansion,
      inExclusiveRange(0, 1),
    );
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
    expect(dividerOpacities(tester), isEmpty);
    await finger.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(
      tester
          .widget<TopicProgressTrack>(find.byType(TopicProgressTrack))
          .thumbTravel
          .value,
      0,
    );
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

  testWidgets('远离握柄起拖仍基于当前楼层，沿顶边上移可直接逐楼', (tester) async {
    current.value = 5001;
    final bar = await showBar(tester);
    final track = find.byType(TopicProgressTrack);
    final idle = tester.widget<TopicProgressTrack>(track);
    final width = bar.width - idle.startInset - idle.endInset;
    final x = bar.left + 66;
    final drag = await tester.startGesture(Offset(x, bar.center.dy));
    await drag.moveBy(const Offset(24, 0));
    await tester.pumpAndSettle();
    final target = (5001 + 24 / width * 9999).round();
    expect(preview(tester), target);
    expect(
      tester.widget<TopicProgressTrack>(track).progress,
      closeTo(idle.progress + 24 / width, .0001),
    );
    await drag.cancel();
    await tester.pumpAndSettle();
    final fine = await tester.startGesture(Offset(x, bar.top + 3));
    await fine.moveBy(const Offset(0, -76));
    await tester.pump();
    expect(find.text('逐楼'), findsOneWidget);
    expect(preview(tester), 5001);
    await fine.moveBy(const Offset(14, 0));
    await fine.up();
    await tester.pumpAndSettle();
    expect(commits, [5002]);
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
