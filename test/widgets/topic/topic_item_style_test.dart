import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_item_builder.dart';

void main() {
  testWidgets('分类图标内联标题，换行后从段落左侧开始且保留未读数', (tester) async {
    final topic = Topic(
      id: 9,
      title: '一个需要换行的置顶话题标题，图标只占用第一行空间',
      slug: 'wrap',
      postsCount: 9,
      replyCount: 8,
      views: 0,
      likeCount: 0,
      categoryId: '1',
      pinned: true,
      unread: 5,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                child: CompactTopicCard(
                  topic: topic,
                  group: (index: 1, count: 2),
                  categoryMap: {
                    1: Category(
                      id: 1,
                      name: '社区',
                      slug: 'community',
                      color: '888888',
                      textColor: 'FFFFFF',
                      icon: 'comments',
                    ),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final icon = find.byKey(const ValueKey('topic-category-inline-9'));
    expect(icon, findsOneWidget);
    expect(
      find.ancestor(of: icon, matching: find.byType(RichText)),
      findsOneWidget,
    );
    final paragraphFinder = find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains(topic.title),
    );
    final paragraph = tester.renderObject<RenderParagraph>(paragraphFinder);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: 1,
        extentOffset: paragraph.text.toPlainText().length,
      ),
    );
    expect(boxes.length, greaterThan(1));
    expect(boxes.first.left, greaterThan(0));
    expect(
      boxes.any((box) => box.top > boxes.first.top && box.left.abs() < 0.5),
      isTrue,
      reason: '第二行不能保留图标列的缩进',
    );
    expect(find.text('5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final style in TopicItemStyle.values) {
    testWidgets('置顶话题卡片按列表指定的 $style 展示，默认保持普通卡片', (tester) async {
      final topic = Topic(
        id: 1,
        title: 'Pinned topic',
        slug: 'pinned',
        postsCount: 8,
        replyCount: 7,
        views: 100,
        likeCount: 2,
        categoryId: '1',
        pinned: true,
        unread: 5,
        lastReadPostNumber: 3,
        highestPostNumber: 8,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => buildTopicItem(
                  context: context,
                  topic: topic,
                  style: style,
                  isSelected: false,
                  onTap: () {},
                  enableLongPress: false,
                  categoryMap: const <int, Category>{},
                ),
              ),
            ),
          ),
        ),
      );
      if (style == TopicItemStyle.standard) {
        expect(find.byType(PaintedTopicCard), findsOneWidget);
        expect(find.byType(CompactTopicCard), findsNothing);
      } else {
        expect(find.byType(CompactTopicCard), findsOneWidget);
        expect(find.text('5'), findsOneWidget, reason: '卡片继续显示未读帖子数');
        expect(find.byIcon(Symbols.push_pin_rounded), findsNothing);
        expect(find.byType(PaintedTopicCard), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
