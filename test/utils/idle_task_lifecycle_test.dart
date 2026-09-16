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
}
