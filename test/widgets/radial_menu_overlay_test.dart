import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/radial_long_press_menu.dart';

void main() {
  const screen = Size(360, 780);
  // 选中胶囊半径 27 + 标签间距 8
  const labelClearance = 35.0;
  const labels = ['时间线', '回到顶部', '回复', '书签', '分享', 'AI 助手'];

  final items = [
    for (final label in labels)
      RadialMenuItem(icon: Icons.circle, label: label, onSelected: () {}),
  ];

  Future<void> pumpOverlay(
    WidgetTester tester, {
    required ValueNotifier<int?> highlighted,
    required ValueNotifier<bool> closing,
    required Offset center,
    required Rect pressArea,
    RadialMenuDirection direction = RadialMenuDirection.up,
    VoidCallback? onClosed,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final window = solveRadialFanWindow(
      itemCount: items.length,
      anchorX: center.dx,
      screenWidth: screen.width,
      anchorY: center.dy,
      screenHeight: screen.height,
      direction: direction,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: Listenable.merge([highlighted, closing]),
          builder: (context, _) => RadialMenuOverlay(
            center: center,
            pressArea: pressArea,
            items: items,
            highlightedIndex: highlighted.value,
            radius: window.radius,
            direction: direction,
            sweepStart: window.sweepStart,
            sweepEnd: window.sweepEnd,
            closing: closing.value,
            onClosed: onClosed ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect labelRect(WidgetTester tester, String label) => tester.getRect(
    find.ancestor(of: find.text(label), matching: find.byType(Material)).first,
  );

  Offset itemCenter(WidgetTester tester, int index) =>
      tester.getCenter(find.byKey(ValueKey('radial_menu_item_$index')));

  double distanceToRect(Offset point, Rect rect) {
    final nearest = Offset(
      point.dx.clamp(rect.left, rect.right),
      point.dy.clamp(rect.top, rect.bottom),
    );
    return (nearest - point).distance;
  }

  testWidgets('向上展开：标签贴在选中项外侧，且不压住选中项', (tester) async {
    final highlighted = ValueNotifier<int?>(null);
    final closing = ValueNotifier(false);
    const center = Offset(180, 700);
    await pumpOverlay(
      tester,
      highlighted: highlighted,
      closing: closing,
      center: center,
      pressArea: Rect.fromCenter(center: center, width: 120, height: 40),
    );
    expect(find.text(labels[0]), findsNothing);

    for (final index in [0, 2, 5]) {
      highlighted.value = index;
      // 弹簧到位后 ticker 必须停下，否则 pumpAndSettle 会超时
      await tester.pumpAndSettle();
      final rect = labelRect(tester, labels[index]);
      final item = itemCenter(tester, index);
      expect(
        distanceToRect(item, rect),
        greaterThanOrEqualTo(labelClearance - 0.5),
      );
      // 标签在选中项的外上方，并完整落在屏幕内
      expect(rect.center.dy, lessThan(item.dy));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(screen.width));
      expect(find.text(labels[index]), findsOneWidget);
    }
  });

  testWidgets('向下展开：标签放在按压区域上方', (tester) async {
    final highlighted = ValueNotifier<int?>(null);
    final closing = ValueNotifier(false);
    const pressArea = Rect.fromLTWH(16, 96, 40, 40);
    await pumpOverlay(
      tester,
      highlighted: highlighted,
      closing: closing,
      center: Offset(pressArea.center.dx, pressArea.bottom),
      pressArea: pressArea,
      direction: RadialMenuDirection.down,
    );
    highlighted.value = 3;
    await tester.pumpAndSettle();
    final rect = labelRect(tester, labels[3]);
    expect(rect.bottom, lessThanOrEqualTo(pressArea.top));
    expect(rect.left, greaterThanOrEqualTo(0));
  });

  testWidgets('收起：标签淡出并回调 onClosed', (tester) async {
    final highlighted = ValueNotifier<int?>(1);
    final closing = ValueNotifier(false);
    var closed = false;
    const center = Offset(180, 700);
    await pumpOverlay(
      tester,
      highlighted: highlighted,
      closing: closing,
      center: center,
      pressArea: Rect.fromCenter(center: center, width: 120, height: 40),
      onClosed: () => closed = true,
    );
    expect(find.text(labels[1]), findsOneWidget);

    highlighted.value = null;
    closing.value = true;
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(find.text(labels[1]), findsNothing);
  });
}
