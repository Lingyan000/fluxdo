import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/bookmark/mobile_topic_workspace_app_bar.dart';

void main() {
  testWidgets('移动端帖子工作区顶栏按预期顺序排列控件', (tester) async {
    const backKey = ValueKey('back');
    const closeKey = ValueKey('close');
    const titleKey = ValueKey('title');
    const searchKey = ValueKey('search');
    const countKey = ValueKey('count');
    const moreKey = ValueKey('more');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: MobileTopicWorkspaceAppBar(
            backButtonKey: backKey,
            closeButtonKey: closeKey,
            title: const Text(
              'Alpha',
              key: titleKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onBack: () {},
            onClose: () {},
            actions: [
              IconButton(
                key: searchKey,
                onPressed: () {},
                icon: const Icon(Icons.search),
              ),
              MobileWorkspaceCountButton(
                key: countKey,
                count: 3,
                tooltip: '已打开 3 个',
                onPressed: () {},
              ),
              IconButton(
                key: moreKey,
                onPressed: () {},
                icon: const Icon(Icons.more_vert),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final backLeft = tester.getTopLeft(find.byKey(backKey));
    final closeLeft = tester.getTopLeft(find.byKey(closeKey));
    final titleLeft = tester.getTopLeft(find.byKey(titleKey));
    final searchLeft = tester.getTopLeft(find.byKey(searchKey));
    final countLeft = tester.getTopLeft(find.byKey(countKey));
    final moreLeft = tester.getTopLeft(find.byKey(moreKey));

    expect(backLeft.dx, lessThan(closeLeft.dx));
    expect(closeLeft.dx, lessThan(titleLeft.dx));
    expect(titleLeft.dx, lessThan(searchLeft.dx));
    expect(searchLeft.dx, lessThan(countLeft.dx));
    expect(countLeft.dx, lessThan(moreLeft.dx));
  });

  testWidgets('移动端帖子工作区数字方框使用更紧凑的尺寸', (tester) async {
    const badgeKey = ValueKey('count-badge');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MobileWorkspaceCountButton(
              count: 12,
              tooltip: '已打开 12 个',
              onPressed: () {},
              badgeKey: badgeKey,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('12'), findsOneWidget);
    expect(tester.getSize(find.byKey(badgeKey)), const Size(26, 26));
  });
}
