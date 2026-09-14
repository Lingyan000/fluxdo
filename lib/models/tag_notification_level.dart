import '../l10n/s.dart';

/// 标签通知级别，与 Discourse TagUser.notification_levels 对应。
enum TagNotificationLevel {
  muted(0),
  regular(1),
  tracking(2),
  watching(3),
  watchingFirstPost(4);

  const TagNotificationLevel(this.value);
  final int value;

  String get label => switch (this) {
    muted => S.current.category_levelMuted,
    regular => S.current.category_levelRegular,
    tracking => S.current.category_levelTracking,
    watching => S.current.category_levelWatching,
    watchingFirstPost => S.current.category_levelWatchingFirstPost,
  };

  String get description => switch (this) {
    muted => S.current.tag_levelMutedDesc,
    regular => S.current.tag_levelRegularDesc,
    tracking => S.current.tag_levelTrackingDesc,
    watching => S.current.tag_levelWatchingDesc,
    watchingFirstPost => S.current.tag_levelWatchingFirstPostDesc,
  };

  static TagNotificationLevel fromValue(int? value) =>
      values.firstWhere((level) => level.value == value, orElse: () => regular);
}
