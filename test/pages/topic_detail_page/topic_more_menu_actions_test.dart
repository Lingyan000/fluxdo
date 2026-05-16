import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_more_menu_actions.dart';

void main() {
  test('选择编辑书签时只会触发书签动作', () {
    var editTopicCalls = 0;
    var bookmarkCalls = 0;
    var readLaterCalls = 0;
    var subscribeCalls = 0;
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
    expect(shareLinkCalls, 0);
    expect(shareImageCalls, 0);
    expect(exportCalls, 0);
    expect(openInBrowserCalls, 0);
    expect(filterCalls, 0);
    expect(readingSettingsCalls, 0);
  });
}
