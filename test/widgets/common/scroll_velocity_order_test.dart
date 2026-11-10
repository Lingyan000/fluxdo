import 'package:common_ui/common_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrackerBehavior extends MaterialScrollBehavior {
  const _TrackerBehavior(this.tracker);
  final VelocityTracker tracker;

  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) =>
      (_) => tracker;
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('$platform 忽略倒序速度采样且保留原有速度模型', (tester) async {
      VelocityTracker create() => platform == TargetPlatform.iOS
          ? IOSScrollViewFlingVelocityTracker(PointerDeviceKind.touch)
          : MacOSScrollViewFlingVelocityTracker(PointerDeviceKind.touch);
      final delegate = create();
      final expected = create();
      late VelocityTracker tracker;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            tracker = DesktopScrollInteractionBehavior(
              delegate: _TrackerBehavior(delegate),
            ).velocityTrackerBuilder(context)(const PointerDownEvent());
            return const SizedBox();
          },
        ),
      );
      for (final (ms, y) in [
        (100, 0.0),
        (116, 20.0),
        (132, 42.0),
        (148, 66.0),
      ]) {
        final time = Duration(milliseconds: ms);
        final point = Offset(0, y);
        tracker.addPosition(time, point);
        expected.addPosition(time, point);
        if (ms == 132) {
          // Replay the log's 95 ms timestamp regression.
          tracker.addPosition(
            const Duration(milliseconds: 37),
            const Offset(0, 80),
          );
        }
      }
      final estimate = tracker.getVelocityEstimate()!;
      final expectedEstimate = expected.getVelocityEstimate()!;
      expect(estimate.pixelsPerSecond, expectedEstimate.pixelsPerSecond);
      expect(estimate.duration, expectedEstimate.duration);
      expect(estimate.offset, expectedEstimate.offset);
      expect(tracker.getVelocity(), expected.getVelocity());
    });
  }

  testWidgets('非 Apple 自定义速度追踪器保持原实例', (tester) async {
    final delegate = VelocityTracker.withKind(PointerDeviceKind.mouse);
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          expect(
            DesktopScrollInteractionBehavior(
              delegate: _TrackerBehavior(delegate),
            ).velocityTrackerBuilder(context)(const PointerDownEvent()),
            same(delegate),
          );
          return const SizedBox();
        },
      ),
    );
  });

  testWidgets('倒序采样仍传递拖动事件，后续滚动可继续', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final moves = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        scrollBehavior: const DesktopScrollInteractionBehavior(),
        home: Listener(
          onPointerMove: (event) => moves.add(event.timeStamp),
          child: ListView(
            controller: scroll,
            children: const [SizedBox(height: 4000)],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(300, 400));
    for (final (ms, y) in [
      (116, 350.0),
      (132, 300.0),
      (37, 280.0),
      (148, 230.0),
    ]) {
      await gesture.moveTo(
        Offset(300, y),
        timeStamp: Duration(milliseconds: ms),
      );
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 164));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(moves, [116, 132, 37, 148].map((ms) => Duration(milliseconds: ms)));
    expect(scroll.offset, greaterThan(0));
  });
}
