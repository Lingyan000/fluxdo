import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';

void main() {
  late ScrollController scroll;
  late ListController list;
  late ValueNotifier<double> height;
  final tallKey = GlobalKey();

  setUp(() {
    scroll = ScrollController();
    list = ListController();
    height = ValueNotifier(2000);
  });

  tearDown(() {
    scroll.dispose();
    list.dispose();
    height.dispose();
  });

  Widget app() {
    final keys = [for (var i = 0; i < 20; i++) 'post-$i'];
    return MaterialApp(
      home: Scaffold(
        body: PositionedStreamList(
          scrollController: scroll,
          listController: list,
          itemKeys: keys,
          positionKey: 0,
          initialIndex: 0,
          cacheExtent: 500,
          itemBuilder: (context, index) {
            final id = keys[index];
            final child = Align(alignment: Alignment.topLeft, child: Text(id));
            if (id == 'post-5') {
              return ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (_, value, _) =>
                    SizedBox(key: tallKey, height: value, child: child),
              );
            }
            return SizedBox(height: 100, child: child);
          },
        ),
      ),
    );
  }

  Future<void> jump(WidgetTester tester, int index, double offset) async {
    final done = list.jumpToIndex(index, offset: offset);
    await tester.pumpAndSettle();
    await done;
  }

  Future<void> shrink(WidgetTester tester) async {
    PositionedStreamList.keepTrailingEdgeOnShrink(tallKey.currentContext!);
    height.value = 300;
    await tester.pump();
  }

  double topOf(WidgetTester tester, String id) =>
      tester.getTopLeft(find.text(id)).dy;

  testWidgets('顶边滚出视口的长项收起后,其后的项留在原位', (tester) async {
    await tester.pumpWidget(app());
    // post-5 顶边在视口上方 1500px,底边与 post-6 在屏幕中部
    await jump(tester, 5, -1500);
    final before = topOf(tester, 'post-6');
    expect(before, greaterThan(0));

    await shrink(tester);
    expect(topOf(tester, 'post-6'), moreOrLessEquals(before));
    // 收起后的短项整个回到视口,底边贴着原位置
    expect(topOf(tester, 'post-5'), moreOrLessEquals(before - 300));
  });

  testWidgets('顶边在视口内时不修正,其后内容随收起上移', (tester) async {
    await tester.pumpWidget(app());
    await jump(tester, 4, 0);
    final tallTop = topOf(tester, 'post-5');

    await shrink(tester);
    expect(topOf(tester, 'post-5'), moreOrLessEquals(tallTop));
    expect(topOf(tester, 'post-6'), moreOrLessEquals(tallTop + 300));
  });
}
