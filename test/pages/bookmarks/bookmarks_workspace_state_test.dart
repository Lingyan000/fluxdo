import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';

void main() {
  test('首次进入工作区时只有固定书签标签', () {
    const state = BookmarksWorkspaceState();

    expect(state.activeTabId, BookmarksWorkspaceState.bookmarksTabId);
    expect(state.topicTabs, isEmpty);
  });

  test('打开话题会新增标签并激活', () {
    final state = const BookmarksWorkspaceState().openTopicTab(
      topicId: 42,
      title: 'FluxDO',
      scrollToPostNumber: 7,
    );

    expect(state.topicTabs, hasLength(1));
    expect(state.activeTabId, BookmarksWorkspaceState.topicTabId(42));
    expect(state.activeTopicTab?.title, 'FluxDO');
    expect(state.activeTopicTab?.scrollToPostNumber, 7);
    expect(state.activeTopicTab?.instanceId, isNotEmpty);
  });

  test('重复打开同一话题会复用标签并更新滚动目标', () {
    final opened = const BookmarksWorkspaceState().openTopicTab(
      topicId: 42,
      title: 'FluxDO',
      scrollToPostNumber: 7,
    );

    final reopened = opened.openTopicTab(
      topicId: 42,
      title: 'FluxDO',
      scrollToPostNumber: 18,
    );

    expect(reopened.topicTabs, hasLength(1));
    expect(
      reopened.topicTabs.single.instanceId,
      opened.topicTabs.single.instanceId,
    );
    expect(reopened.topicTabs.single.scrollToPostNumber, 18);
  });

  test('关闭当前激活标签后会回到左侧相邻标签', () {
    final state = const BookmarksWorkspaceState()
        .openTopicTab(topicId: 1, title: 'A')
        .openTopicTab(topicId: 2, title: 'B')
        .openTopicTab(topicId: 3, title: 'C');

    final closed = state.closeTopicTab(3);

    expect(closed.topicTabs.map((tab) => tab.topicId), [1, 2]);
    expect(closed.activeTabId, BookmarksWorkspaceState.topicTabId(2));
  });

  test('关闭最左侧唯一话题标签后回到我的书签', () {
    final state = const BookmarksWorkspaceState().openTopicTab(
      topicId: 1,
      title: 'A',
    );

    final closed = state.closeTopicTab(1);

    expect(closed.topicTabs, isEmpty);
    expect(closed.activeTabId, BookmarksWorkspaceState.bookmarksTabId);
  });

  test('可以按顺序切换到右侧相邻标签', () {
    final state = const BookmarksWorkspaceState()
        .openTopicTab(topicId: 1, title: 'A')
        .openTopicTab(topicId: 2, title: 'B')
        .activateBookmarksTab();

    final next = state.moveActiveTabBy(1);
    final last = next.moveActiveTabBy(2);

    expect(next.activeTabId, BookmarksWorkspaceState.topicTabId(1));
    expect(last.activeTabId, BookmarksWorkspaceState.topicTabId(2));
  });

  test('切到边界后继续滚动会停在当前标签', () {
    final state = const BookmarksWorkspaceState().openTopicTab(
      topicId: 1,
      title: 'A',
    );

    expect(
      state.moveActiveTabBy(1).moveActiveTabBy(1).activeTabId,
      BookmarksWorkspaceState.topicTabId(1),
    );
    expect(
      state.activateBookmarksTab().moveActiveTabBy(-1).activeTabId,
      BookmarksWorkspaceState.bookmarksTabId,
    );
  });

  test('后台打开标签页不会切走当前激活标签', () {
    final state = const BookmarksWorkspaceState()
        .openTopicTab(topicId: 1, title: 'A')
        .activateBookmarksTab();

    final backgroundOpened = state.openTopicTabInBackground(
      topicId: 2,
      title: 'B',
    );

    expect(
      backgroundOpened.activeTabId,
      BookmarksWorkspaceState.bookmarksTabId,
    );
    expect(backgroundOpened.topicTabs.map((tab) => tab.topicId), [1, 2]);
  });

  test('超过 10 个话题标签时会自动关闭最早打开的第一个标签', () {
    var state = const BookmarksWorkspaceState();
    for (var topicId = 1; topicId <= 10; topicId++) {
      state = state.openTopicTab(topicId: topicId, title: 'T$topicId');
    }

    final overflowed = state.openTopicTab(topicId: 11, title: 'T11');

    expect(overflowed.topicTabs, hasLength(10));
    expect(
      overflowed.topicTabs.map((tab) => tab.topicId),
      [2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    );
    expect(overflowed.activeTabId, BookmarksWorkspaceState.topicTabId(11));
  });

  test('后台打开第 11 个标签时也会淘汰最早打开的第一个标签', () {
    var state = const BookmarksWorkspaceState();
    for (var topicId = 1; topicId <= 10; topicId++) {
      state = state.openTopicTab(topicId: topicId, title: 'T$topicId');
    }
    state = state.activateBookmarksTab();

    final overflowed = state.openTopicTabInBackground(topicId: 11, title: 'T11');

    expect(overflowed.topicTabs, hasLength(10));
    expect(
      overflowed.topicTabs.map((tab) => tab.topicId),
      [2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    );
    expect(
      overflowed.activeTabId,
      BookmarksWorkspaceState.bookmarksTabId,
    );
  });

  test('打开书签话题时会保留并更新书签上下文', () {
    final opened = const BookmarksWorkspaceState().openTopicTab(
      topicId: 42,
      title: 'FluxDO',
      scrollToPostNumber: 7,
      bookmarkId: 101,
      bookmarkName: 'draft',
      bookmarkableType: 'Post',
    );

    expect(opened.activeTopicTab?.bookmarkId, 101);
    expect(opened.activeTopicTab?.bookmarkName, 'draft');
    expect(opened.activeTopicTab?.bookmarkableType, 'Post');

    final reopened = opened.openTopicTab(
      topicId: 42,
      title: 'FluxDO',
      scrollToPostNumber: 8,
      bookmarkId: 202,
      bookmarkName: 'updated',
      bookmarkableType: 'Topic',
    );

    expect(reopened.activeTopicTab?.bookmarkId, 202);
    expect(reopened.activeTopicTab?.bookmarkName, 'updated');
    expect(reopened.activeTopicTab?.bookmarkableType, 'Topic');
    expect(reopened.activeTopicTab?.scrollToPostNumber, 8);
  });
}
