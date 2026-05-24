import 'package:uuid/uuid.dart';

import '../../models/topic.dart';
import '../../utils/bookmark_name_utils.dart';

export '../../utils/bookmark_name_utils.dart' show normalizeBookmarkName;

const String unsetBookmarkNameFilterKey = '__bookmark_name_unset__';
// Discourse 书签接口单页上限是 20，超过会直接返回 invalid_parameters。
const int bookmarkRequestLimit = 20;

typedef BookmarkPageLoader =
    Future<TopicListResponse> Function(int page, int limit);

int _normalizeBookmarkRequestLimit(int requestLimit) {
  if (requestLimit <= 0) {
    return bookmarkRequestLimit;
  }
  return requestLimit > bookmarkRequestLimit
      ? bookmarkRequestLimit
      : requestLimit;
}

int? resolveBookmarkScrollToPostNumber(Topic topic) {
  return topic.bookmarkedPostNumber ?? topic.lastReadPostNumber;
}

class BookmarkNameSummary {
  const BookmarkNameSummary({
    required this.filterKey,
    required this.displayName,
    required this.count,
  });

  final String filterKey;
  final String displayName;
  final int count;

  bool get isUnset => filterKey == unsetBookmarkNameFilterKey;

  String get label => '$displayName ($count)';
}

List<BookmarkNameSummary> buildBookmarkNameSummaries(List<Topic> topics) {
  final counts = <String, int>{};
  var unsetCount = 0;
  for (final topic in topics) {
    final name = normalizeBookmarkName(topic.bookmarkName);
    if (name == null) {
      unsetCount++;
      continue;
    }
    counts.update(name, (value) => value + 1, ifAbsent: () => 1);
  }

  final summaries = counts.entries
      .map(
        (entry) => BookmarkNameSummary(
          filterKey: entry.key,
          displayName: entry.key,
          count: entry.value,
        ),
      )
      .toList();
  summaries.sort((a, b) {
    final countCompare = b.count.compareTo(a.count);
    if (countCompare != 0) {
      return countCompare;
    }
    return a.displayName.compareTo(b.displayName);
  });
  if (unsetCount > 0) {
    summaries.insert(
      0,
      BookmarkNameSummary(
        filterKey: unsetBookmarkNameFilterKey,
        displayName: unsetBookmarkNameFilterKey,
        count: unsetCount,
      ),
    );
  }
  return summaries;
}

List<String> buildBookmarkNameSuggestions(List<Topic> topics) {
  return buildBookmarkNameSummaries(topics)
      .where((summary) => !summary.isUnset)
      .map((summary) => summary.displayName)
      .toList();
}

List<Topic> filterBookmarksByName(
  List<Topic> topics,
  String? selectedBookmarkName,
) {
  if (selectedBookmarkName == null) {
    return topics;
  }
  if (selectedBookmarkName == unsetBookmarkNameFilterKey) {
    return topics
        .where((topic) => normalizeBookmarkName(topic.bookmarkName) == null)
        .toList();
  }
  return topics.where((topic) {
    return normalizeBookmarkName(topic.bookmarkName) == selectedBookmarkName;
  }).toList();
}

String bookmarkTopicIdentity(Topic topic) {
  final bookmarkId = topic.bookmarkId;
  if (bookmarkId != null) {
    return 'bookmark:$bookmarkId';
  }
  return 'topic:${topic.id}';
}

Future<List<Topic>> loadAllBookmarkTopics({
  required BookmarkPageLoader loadPage,
  int requestLimit = bookmarkRequestLimit,
}) async {
  final topics = <Topic>[];
  final seenKeys = <String>{};
  final effectiveRequestLimit = _normalizeBookmarkRequestLimit(requestLimit);
  var page = 0;

  while (true) {
    final response = await loadPage(page, effectiveRequestLimit);
    if (response.topics.isEmpty) {
      break;
    }

    var addedCount = 0;
    for (final topic in response.topics) {
      final key = bookmarkTopicIdentity(topic);
      if (seenKeys.add(key)) {
        topics.add(topic);
        addedCount++;
      }
    }
    if (addedCount == 0) {
      break;
    }
    page++;
  }

  return topics;
}

Stream<List<Topic>> progressivelyLoadAllBookmarkTopics({
  required BookmarkPageLoader loadPage,
  int requestLimit = bookmarkRequestLimit,
}) async* {
  final topics = <Topic>[];
  final seenKeys = <String>{};
  final effectiveRequestLimit = _normalizeBookmarkRequestLimit(requestLimit);
  var page = 0;
  var emitted = false;

  while (true) {
    final response = await loadPage(page, effectiveRequestLimit);
    if (response.topics.isEmpty) {
      break;
    }

    var addedCount = 0;
    for (final topic in response.topics) {
      final key = bookmarkTopicIdentity(topic);
      if (seenKeys.add(key)) {
        topics.add(topic);
        addedCount++;
      }
    }
    if (addedCount == 0) {
      break;
    }
    emitted = true;
    yield List.unmodifiable(topics);
    page++;
  }

  if (!emitted) {
    yield const <Topic>[];
  }
}

class BookmarkWorkspaceTopicTab {
  const BookmarkWorkspaceTopicTab({
    required this.topicId,
    required this.title,
    required this.instanceId,
    this.scrollToPostNumber,
    this.bookmarkId,
    this.bookmarkName,
    this.bookmarkReminderAt,
    this.bookmarkableType,
  });

  final int topicId;
  final String title;
  final int? scrollToPostNumber;
  final int? bookmarkId;
  final String? bookmarkName;
  final DateTime? bookmarkReminderAt;
  final String? bookmarkableType;
  final String instanceId;

  String get tabId => BookmarksWorkspaceState.topicTabId(topicId);

  BookmarkWorkspaceTopicTab copyWith({
    String? title,
    int? scrollToPostNumber,
    int? bookmarkId,
    String? bookmarkName,
    DateTime? bookmarkReminderAt,
    String? bookmarkableType,
  }) {
    return BookmarkWorkspaceTopicTab(
      topicId: topicId,
      title: title ?? this.title,
      scrollToPostNumber: scrollToPostNumber ?? this.scrollToPostNumber,
      bookmarkId: bookmarkId ?? this.bookmarkId,
      bookmarkName: bookmarkName ?? this.bookmarkName,
      bookmarkReminderAt: bookmarkReminderAt ?? this.bookmarkReminderAt,
      bookmarkableType: bookmarkableType ?? this.bookmarkableType,
      instanceId: instanceId,
    );
  }
}

class BookmarksWorkspaceState {
  static const String bookmarksTabId = 'bookmarks';
  static const int maxTopicTabs = 10;
  static final Uuid _uuid = const Uuid();

  const BookmarksWorkspaceState({
    this.activeTabId = bookmarksTabId,
    this.topicTabs = const [],
  });

  final String activeTabId;
  final List<BookmarkWorkspaceTopicTab> topicTabs;

  static String topicTabId(int topicId) => 'topic:$topicId';

  BookmarkWorkspaceTopicTab? get activeTopicTab {
    for (final tab in topicTabs) {
      if (tab.tabId == activeTabId) {
        return tab;
      }
    }
    return null;
  }

  BookmarksWorkspaceState copyWith({
    String? activeTabId,
    List<BookmarkWorkspaceTopicTab>? topicTabs,
  }) {
    return BookmarksWorkspaceState(
      activeTabId: activeTabId ?? this.activeTabId,
      topicTabs: topicTabs ?? this.topicTabs,
    );
  }

  BookmarksWorkspaceState activateBookmarksTab() {
    if (activeTabId == bookmarksTabId) {
      return this;
    }
    return copyWith(activeTabId: bookmarksTabId);
  }

  BookmarksWorkspaceState activateTopicTab(int topicId) {
    final nextActiveTabId = topicTabId(topicId);
    if (activeTabId == nextActiveTabId) {
      return this;
    }
    return copyWith(activeTabId: nextActiveTabId);
  }

  List<String> orderedTabIds() {
    return [bookmarksTabId, ...topicTabs.map((tab) => tab.tabId)];
  }

  BookmarksWorkspaceState moveActiveTabBy(int offset) {
    if (offset == 0) {
      return this;
    }
    final tabIds = orderedTabIds();
    final currentIndex = tabIds.indexOf(activeTabId);
    if (currentIndex == -1) {
      return this;
    }
    final nextIndex = (currentIndex + offset).clamp(0, tabIds.length - 1);
    final nextTabId = tabIds[nextIndex];
    if (nextTabId == activeTabId) {
      return this;
    }
    if (nextTabId == bookmarksTabId) {
      return activateBookmarksTab();
    }
    final topicId = topicTabs[nextIndex - 1].topicId;
    return activateTopicTab(topicId);
  }

  ({List<BookmarkWorkspaceTopicTab> tabs, String activeTabId})
  _applyTopicTabLimit(
    List<BookmarkWorkspaceTopicTab> tabs,
    String activeTabId,
  ) {
    if (tabs.length <= maxTopicTabs) {
      return (tabs: tabs, activeTabId: activeTabId);
    }

    final removedTabId = tabs.first.tabId;
    final trimmedTabs = tabs.sublist(tabs.length - maxTopicTabs);
    final resolvedActiveTabId = activeTabId == removedTabId
        ? bookmarksTabId
        : activeTabId;
    return (tabs: trimmedTabs, activeTabId: resolvedActiveTabId);
  }

  BookmarksWorkspaceState openTopicTab({
    required int topicId,
    required String title,
    int? scrollToPostNumber,
    int? bookmarkId,
    String? bookmarkName,
    DateTime? bookmarkReminderAt,
    String? bookmarkableType,
  }) {
    final existingIndex = topicTabs.indexWhere((tab) => tab.topicId == topicId);
    if (existingIndex != -1) {
      final updatedTabs = [...topicTabs];
      updatedTabs[existingIndex] = BookmarkWorkspaceTopicTab(
        topicId: topicId,
        title: title,
        scrollToPostNumber: scrollToPostNumber,
        bookmarkId: bookmarkId,
        bookmarkName: bookmarkName,
        bookmarkReminderAt: bookmarkReminderAt,
        bookmarkableType: bookmarkableType,
        instanceId: updatedTabs[existingIndex].instanceId,
      );
      return copyWith(activeTabId: topicTabId(topicId), topicTabs: updatedTabs);
    }

    final limited = _applyTopicTabLimit(
      [
        ...topicTabs,
        BookmarkWorkspaceTopicTab(
          topicId: topicId,
          title: title,
          scrollToPostNumber: scrollToPostNumber,
          bookmarkId: bookmarkId,
          bookmarkName: bookmarkName,
          bookmarkReminderAt: bookmarkReminderAt,
          bookmarkableType: bookmarkableType,
          instanceId: _uuid.v4(),
        ),
      ],
      topicTabId(topicId),
    );
    return copyWith(
      activeTabId: limited.activeTabId,
      topicTabs: limited.tabs,
    );
  }

  BookmarksWorkspaceState openTopicTabInBackground({
    required int topicId,
    required String title,
    int? scrollToPostNumber,
    int? bookmarkId,
    String? bookmarkName,
    DateTime? bookmarkReminderAt,
    String? bookmarkableType,
  }) {
    final existingIndex = topicTabs.indexWhere((tab) => tab.topicId == topicId);
    if (existingIndex != -1) {
      final updatedTabs = [...topicTabs];
      updatedTabs[existingIndex] = BookmarkWorkspaceTopicTab(
        topicId: topicId,
        title: title,
        scrollToPostNumber: scrollToPostNumber,
        bookmarkId: bookmarkId,
        bookmarkName: bookmarkName,
        bookmarkReminderAt: bookmarkReminderAt,
        bookmarkableType: bookmarkableType,
        instanceId: updatedTabs[existingIndex].instanceId,
      );
      return copyWith(topicTabs: updatedTabs);
    }

    final limited = _applyTopicTabLimit(
      [
        ...topicTabs,
        BookmarkWorkspaceTopicTab(
          topicId: topicId,
          title: title,
          scrollToPostNumber: scrollToPostNumber,
          bookmarkId: bookmarkId,
          bookmarkName: bookmarkName,
          bookmarkReminderAt: bookmarkReminderAt,
          bookmarkableType: bookmarkableType,
          instanceId: _uuid.v4(),
        ),
      ],
      activeTabId,
    );
    return copyWith(
      activeTabId: limited.activeTabId,
      topicTabs: limited.tabs,
    );
  }

  BookmarksWorkspaceState closeTopicTab(int topicId) {
    final existingIndex = topicTabs.indexWhere((tab) => tab.topicId == topicId);
    if (existingIndex == -1) {
      return this;
    }

    final nextTabs = [...topicTabs]..removeAt(existingIndex);
    if (activeTabId != topicTabId(topicId)) {
      return copyWith(topicTabs: nextTabs);
    }

    final nextActiveTabId = existingIndex > 0
        ? nextTabs[existingIndex - 1].tabId
        : bookmarksTabId;
    return copyWith(activeTabId: nextActiveTabId, topicTabs: nextTabs);
  }
}
