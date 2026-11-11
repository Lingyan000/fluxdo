import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
