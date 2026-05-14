import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/topic.dart';
import '../pages/bookmarks/bookmarks_models.dart';
import 'core_providers.dart';
import 'theme_provider.dart';

final bookmarkNameSuggestionPageLoaderProvider = Provider<BookmarkPageLoader>((
  ref,
) {
  final service = ref.read(discourseServiceProvider);
  return (page, limit) => service.getUserBookmarks(page: page, limit: limit);
});

class BookmarkNameSuggestionsNotifier extends Notifier<List<String>> {
  static const String _cacheKey = 'bookmark_name_suggestions_cache';

  Future<List<String>>? _loadingFuture;
  bool _didLoadAll = false;

  @override
  List<String> build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final cached = prefs.getStringList(_cacheKey) ?? const <String>[];
    return _normalizeSuggestions(cached);
  }

  void seedFromTopics(List<Topic> topics, {bool isCompleteSnapshot = false}) {
    final suggestions = buildBookmarkNameSuggestions(topics);
    if (isCompleteSnapshot) {
      _didLoadAll = true;
      _updateSuggestions(suggestions);
      return;
    }
    if (suggestions.isEmpty) {
      return;
    }
    _updateSuggestions(_mergeSuggestions(suggestions, state));
  }

  void rememberName(String? name) {
    final normalized = normalizeBookmarkName(name);
    if (normalized == null || state.contains(normalized)) {
      return;
    }
    _updateSuggestions([...state, normalized]);
  }

  void markDirty({String? optimisticName}) {
    _didLoadAll = false;
    rememberName(optimisticName);
  }

  void clearCache() {
    _didLoadAll = false;
    _loadingFuture = null;
    state = const <String>[];
    unawaited(ref.read(sharedPreferencesProvider).remove(_cacheKey));
  }

  Future<List<String>> ensureLoaded() {
    if (_didLoadAll) {
      return Future.value(state);
    }
    final inFlight = _loadingFuture;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _loadAllSuggestions();
    _loadingFuture = future;
    return future;
  }

  void prefetchIfEmpty() {
    if (_didLoadAll || _loadingFuture != null || state.isNotEmpty) {
      return;
    }
    unawaited(ensureLoaded().catchError((_) => state));
  }

  Future<List<String>> _loadAllSuggestions() async {
    try {
      final loadPage = ref.read(bookmarkNameSuggestionPageLoaderProvider);
      final topics = await loadAllBookmarkTopics(loadPage: loadPage);
      final suggestions = buildBookmarkNameSuggestions(topics);
      _updateSuggestions(suggestions);
      _didLoadAll = true;
      return state;
    } finally {
      _loadingFuture = null;
    }
  }

  void _updateSuggestions(List<String> suggestions) {
    final normalized = _normalizeSuggestions(suggestions);
    state = normalized;
    unawaited(
      ref.read(sharedPreferencesProvider).setStringList(_cacheKey, normalized),
    );
  }

  List<String> _mergeSuggestions(List<String> primary, List<String> secondary) {
    final merged = <String>[];
    final seen = <String>{};
    for (final suggestion in [...primary, ...secondary]) {
      final normalized = normalizeBookmarkName(suggestion);
      if (normalized == null || !seen.add(normalized)) {
        continue;
      }
      merged.add(normalized);
    }
    return merged;
  }

  List<String> _normalizeSuggestions(Iterable<String> suggestions) {
    return _mergeSuggestions(List<String>.from(suggestions), const <String>[]);
  }
}

final bookmarkNameSuggestionsProvider =
    NotifierProvider<BookmarkNameSuggestionsNotifier, List<String>>(
      BookmarkNameSuggestionsNotifier.new,
    );
