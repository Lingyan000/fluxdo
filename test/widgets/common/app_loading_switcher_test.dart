import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({
    bool loading = true,
    Object identity = 'query',
    Widget? child,
  }) => MaterialApp(
    home: AppLoadingSwitcher(
      loading: loading,
      identity: identity,
      loadingBuilder: (_) => const Text('skeleton'),
      child: child ?? const Text('content'),
    ),
  );

  testWidgets('短加载直接进入内容，不出现骨架', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('skeleton'), findsNothing);
    await tester.pumpWidget(host(loading: false));
    expect(find.text('content'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('skeleton'), findsNothing);
  });

  testWidgets('长加载 400ms 后显示骨架，结果到达立即替换', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 399));
    expect(find.text('skeleton'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('skeleton'), findsOneWidget);
    await tester.pumpWidget(host(loading: false));
    expect(find.text('skeleton'), findsNothing);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('刷新保留原列表 Element 和滚动位置，失败正常呈现', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final list = ListView.builder(
      controller: controller,
      itemExtent: 50,
      itemCount: 100,
      itemBuilder: (_, i) => Text('row $i'),
    );
    await tester.pumpWidget(host(loading: false, child: list));
    controller.jumpTo(500);
    await tester.pump();
    final element = tester.element(find.byType(ListView));
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.element(find.byType(ListView)), same(element));
    expect(controller.offset, 500);
    expect(find.text('skeleton'), findsNothing);
    await tester.pumpWidget(
      host(loading: false, child: const Text('error/retry')),
    );
    expect(find.text('error/retry'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('切换账号/查询清除旧内容，计时从新请求开始', (tester) async {
    await tester.pumpWidget(host(loading: false));
    await tester.pumpWidget(host(identity: 'new account'));
    expect(find.text('content'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(host(identity: 'new query'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('skeleton'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('skeleton'), findsOneWidget);
    await tester.pumpWidget(
      host(
        identity: 'new query',
        loading: false,
        child: const Text('empty result'),
      ),
    );
    expect(find.text('empty result'), findsOneWidget);
  });

  testWidgets('加载期间销毁取消计时器', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
