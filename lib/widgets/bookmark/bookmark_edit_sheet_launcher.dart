import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/topic.dart';
import '../../providers/bookmark_name_suggestions_provider.dart';
import 'bookmark_edit_sheet.dart';

Future<BookmarkEditResult?> showBookmarkEditSheetWithCachedNames(
  BuildContext context,
  WidgetRef ref, {
  required int bookmarkId,
  String? initialName,
  DateTime? initialReminderAt,
  List<Topic> seedTopics = const [],
}) async {
  final suggestionsNotifier = ref.read(
    bookmarkNameSuggestionsProvider.notifier,
  );
  if (seedTopics.isNotEmpty) {
    suggestionsNotifier.seedFromTopics(seedTopics);
  }
  suggestionsNotifier.rememberName(initialName);

  final result = await BookmarkEditSheet.show(
    context,
    bookmarkId: bookmarkId,
    initialName: initialName,
    initialReminderAt: initialReminderAt,
    nameSuggestions: ref.read(bookmarkNameSuggestionsProvider),
    nameSuggestionsLoader: suggestionsNotifier.ensureLoaded,
  );

  if (result == null) {
    return null;
  }

  if (result.deleted) {
    suggestionsNotifier.markDirty();
  } else {
    suggestionsNotifier.markDirty(optimisticName: result.name);
  }
  return result;
}
