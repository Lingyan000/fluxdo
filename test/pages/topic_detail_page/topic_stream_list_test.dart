import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';

void main() {
  late ScrollController scroll;
  late ListController list;
  late ValueNotifier<List<String>> rows;
  late ValueNotifier<double> height;
  var revision = 0;
  int? initialIndex = 50;
  final builtRows = <String>{};

  setUp(() {
    scroll = ScrollController();
    list = ListController();
    rows = ValueNotifier([
      for (var i = 0; i < 100; i++) 'post-$i',
      'recommendations',
    ]);
    height = ValueNotifier(100);
    revision = 0;
    initialIndex = 50;
    builtRows.clear();
  });

  tearDown(() {
    scroll.dispose();
    list.dispose();
    rows.dispose();
    height.dispose();
  });

  Widget app({bool variableHeights = false}) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<List<String>>(
        valueListenable: rows,
        builder: (context, keys, _) => PositionedStreamList(
          scrollController: scroll,
          listController: list,
          itemKeys: keys,
          positionKey: revision,
          initialIndex: initialIndex,
          cacheExtent: 500,
          itemBuilder: (context, index) {
            final id = keys[index];
            builtRows.add(id);
            final child = Align(alignment: Alignment.topLeft, child: Text(id));
            if (id == 'post-69') {
              return ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (_, value, _) => SizedBox(height: value, child: child),
              );
            }
            return SizedBox(
              height: id == 'recommendations'
                  ? 1000
                  : variableHeights
                  ? (80 + int.parse(id.substring(5)) % 7 * 31) *
                        800 /
                        MediaQuery.sizeOf(context).width
                  : 100,
              child: child,
            );
          },
        ),
      ),
    ),
  );

  Future<void> jump(WidgetTester tester, int index) async {
    final done = list.jumpToIndex(index, offset: -30);
    await tester.pumpAndSettle();
    await done;
  }

  Future<void> expectStable(
    WidgetTester tester,
    String id,
    VoidCallback mutate,
  ) async {
    final before = tester.getTopLeft(find.text(id)).dy;
    mutate();
    await tester.pump();
    expect(tester.getTopLeft(find.text(id)).dy, closeTo(before, 0.1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text(id)).dy, closeTo(before, 0.1));
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('从中间进入后，上方异步变高并插帖，首帧位置稳定', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 70);
    await expectStable(tester, 'post-70', () {
      height.value = 280;
      rows.value = [...rows.value.take(100), 'new-post', 'recommendations'];
    });
  });

  testWidgets('向上分页按稳定标识恢复可见帖子', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 70);
    await expectStable(tester, 'post-70', () {
      rows.value = [for (var i = -20; i < 0; i++) 'post-$i', ...rows.value];
    });
  });

  testWidgets('正在阅读推荐区时新增帖子，推荐区首帧位置稳定', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 100);
    await expectStable(tester, 'recommendations', () {
      rows.value = [...rows.value.take(100), 'new-post', 'recommendations'];
    });
  });

  testWidgets('刷新定位请求在同帧覆盖旧位置', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 70);
    revision++;
    initialIndex = 20;
    await tester.pumpWidget(app());
    expect(tester.getTopLeft(find.text('post-20')).dy, closeTo(0, 0.1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('删除当前阅读项后定位最近的后继项', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 70);
    rows.value = rows.value.where((id) => id != 'post-70').toList();
    await tester.pump();
    expect(tester.getTopLeft(find.text('post-71')).dy, closeTo(0, 0.1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('惯性滚动中前插立即布局，并连续推进滚动', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 70);
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -120),
      800,
    );
    await tester.pump(const Duration(milliseconds: 16));
    final anchorId = rows.value[list.anchor!.index];
    final before = tester.getTopLeft(find.text(anchorId)).dy;
    rows.value = [for (var i = -20; i < 0; i++) 'post-$i', ...rows.value];
    await tester.pump(const Duration(milliseconds: 16));
    final after = tester.getTopLeft(find.text(anchorId)).dy;
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expect(after, lessThan(before - 0.1));
    expect(after, greaterThan(before - 40));
    await tester.pump(const Duration(milliseconds: 16));
    final next = tester.getTopLeft(find.text(anchorId)).dy;
    expect(next, lessThan(after - 0.1));
    expect(next, greaterThan(after - 40));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('万条变高列表远距离定位仅构建目标附近内容', (tester) async {
    rows.value = [for (var i = 0; i < 10000; i++) 'post-$i'];
    initialIndex = 5000;
    await tester.pumpWidget(app(variableHeights: true));
    expect(tester.getTopLeft(find.text('post-5000')).dy, closeTo(0, 0.5));
    expect(builtRows.length, lessThan(100));
    for (final index in [10, 9990, 5, 8000]) {
      builtRows.clear();
      final done = list.jumpToIndex(index);
      await tester.pump();
      expect(tester.getTopLeft(find.text('post-$index')).dy, closeTo(0, 0.5));
      await tester.pumpAndSettle();
      await done;
      expect(builtRows.length, lessThan(100));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窗口变窄变宽后保持阅读条目和条目内阅读比例', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(variableHeights: true));
    await jump(tester, 70);
    final before = tester.getTopLeft(find.text('post-70')).dy;
    for (final width in [390.0, 1200.0, 600.0]) {
      tester.view.physicalSize = Size(width, 600);
      await tester.pump();
      // 重排导致条目高度按宽度缩放，引擎同步保留条目内的阅读比例。
      expect(
        tester.getTopLeft(find.text('post-70')).dy,
        closeTo(before * 800 / width, 0.5),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('post-70')).dy,
        closeTo(before * 800 / width, 0.5),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('连续增删重排与高度更新逐帧保持阅读条目', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 70);
    final before = tester.getTopLeft(find.text('post-70')).dy;
    final random = Random(2696141);
    for (var round = 0; round < 40; round++) {
      final updated = [...rows.value];
      final anchorIndex = updated.indexOf('post-70');
      updated.insert(random.nextInt(anchorIndex), 'inserted-$round');
      if (round.isEven) updated.removeAt(random.nextInt(anchorIndex));
      if (round % 3 == 0) {
        final moved = updated.removeAt(0);
        updated.insert(updated.indexOf('post-70'), moved);
      }
      height.value = 60.0 + random.nextInt(300);
      rows.value = updated;
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('post-70')).dy,
        closeTo(before, 0.5),
        reason: '第 $round 次更新',
      );
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('post-70')).dy, closeTo(before, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('上方内容逐帧增高和收缩时保持阅读位置', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 70);
    final before = tester.getTopLeft(find.text('post-70')).dy;
    for (final value in [160.0, 240.0, 360.0, 220.0, 100.0]) {
      height.value = value;
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(find.text('post-70')).dy, closeTo(before, 0.5));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('连续快速跳转以最后一个目标为准', (tester) async {
    await tester.pumpWidget(app());
    final first = list.jumpToIndex(10);
    final second = list.jumpToIndex(80);
    await tester.pump();
    expect(tester.getTopLeft(find.text('post-80')).dy, closeTo(0, 0.5));
    await tester.pumpAndSettle();
    await Future.wait([first, second]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('跳转请求尚未布局就离开页面可正常释放', (tester) async {
    await tester.pumpWidget(app());
    final done = list.jumpToIndex(80);
    await tester.pumpWidget(const SizedBox.shrink());
    await done;
    expect(list.isAttached, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未指定初始条目时保留外部控制器的初始偏移', (tester) async {
    scroll.dispose();
    scroll = ScrollController(initialScrollOffset: 2000);
    initialIndex = null;
    await tester.pumpWidget(app());
    expect(scroll.offset, closeTo(2000, 0.5));
    expect(tester.getTopLeft(find.text('post-20')).dy, closeTo(0, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
