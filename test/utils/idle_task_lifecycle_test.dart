import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/idle_task.dart';
import 'package:fluxdo/widgets/topic/topic_card_prewarmer.dart';

void main() {
  testWidgets('取消空闲任务立即清除计时器且不会执行', (tester) async {
    var runs = 0;
    final handle = scheduleIdleTask(() => runs++);
    handle.cancel();
    handle.cancel();
    await tester.pump(const Duration(milliseconds: 16));
    expect(runs, 0);
  });

  testWidgets('空闲任务只执行一次', (tester) async {
    var runs = 0;
    scheduleIdleTask(() => runs++);
    await tester.pump(const Duration(milliseconds: 8));
    await tester.pump(const Duration(milliseconds: 16));
    expect(runs, 1);
  });

  testWidgets('预热范围立即卸载不留下计时器', (tester) async {
    var runs = 0;
    await tester.pumpWidget(
      CardPrewarmScope<int>(
        items: const [1],
        signature: 1,
        warmItem: (_, _) {
          runs++;
          return null;
        },
        child: const SizedBox(),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    expect(runs, 0);
    // 不推进 8ms：测试框架在结束时检查是否仍有 pending Timer。
  });

  testWidgets('预热签名更新取消旧任务，仅处理最新数据', (tester) async {
    final warmed = <int>[];
    Future<void> show(int value) => tester.pumpWidget(
      CardPrewarmScope<int>(
        items: [value],
        signature: value,
        warmItem: (_, item) {
          warmed.add(item);
          return null;
        },
        child: const SizedBox(),
      ),
    );
    await show(1);
    await show(2);
    await tester.pump(const Duration(milliseconds: 8));
    expect(warmed, [2]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手指按住拖动列表期间暂停空闲任务和卡片预热，松手停稳后恢复', (tester) async {
    addTearDown(resetIdleTaskInteractionState);
    final warmed = <int>[];
    var idleRuns = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CardPrewarmScope<int>(
          items: const [1, 2, 3],
          signature: 'drag-test',
          warmItem: (_, item) {
            warmed.add(item);
            return null;
          },
          child: ListView.builder(
            itemCount: 40,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('row $i')),
          ),
        ),
      ),
    );

    // 模拟手指按下并持续拖动（此时无动画 ticker，transientCallbackCount == 0）
    final gesture = await tester.startGesture(const Offset(100, 300));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();

    scheduleIdleTask(() => idleRuns++);

    // 拖动保持 300ms：期间不应执行空闲任务或预热
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(idleRuns, 0, reason: '手指按住拖动期间不应执行 scheduleIdleTask');
    expect(warmed, isEmpty, reason: '手指按住拖动期间不应执行卡片预热');

    // 松手并等待滚动停稳后恢复执行
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 24));
    expect(idleRuns, 1, reason: '滚动停稳后空闲任务应正常执行');
    expect(warmed, [1, 2, 3], reason: '滚动停稳后卡片预热应恢复完成');

    await tester.pumpWidget(const SizedBox());
  });
}
