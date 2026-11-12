import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('横滑时图标让位、文字靠右展开，栏目位置固定且取消后恢复', (tester) async {
    final controller = TabController(length: 3, vsync: tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller, (_) {}));
    await tester.pumpAndSettle();
    final initialWidth = tester.getSize(find.byTooltip('概览')).width;
    double? labelWidth;
    Offset? labelPosition;
    var iconX = tester.getCenter(find.byIcon(Icons.bar_chart)).dx;
    final otherTabPosition = tester.getCenter(find.byTooltip('关于'));

    for (final progress in [0.25, 0.5, 0.75]) {
      controller.offset = progress;
      await tester.pump();
      expect(controller.index, 0);
      expect(find.text('动态'), findsOneWidget);
      expect(find.text('概览'), findsOneWidget);
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('概览'), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, progress);
      final textWidth = tester.getSize(find.text('概览')).width;
      labelWidth ??= textWidth;
      expect(textWidth, labelWidth);
      labelPosition ??= tester.getTopLeft(find.text('概览'));
      expect(tester.getTopLeft(find.text('概览')), labelPosition);
      final currentIconX = tester.getCenter(find.byIcon(Icons.bar_chart)).dx;
      expect(currentIconX, lessThan(iconX));
      iconX = currentIconX;
      expect(tester.getCenter(find.byTooltip('关于')), otherTabPosition);
      expect(
        find.ancestor(of: find.text('概览'), matching: find.byType(ShaderMask)),
        findsOneWidget,
      );
      final tab = find.ancestor(
        of: find.text('概览'),
        matching: find.byType(Tab),
      );
      expect(
        find.descendant(of: tab, matching: find.byType(ClipRect)),
        findsNothing,
      );
      expect(tester.getSize(find.byTooltip('概览')).width, initialWidth);
      expect(tester.takeException(), isNull);
    }

    controller.offset = 0;
    await tester.pumpAndSettle();
    expect(find.text('概览'), findsNothing);
    expect(tester.getSize(find.byTooltip('概览')).width, initialWidth);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('宽屏显示全部标签，切换时保持栏目位置', (tester) async {
    final controller = TabController(length: 3, vsync: tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller, (_) {}, showAllLabels: true));
    await tester.pumpAndSettle();
    expect(find.text('动态'), findsOneWidget);
    expect(find.text('概览'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    final position = tester.getCenter(find.byTooltip('关于'));
    await tester.tap(find.byTooltip('关于'));
    await tester.pumpAndSettle();
    expect(controller.index, 2);
    expect(
      (tester.getCenter(find.byTooltip('关于')) - position).distance,
      lessThan(0.01),
    );
    expect(find.text('动态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('先切换栏目，再点击选中栏目打开筛选且仅回调一次', (tester) async {
    final controller = TabController(length: 3, vsync: tester, initialIndex: 1);
    addTearDown(controller.dispose);
    final selected = <String>[];
    await tester.pumpWidget(_host(controller, selected.add));
    await tester.tap(find.byTooltip('动态'));
    await tester.pumpAndSettle();
    expect(controller.index, 0);
    expect(find.text('只看话题'), findsNothing);

    await tester.tap(find.byTooltip('动态'));
    await tester.pumpAndSettle();
    expect(find.text('只看话题'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.text('只看话题')));
    await tester.pumpAndSettle();
    expect(selected, ['topics']);
    expect(controller.index, 0);
    expect(find.text('只看话题'), findsNothing);

    await tester.tap(find.byTooltip('关于'));
    await tester.pumpAndSettle();
    expect(controller.index, 2);
    await tester.tap(find.byTooltip('关于'));
    await tester.pumpAndSettle();
    expect(selected, ['topics']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏大字可横向滚动，控制器替换后同步选中项', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = TabController(length: 3, vsync: tester);
    final second = TabController(length: 3, vsync: tester, initialIndex: 2);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(_host(first, (_) {}, scale: 2));
    await tester.pumpAndSettle();
    expect(find.text('动态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_host(second, (_) {}, scale: 2));
    await tester.pumpAndSettle();
    expect(find.text('关于'), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller, second);
    first.index = 1;
    await tester.pumpAndSettle();
    expect(find.text('关于'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _host(
  TabController controller,
  ValueChanged<String> onSelected, {
  double scale = 1,
  bool showAllLabels = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: MenuTabBar<String>(
        controller: controller,
        showAllLabels: showAllLabels,
        items: [
          MenuTabItem(
            label: '动态',
            icon: Icons.article_outlined,
            onSelected: onSelected,
            menuBuilder: (_) => const [
              PopupMenuItem(value: 'topics', child: Text('只看话题')),
            ],
          ),
          const MenuTabItem(label: '概览', icon: Icons.bar_chart),
          const MenuTabItem(label: '关于', icon: Icons.person_outline),
        ],
      ),
    ),
  ),
);
