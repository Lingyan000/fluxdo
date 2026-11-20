import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart' show RenderCustomPaint;
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bar_gestures.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_bar.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_detail_overlay.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_filter_controls.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_floating_bar_edge.dart';
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
    ThemeData? barTheme,
    ValueNotifier<double>? readingPosition,
    int totalCount = 10000,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = viewport;
    addTearDown(tester.view.reset);
    final bar = TopicBottomBar(
      streamIndexListenable: current,
      readingPositionListenable: readingPosition,
      totalCount: totalCount,
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
    final content = barTheme == null ? bar : Theme(data: barTheme, child: bar);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              bottomNavigationBar: paneWidth == null
                  ? content
                  : Align(
                      alignment: Alignment.centerRight,
                      heightFactor: 1,
                      child: SizedBox(width: paneWidth, child: content),
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

  Future<void> expectReadingColors(
    WidgetTester tester,
    Finder trackFinder,
    double fraction,
  ) async {
    final context = tester.element(trackFinder);
    final track = tester.widget<TopicProgressTrack>(trackFinder);
    final render = tester.renderObject<RenderCustomPaint>(
      find.descendant(of: trackFinder, matching: find.byType(CustomPaint)),
    );
    final size = render.size;
    final scheme = Theme.of(context).colorScheme;
    final read = Color.alphaBlend(context.emphasis.selected, scheme.surface);
    final unread = Color.alphaBlend(
      scheme.outlineVariant.withValues(alpha: .55),
      scheme.surface,
    );
    await tester.runAsync(() async {
      const scale = 3.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(scale);
      canvas.drawColor(scheme.surface, BlendMode.src);
      render.painter!.paint(canvas, size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        (size.width * scale).ceil(),
        (size.height * scale).ceil(),
      );
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final step = 1 / size.width;
      final split =
          track.floatingEdge?.at(fraction).dx ?? size.width * fraction;
      // 在分界两侧各取一个逻辑像素，也检查以前读过、现在已回滑的那段。
      for (final f in [
        step / 4,
        .25,
        .5,
        .75,
        1 - step / 4,
        fraction - step,
        fraction + step,
      ]) {
        if (f <= 0 || f >= 1 || f == fraction) continue;
        final p =
            track.floatingEdge?.at(f) ??
            Offset(size.width * f, size.height / 2);
        final x = (p.dx * scale).floor();
        final offset = ((p.dy * scale).floor() * image.width + x) * 4;
        final pixel = Color.fromARGB(
          bytes.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2),
        );
        expect(
          pixel,
          isSameColorAs(
            (x + .5) / scale < split ? read : unread,
            threshold: .008,
          ),
          reason: '进度 $fraction，采样位置 $f',
        );
      }
      image.dispose();
      picture.dispose();
    });
  }

  testWidgets('阅读时同一楼内的细线与悬浮顶边按实际位置逐帧绘制', (tester) async {
    current.value = 2;
    final reading = ValueNotifier(1.0);
    addTearDown(reading.dispose);
    final trackFinder = find.byType(TopicProgressTrack);
    final paint = find.descendant(
      of: trackFinder,
      matching: find.byType(CustomPaint),
    );
    for (final width in [390.0, 960.0]) {
      await showBar(
        tester,
        viewport: Size(width, 720),
        readingPosition: reading,
        totalCount: 4,
      );
      final initialTrack = tester.widget<TopicProgressTrack>(trackFinder);
      final render = tester.renderObject<RenderCustomPaint>(paint);
      for (final amount in [0.0, .04, 1.25, 1.5, 1.75, 1.5, 3.96, 4.0]) {
        reading.value = amount;
        expect(render.debugNeedsPaint, isTrue);
        await tester.pump();
        final track = tester.widget<TopicProgressTrack>(trackFinder);
        expect(track, same(initialTrack), reason: '楼内滚动只需重绘');
        await expectReadingColors(tester, trackFinder, amount / 4);
        expect(current.value, 2);
      }
    }
  });

  testWidgets('窄屏阅读线贴边，展开时两端淡出，松手后恢复整条分割线', (tester) async {
    final bar = await showBar(tester);
    final track = find.byType(TopicProgressTrack);
    for (final floor in [1, 5001, 10000]) {
      current.value = floor;
      await tester.pump();
      final bed = paintedCapsules(tester).single;
      expect(bed.left, lessThanOrEqualTo(0));
      expect(bed.right, greaterThanOrEqualTo(bar.width));
      expect(tester.getTopLeft(track).dy + bed.top, closeTo(bar.top, .01));
      expect(bed.height, TopicBottomBarMetrics.progressLineHeight);
      await expectReadingColors(tester, track, (floor - 1) / 9999);
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

  testWidgets('悬浮渐变从底栏同色的弧形上沿展开，收回途中可以再拖', (tester) async {
    final bar = await showBar(
      tester,
      viewport: const Size(960, 720),
      paneWidth: 420,
      barTheme: ThemeData.dark(),
    );
    final indicator = find.byType(TopicScrubIndicator);
    final track = find.byType(TopicProgressTrack);
    final rest = tester.widget<TopicProgressTrack>(track);
    expect(rest.surface, TopicProgressSurface.floating);
    final edge = rest.floatingEdge!;
    expect(edge.size, bar.size);
    expect(
      edge.at(0).dx,
      inExclusiveRange(2.0, TopicBottomBarMetrics.floatingRadius),
    );
    expect(edge.at(1).dx, closeTo(bar.width - edge.at(0).dx, .2));
    expect(edge.at(0).dy, closeTo(edge.at(1).dy, .2));
    expect(edge.at(1).dy - edge.at(.5).dy, closeTo(2, .1));
    expect(edge.at(.1).dy, closeTo(edge.at(.5).dy, .1));
    expect(edge.at(.5).dx, closeTo(bar.width / 2, .15));
    expect(edge.at(.5).dy, closeTo(rest.surface.restThickness / 2, .1));
    final end =
        (paintTrack(tester).invocations
                    .lastWhere(
                      (call) => call.invocation.memberName == #drawPath,
                    )
                    .invocation
                    .positionalArguments
                    .first
                as Path)
            .computeMetrics()
            .first;
    expect(
      (end.getTangentForOffset(end.length)!.position - edge.at(1)).distance,
      lessThan(.15),
    );
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
    final readoutFade = find
        .descendant(of: indicator, matching: find.byType(FadeTransition))
        .first;
    expect(tester.widget<FadeTransition>(readoutFade).opacity.value, 0);
    expect(
      mid.startInset,
      greaterThanOrEqualTo(
        TopicBottomBarMetrics.floatingRadius + mid.surface.openThickness / 2,
      ),
    );
    expect(mid.endInset, mid.startInset);
    final midY = tester.getCenter(track).dy;
    expect(midY, lessThan(restY));
    await tester.pumpAndSettle();
    expect(tester.getCenter(track).dy, lessThan(midY));
    expect(tester.widget<FadeTransition>(readoutFade).opacity.value, 1);
    expect(tester.getRect(track).bottom, lessThanOrEqualTo(bar.top));
    final field = find.descendant(
      of: indicator,
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is TopicFloatingScrubBackdrop,
      ),
    );
    final bounds = tester.getRect(field);
    expect(bounds.left, closeTo(bar.left, .01));
    expect(bounds.right, closeTo(bar.right, .01));
    expect(bounds.top, greaterThan(bar.top / 2));
    final axisY = tester.getCenter(track).dy;
    expect(bounds.contains(Offset(bar.left + mid.startInset, axisY)), isTrue);
    expect(bounds.contains(Offset(bar.right - mid.endInset, axisY)), isTrue);
    expect(bounds.bottom, closeTo(bar.center.dy, .01));
    final backdrop =
        tester.widget<CustomPaint>(field).painter!
            as TopicFloatingScrubBackdrop;
    expect(backdrop.edge, same(edge));
    final material = tester.widget<Material>(
      find
          .ancestor(
            of: find.byType(TopicBarGestures),
            matching: find.byWidgetPredicate(
              (w) => w is Material && w.shape == edge.shape,
            ),
          )
          .first,
    );
    expect(backdrop.container, material.color);
    // 黑底、图片和回帖行都可能出现在栏后，直接校验渐变的实际像素。
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      backdrop.paint(Canvas(recorder), bounds.size);
      final picture = recorder.endRecording();
      final img = await picture.toImage(
        bounds.width.ceil(),
        bounds.height.ceil(),
      );
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      Color pixel(int x, int y) {
        final offset = (y * img.width + x) * 4;
        return Color.fromARGB(
          bytes.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2),
        );
      }

      final centerX = (bounds.width / 2).floor();
      final rootY = (bar.top - bounds.top).floor();
      final atRoot = pixel(centerX, rootY - 1);
      expect(atRoot.a, 1);
      expect((atRoot.r - backdrop.container.r).abs(), lessThan(.015));
      expect(pixel(centerX, 0).a, lessThan(.02));
      const shoulderX = 6;
      final outline = edge.shape.getOuterPath(Offset.zero & edge.size);
      final shoulderY = Iterable<int>.generate(bar.height.ceil())
          .firstWhere((y) => outline.contains(Offset(shoulderX + .5, y + .5)));
      expect(shoulderY, greaterThan(edge.at(0).dy));
      expect(pixel(shoulderX, rootY + shoulderY - 3).a, greaterThan(.02));
      expect(pixel(shoulderX, rootY + shoulderY + 3).a, 0);
      expect(pixel(centerX, rootY + 6).a, 0);
      img.dispose();
      picture.dispose();
    });
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

  testWidgets('从悬浮底栏左侧圆角可向上逐楼，方正主题沿顶边收头', (tester) async {
    current.value = 1;
    final bar = await showBar(
      tester,
      viewport: const Size(960, 720),
      paneWidth: 420,
    );
    final edge = tester
        .widget<TopicProgressTrack>(find.byType(TopicProgressTrack))
        .floatingEdge!;
    final finger = await tester.startGesture(
      bar.topLeft + edge.at(0) + const Offset(2, 0),
    );
    await finger.moveBy(const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('逐楼'), findsOneWidget);
    expect(preview(tester), 1);
    await finger.moveBy(const Offset(14, 0));
    await finger.up();
    await tester.pumpAndSettle();
    expect(commits, [2]);

    final square = TopicFloatingBarEdge(
      bar.size,
      RoundedSuperellipseBorder(
        borderRadius: const UiShapes(max: 0)
            .borderRadius(TopicBottomBarMetrics.floatingRadius),
      ),
    );
    for (final progress in [0.0, .1, .5, .9, 1.0]) {
      const inset = TopicFloatingBarEdge.inset;
      expect(square.at(progress).dy, inset);
      expect(
        square.at(progress).dx,
        closeTo(inset + (bar.width - 2 * inset) * progress, .01),
      );
    }
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

  testWidgets('远离当前阅读位置起拖仍基于当前楼层，沿顶边上移可直接逐楼', (tester) async {
    current.value = 5001;
    final bar = await showBar(tester);
    final track = find.byType(TopicProgressTrack);
    final idle = tester.widget<TopicProgressTrack>(track);
    final x = bar.left + 66;
    final drag = await tester.startGesture(Offset(x, bar.center.dy));
    await drag.moveBy(const Offset(24, 0));
    await tester.pumpAndSettle();
    final open = tester.widget<TopicProgressTrack>(track);
    final width = bar.width - open.startInset - open.endInset;
    final target = (5001 + 24 / width * 9999).round();
    expect(preview(tester), target);
    expect(open.progress, closeTo(idle.progress + 24 / width, .0001));
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
    final collapsed = find.descendant(
      of: find.byKey(const ValueKey('collapsed_progress_line')),
      matching: find.byType(TopicProgressTrack),
    );
    current.value = 5001;
    await tester.pump();
    expect(
      tester.getSize(collapsed).height,
      TopicBottomBarMetrics.progressLineHeight,
    );
    await expectReadingColors(tester, collapsed, 5000 / 9999);
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
