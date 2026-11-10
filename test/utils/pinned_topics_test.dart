import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/utils/pinned_topics.dart';

Topic topic(
  int id, {
  bool pinned = false,
  bool unseen = false,
  int unread = 0,
  int highest = 5,
  int? lastRead,
}) => Topic(
  id: id,
  title: '话题 $id',
  slug: '$id',
  categoryId: '2',
  postsCount: highest,
  replyCount: highest - 1,
  views: 0,
  likeCount: 0,
  pinned: pinned,
  unseen: unseen,
  unread: unread,
  highestPostNumber: highest,
  lastReadPostNumber: lastRead,
);

void main() {
  test('新话题插到前面后，置顶仍在最前，普通话题顺序不变', () {
    final controller = PinnedTopicsController();
    controller.update([
      topic(3),
      topic(1, pinned: true, unseen: true),
      topic(4),
      topic(2, pinned: true),
      topic(5),
    ], identity: '首页');
    expect(controller.expanded, isTrue);
    expect(controller.unreadCount, 1);
    expect(controller.visible.map((t) => t.id), [1, 2, 3, 4, 5]);
  });

  test('全已读默认折叠，手动展开不会被无关重建收回', () {
    final controller = PinnedTopicsController();
    final items = [topic(1, pinned: true), topic(2)];
    controller.update(items, identity: '首页');
    expect(controller.visible.map((t) => t.id), [2]);
    controller.toggle();
    controller.update([...items, topic(3)], identity: '首页');
    expect(controller.expanded, isTrue);
    expect(controller.visible.map((t) => t.id), [1, 2, 3]);
  });

  test('未读回复不计入置顶未读，读过话题后自动折叠', () {
    final controller = PinnedTopicsController();
    final fresh = topic(1, pinned: true, unseen: true);
    final replies = topic(2, pinned: true, unread: 2, lastRead: 3);
    controller.update([fresh, replies], identity: '首页');
    expect(controller.expanded, isTrue);
    expect(controller.unreadCount, 1);
    controller.update([
      fresh.copyWith(unseen: false, unread: 4, lastReadPostNumber: 1),
      replies,
    ], identity: '首页');
    expect(controller.expanded, isFalse);
    expect(controller.unreadCount, 0);
    controller.update([
      fresh.copyWith(
        unseen: false,
        unread: 5,
        lastReadPostNumber: 1,
        highestPostNumber: 6,
      ),
      replies,
    ], identity: '首页');
    expect(controller.expanded, isFalse, reason: '新回复不能重新展开已读置顶');
  });

  test('手动折叠后同一新话题增加回复不展开，出现另一未读话题才展开', () {
    final controller = PinnedTopicsController();
    final fresh = topic(1, pinned: true, unseen: true);
    controller.update([fresh], identity: '首页');
    controller.toggle();
    controller.update([fresh.copyWith(highestPostNumber: 6)], identity: '首页');
    expect(controller.expanded, isFalse);
    controller.update([
      fresh,
      topic(2, pinned: true, unseen: true),
    ], identity: '首页');
    expect(controller.expanded, isTrue);
    expect(controller.unreadCount, 2);
  });

  test('已有阅读位置时忽略滞后的 unseen，已忽略的话题也不算未读', () {
    final controller = PinnedTopicsController();
    controller.update([
      topic(1, pinned: true, unseen: true, lastRead: 1, unread: 4),
      topic(2, pinned: true, unseen: false),
    ], identity: '首页');
    expect(controller.expanded, isFalse);
    expect(controller.unreadCount, 0);
  });

  test('切换筛选或账号重置手动状态', () {
    final controller = PinnedTopicsController();
    final items = [topic(1, pinned: true, unseen: true)];
    controller.update(items, identity: ('账号1', '最新'));
    controller.toggle();
    controller.update(items, identity: ('账号1', '未读'));
    expect(controller.expanded, isTrue);
    controller.toggle();
    controller.update(items, identity: ('账号2', '未读'));
    expect(controller.expanded, isTrue);
  });

  test('个人取消置顶仍归入站点置顶，管理员取消后不再置顶', () {
    expect(
      Topic.fromJson({'id': 1, 'pinned': false, 'unpinned': true}).pinned,
      isTrue,
    );
    expect(
      Topic.fromJson({'id': 1, 'pinned': false, 'unpinned': false}).pinned,
      isFalse,
    );
    expect(
      Topic.fromJson({'id': 1, 'pinned': false, 'unpinned': null}).pinned,
      isFalse,
    );
  });
}
