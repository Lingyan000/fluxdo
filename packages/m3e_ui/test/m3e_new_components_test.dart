import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('M3eButtonGroup 选择/按压联动不抛错', (tester) async {
    String selected = 'a';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => M3eButtonGroup<String>(
              items: const [
                M3eButtonGroupItem(value: 'a', label: Text('A')),
                M3eButtonGroupItem(value: 'b', label: Text('B')),
                M3eButtonGroupItem(value: 'c', label: Text('C')),
              ],
              selected: selected,
              onSelected: (v) => setState(() => selected = v),
            ),
          ),
        ),
      ),
    );
    // 按下 B:按住期间展宽动画运行。
    final gesture = await tester.startGesture(tester.getCenter(find.text('B')));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 'b');
    expect(tester.takeException(), isNull);
  });

  testWidgets('M3eButtonGroup 关闭态回退 SegmentedButton', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [M3eFlags(enabled: false)]),
        home: Scaffold(
          body: M3eButtonGroup<int>(
            items: const [
              M3eButtonGroupItem(value: 1, label: Text('1')),
              M3eButtonGroupItem(value: 2, label: Text('2')),
            ],
            selected: 1,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
  });

  testWidgets('M3eCircularProgress 进度推进与振幅开合不抛错', (tester) async {
    for (final v in [0.0, 0.05, 0.5, 0.96, 1.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: M3eCircularProgress(value: v))),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('M3eCircularProgress 关闭态回退 CPI', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [M3eFlags(enabled: false)]),
        home: const Scaffold(body: M3eCircularProgress(value: 0.5)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('M3eFabMenu 展开/收起/点击项', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          floatingActionButton: M3eFabMenu(
            icon: const Icon(Icons.add),
            items: [
              M3eFabMenuItem(
                icon: const Icon(Icons.edit),
                label: const Text('编辑'),
                onPressed: () => pressed++,
              ),
              M3eFabMenuItem(
                icon: const Icon(Icons.share),
                label: const Text('分享'),
                onPressed: () => pressed++,
              ),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.tap(find.byType(InkWell).last);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(pressed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('M3eFabMenu 关闭态回退普通 FAB', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [M3eFlags(enabled: false)]),
        home: Scaffold(
          floatingActionButton: M3eFabMenu(
            icon: const Icon(Icons.add),
            items: [
              M3eFabMenuItem(
                icon: const Icon(Icons.edit),
                label: const Text('编辑'),
                onPressed: () {},
              ),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
