import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_sheet_controller.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  test('开启前跟手比例稳定，过阈值后的阻力与速度连续', () {
    for (final viewport in [600.0, 844.0]) {
      final geometry = RefreshRevealGeometry(
        viewportExtent: viewport,
        topInset: 52,
      );
      expect(geometry.offsetFor(270), greaterThan(geometry.secondaryExtent));
      expect(geometry.offsetFor(180), lessThan(geometry.revealStart));
      for (final distance in [0.0, 120.0, 220.0, 270.0, 440.0]) {
        expect(
          geometry.distanceFor(geometry.offsetFor(distance)),
          closeTo(distance, .001),
        );
      }
      final threshold = geometry.distanceFor(geometry.secondaryExtent);
      final before =
          geometry.offsetFor(threshold) - geometry.offsetFor(threshold - .1);
      final after =
          geometry.offsetFor(threshold + .1) - geometry.offsetFor(threshold);
      expect(before, closeTo(after, .0001));
      expect(
        geometry.velocityFactor(threshold),
        closeTo(geometry.velocityFactor(threshold + .1), .001),
      );
    }
  });

  testWidgets('按下暂停，取消继续；短距离反向接管不会被旧动画关闭', (tester) async {
    final sheet = MiniAppSheetController(tester)..extent = 756;
    addTearDown(sheet.dispose);
    final closed = sheet.open();
    var completed = false;
    closed.then((_) => completed = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    sheet.holdMotion();
    final held = sheet.offset;
    await tester.pump(const Duration(milliseconds: 100));
    expect(sheet.offset, held);
    sheet.cancelCloseDrag();
    await tester.pumpAndSettle();
    expect(sheet.offset, 756);
    sheet.beginCloseDrag();
    sheet.updateCloseDrag(-60);
    sheet.endCloseDrag(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    sheet.beginCloseDrag();
    final caught = sheet.offset;
    sheet.updateCloseDrag(48);
    expect(sheet.offset, caught + 48);
    sheet.endCloseDrag(0);
    await tester.pumpAndSettle();
    expect(sheet.offset, 756);
    expect(completed, isFalse);
    sheet.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    sheet.open();
    await tester.pumpAndSettle();
    expect(sheet.offset, 756);
    expect(completed, isFalse);
  });

  testWidgets(
    'release inherits velocity; a close can be interrupted and reversed',
    (tester) async {
      final slow = MiniAppSheetController(tester)..extent = 700;
      final fast = MiniAppSheetController(tester)..extent = 700;
      addTearDown(slow.dispose);
      addTearDown(fast.dispose);
      slow.reveal(const RefreshRevealNotification(1.3, true, false));
      fast.reveal(
        const RefreshRevealNotification(1.3, true, false, velocity: 1200),
      );
      expect(fast.offset, slow.offset);
      slow.open();
      final finished = fast.open();
      var closed = false;
      finished.then((_) => closed = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(fast.offset, greaterThan(slow.offset));
      await tester.pumpAndSettle();
      fast.beginCloseDrag();
      fast.updateCloseDrag(-250);
      fast.endCloseDrag(-600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final interrupted = fast.offset;
      fast.beginCloseDrag();
      expect(fast.offset, interrupted);
      fast.updateCloseDrag(150);
      fast.endCloseDrag(1500);
      await tester.pumpAndSettle();
      expect(fast.offset, 700);
      expect(closed, isFalse);
      fast.close();
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(fast.offset, 0);
    },
  );

  testWidgets('reduced motion settles immediately; classic motion completes', (
    tester,
  ) async {
    final sheet = MiniAppSheetController(tester)..extent = 600;
    addTearDown(sheet.dispose);
    sheet.reduceMotion = true;
    final closed = sheet.open();
    expect(sheet.offset, 600);
    sheet.close();
    await closed;
    expect(sheet.isOpen, isFalse);
    sheet.reduceMotion = false;
    sheet.expressive = false;
    sheet.open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sheet.offset, inExclusiveRange(0, 600));
    await tester.pumpAndSettle();
    expect(sheet.offset, 600);
  });
}
