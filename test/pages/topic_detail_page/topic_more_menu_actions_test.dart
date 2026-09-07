import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_more_menu_actions.dart';

void main() {
  /// 归档入口共用 `archive_message` 一个 value，双态（归档 / 移回收件箱）
  /// 由 detail.messageArchived 决定文案与图标，分发这层不区分。
  test('archive_message 分发到归档回调', () {
    var toggled = 0;
    handleTopicDetailMoreMenuSelection(
      'archive_message',
      onEditTopic: () => fail('不应触发'),
      onBookmark: () => fail('不应触发'),
      onReadLater: () => fail('不应触发'),
      onSubscribe: () => fail('不应触发'),
      onMarkUnread: () => fail('不应触发'),
      onMarkUnreadAll: () => fail('不应触发'),
      onShareLink: () => fail('不应触发'),
      onShareImage: () => fail('不应触发'),
      onExport: () => fail('不应触发'),
      onOpenInBrowser: () => fail('不应触发'),
      onFilter: () => fail('不应触发'),
      onReadingSettings: () => fail('不应触发'),
      onToggleArchiveMessage: () => toggled++,
    );
    expect(toggled, 1);
  });

  test('非私信话题不传归档回调时选中该项不抛异常', () {
    // 菜单项本身已按 isPrivateMessage 门控，这里守的是分发层的健壮性
    handleTopicDetailMoreMenuSelection(
      'archive_message',
      onEditTopic: () => fail('不应触发'),
      onBookmark: () => fail('不应触发'),
      onReadLater: () => fail('不应触发'),
      onSubscribe: () => fail('不应触发'),
      onMarkUnread: () => fail('不应触发'),
      onMarkUnreadAll: () => fail('不应触发'),
      onShareLink: () => fail('不应触发'),
      onShareImage: () => fail('不应触发'),
      onExport: () => fail('不应触发'),
      onOpenInBrowser: () => fail('不应触发'),
      onFilter: () => fail('不应触发'),
      onReadingSettings: () => fail('不应触发'),
    );
  });

  test('其它菜单项不会误触归档', () {
    var toggled = 0;
    var exported = 0;
    handleTopicDetailMoreMenuSelection(
      'export',
      onEditTopic: () => fail('不应触发'),
      onBookmark: () => fail('不应触发'),
      onReadLater: () => fail('不应触发'),
      onSubscribe: () => fail('不应触发'),
      onMarkUnread: () => fail('不应触发'),
      onMarkUnreadAll: () => fail('不应触发'),
      onShareLink: () => fail('不应触发'),
      onShareImage: () => fail('不应触发'),
      onExport: () => exported++,
      onOpenInBrowser: () => fail('不应触发'),
      onFilter: () => fail('不应触发'),
      onReadingSettings: () => fail('不应触发'),
      onToggleArchiveMessage: () => toggled++,
    );
    expect(exported, 1);
    expect(toggled, 0);
  });
}
