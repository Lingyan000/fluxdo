void handleTopicDetailMoreMenuSelection(
  String value, {
  required void Function() onEditTopic,
  required void Function() onBookmark,
  required void Function() onReadLater,
  required void Function() onSubscribe,
  required void Function() onShareLink,
  required void Function() onShareImage,
  required void Function() onExport,
  required void Function() onOpenInBrowser,
  required void Function() onFilter,
  required void Function() onReadingSettings,
}) {
  switch (value) {
    case 'edit_topic':
      onEditTopic();
      return;
    case 'bookmark':
      onBookmark();
      return;
    case 'read_later':
      onReadLater();
      return;
    case 'subscribe':
      onSubscribe();
      return;
    case 'share_link':
      onShareLink();
      return;
    case 'share_image':
      onShareImage();
      return;
    case 'export':
      onExport();
      return;
    case 'open_in_browser':
      onOpenInBrowser();
      return;
    case 'filter':
      onFilter();
      return;
    case 'reading_settings':
      onReadingSettings();
      return;
  }
}
