import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';

void main() {
  test('从列表选中的首层会立即绑定稳定 instanceId', () {
    final notifier = SelectedTopicNotifier()..select(topicId: 1);
    final instanceId = notifier.state.instanceId;

    expect(instanceId, isNotNull);

    notifier.push(topicId: 2);

    expect(notifier.state.stack.first.instanceId, instanceId);
  });

  test('同一话题的不同面板实例分别保存浏览位置', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const first = (topicId: 1, instanceId: 'first');
    const second = (topicId: 1, instanceId: 'second');

    container.read(detailScrollPositionProvider(first).notifier).state = 120;

    expect(container.read(detailScrollPositionProvider(first)), 120);
    expect(container.read(detailScrollPositionProvider(second)), isNull);
  });

  group('SelectedTopicNotifier.updateTopTopic', () {
    test('更新栈顶话题时保留此前的平行视界历史', () {
      final notifier = SelectedTopicNotifier()
        ..select(topicId: 1, initialTitle: '第一层')
        ..pushProfile('alice')
        ..push(topicId: 2, initialTitle: '旧标题');

      notifier.updateTopTopic(
        topicId: 2,
        initialTitle: '新标题',
        scrollToPostNumber: 42,
        instanceId: 'instance-2',
      );

      expect(notifier.state.stack, hasLength(3));
      expect(notifier.state.stack[0].topicId, 1);
      expect(notifier.state.stack[1].username, 'alice');
      expect(notifier.state.topEntry?.topicId, 2);
      expect(notifier.state.topEntry?.initialTitle, '新标题');
      expect(notifier.state.topEntry?.scrollToPostNumber, 42);
      expect(notifier.state.topEntry?.instanceId, 'instance-2');
    });

    test('栈顶不是目标话题时不修改状态', () {
      final notifier = SelectedTopicNotifier()
        ..select(topicId: 1)
        ..pushProfile('alice');
      final before = notifier.state;

      notifier.updateTopTopic(topicId: 1, scrollToPostNumber: 9);

      expect(notifier.state, same(before));
    });
  });

  test('切换左栏时仅保留当前栈顶详情', () {
    final notifier = SelectedTopicNotifier()
      ..select(topicId: 1)
      ..pushProfile('alice')
      ..push(topicId: 2);

    notifier.collapseToTop();

    expect(notifier.state.stack, hasLength(1));
    expect(notifier.state.topicId, 2);
    expect(notifier.state.isStacked, isFalse);
  });

  test('追觅平行视界与首页、搜索栈相互隔离', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(selectedSeekingProvider.notifier).select(topicId: 99);

    expect(container.read(selectedSeekingProvider).topicId, 99);
    expect(container.read(selectedTopicProvider).hasSelection, isFalse);
    expect(container.read(selectedSearchProvider).hasSelection, isFalse);
  });

  group('分类层(PaneKind.category)——列表态,插到栈顶下面当左栏信息流', () {
    test('单层话题时打开分类:分类垫底、话题留在栈顶(右栏不动)', () {
      final notifier = SelectedTopicNotifier()
        ..select(topicId: 1)
        ..openCategoryAsMaster(14);

      expect(notifier.state.stack, hasLength(2));
      expect(notifier.state.stack[0].kind, PaneKind.category);
      expect(notifier.state.stack[0].categoryId, 14);
      // 栈顶仍是原话题,右栏保住正在看的内容
      expect(notifier.state.topicId, 1);
    });

    test('深栈时插到栈顶下面,左栏预览位变成分类', () {
      final notifier = SelectedTopicNotifier()
        ..select(topicId: 1)
        ..push(topicId: 2)
        ..openCategoryAsMaster(14);

      expect(notifier.state.stack, hasLength(3));
      expect(notifier.state.stack[1].kind, PaneKind.category);
      expect(notifier.state.topicId, 2);
    });

    test('分类层唯一:再开新分类时旧分类层被清掉', () {
      final notifier = SelectedTopicNotifier()
        ..select(topicId: 1)
        ..openCategoryAsMaster(14)
        ..openCategoryAsMaster(99);

      expect(notifier.state.stack, hasLength(2));
      expect(notifier.state.stack[0].categoryId, 99);
      expect(notifier.state.topicId, 1);
    });

    test('栈顶本身是分类时直接替换,不往下插', () {
      final notifier = SelectedTopicNotifier()
        ..select(topicId: 1)
        ..openCategoryAsMaster(14)
        ..pop(); // 弹掉话题,分类成为栈顶

      expect(notifier.state.topEntry?.kind, PaneKind.category);

      notifier.openCategoryAsMaster(99);

      expect(notifier.state.stack, hasLength(1));
      expect(notifier.state.topEntry?.categoryId, 99);
    });

    test('pop 栈顶话题后分类层仍在,topicId 口径为 null', () {
      final notifier = SelectedTopicNotifier()
        ..select(topicId: 1)
        ..openCategoryAsMaster(14)
        ..pop();

      expect(notifier.state.stack, hasLength(1));
      expect(notifier.state.topEntry?.categoryId, 14);
      expect(notifier.state.topicId, isNull);
    });
  });

  testWidgets('EmbeddedStackScope 将资料页话题入口压入当前面板栈', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EmbeddedStackScope(
            stackProvider: selectedMessageProvider,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => EmbeddedStackScope.maybePushTopic(
                  context,
                  topicId: 42,
                  initialTitle: '资料页话题',
                  scrollToPostNumber: 7,
                ),
                child: const Text('打开话题'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开话题'));

    final state = container.read(selectedMessageProvider);
    expect(state.stack, hasLength(1));
    expect(state.topicId, 42);
    expect(state.initialTitle, '资料页话题');
    expect(state.scrollToPostNumber, 7);
    expect(container.read(selectedTopicProvider).hasSelection, isFalse);
  });
}
