import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_more_menu_actions.dart';

void main() {
  test('选择编辑书签时只会触发书签动作', () {
    var editTopicCalls = 0;
    var bookmarkCalls = 0;
    var readLaterCalls = 0;
    var subscribeCalls = 0;
    var markUnreadCalls = 0;
    var shareLinkCalls = 0;
    var shareImageCalls = 0;
    var exportCalls = 0;
    var openInBrowserCalls = 0;
    var filterCalls = 0;
    var readingSettingsCalls = 0;

    handleTopicDetailMoreMenuSelection(
      'bookmark',
      onEditTopic: () => editTopicCalls++,
      onBookmark: () => bookmarkCalls++,
      onReadLater: () => readLaterCalls++,
      onSubscribe: () => subscribeCalls++,
      onMarkUnread: () => markUnreadCalls++,
      onMarkUnreadAll: () => markUnreadCalls++,
      onShareLink: () => shareLinkCalls++,
      onShareImage: () => shareImageCalls++,
      onExport: () => exportCalls++,
      onOpenInBrowser: () => openInBrowserCalls++,
      onFilter: () => filterCalls++,
      onReadingSettings: () => readingSettingsCalls++,
    );

    expect(editTopicCalls, 0);
    expect(bookmarkCalls, 1);
    expect(readLaterCalls, 0);
    expect(subscribeCalls, 0);
    expect(markUnreadCalls, 0);
    expect(shareLinkCalls, 0);
    expect(shareImageCalls, 0);
    expect(exportCalls, 0);
    expect(openInBrowserCalls, 0);
    expect(filterCalls, 0);
    expect(readingSettingsCalls, 0);
  });

  test('选择标记未读时只会触发标记未读动作', () {
    var markUnreadCalls = 0;
    var markUnreadAllCalls = 0;
    var otherCalls = 0;

    handleTopicDetailMoreMenuSelection(
      'mark_unread',
      onEditTopic: () => otherCalls++,
      onBookmark: () => otherCalls++,
      onReadLater: () => otherCalls++,
      onSubscribe: () => otherCalls++,
      onMarkUnread: () => markUnreadCalls++,
      onMarkUnreadAll: () => markUnreadAllCalls++,
      onShareLink: () => otherCalls++,
      onShareImage: () => otherCalls++,
      onExport: () => otherCalls++,
      onOpenInBrowser: () => otherCalls++,
      onFilter: () => otherCalls++,
      onReadingSettings: () => otherCalls++,
    );

    expect(markUnreadCalls, 1);
    expect(markUnreadAllCalls, 0);
    expect(otherCalls, 0);
  });

  test('选择全部未读时只会触发全部未读动作', () {
    var markUnreadCalls = 0;
    var markUnreadAllCalls = 0;
    var otherCalls = 0;

    handleTopicDetailMoreMenuSelection(
      'mark_unread_all',
      onEditTopic: () => otherCalls++,
      onBookmark: () => otherCalls++,
      onReadLater: () => otherCalls++,
      onSubscribe: () => otherCalls++,
      onMarkUnread: () => markUnreadCalls++,
      onMarkUnreadAll: () => markUnreadAllCalls++,
      onShareLink: () => otherCalls++,
      onShareImage: () => otherCalls++,
      onExport: () => otherCalls++,
      onOpenInBrowser: () => otherCalls++,
      onFilter: () => otherCalls++,
      onReadingSettings: () => otherCalls++,
    );

    expect(markUnreadCalls, 0);
    expect(markUnreadAllCalls, 1);
    expect(otherCalls, 0);
  });
}
