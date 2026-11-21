import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:fluxdo/widgets/mention/mention_candidate_list.dart';

void main() {
  testWidgets('可见项保持位置，视口收缩和搜索刷新后仍能显示选中整行', (tester) async {
    var selected = 0;
    var height = 155.0;
    var count = 12;
    late StateSetter update;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SizedBox(
                width: 240,
                height: height,
                child: MentionCandidateList(
                  selectedIndex: selected,
                  children: [
                    for (var i = 0; i < count; i++)
                      SizedBox(key: ValueKey(i), height: i.isEven ? 50 : 40),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byType(MentionCandidateList);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    update(() => selected = 1);
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    update(() => selected = 3);
    await tester.pumpAndSettle();
    // 前四项高 180，视口高 155，只需滚动 25。
    expect(position.pixels, closeTo(25, 0.1));
    update(() => height = 75);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(105, 0.1));
    expect(
      tester.getRect(find.byKey(const ValueKey(3))).bottom,
      lessThanOrEqualTo(tester.getRect(list).bottom + 0.1),
    );
    update(() {
      selected = 0;
      count = 2;
    });
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    expect(tester.takeException(), isNull);
  });
}
