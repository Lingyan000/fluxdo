import 'package:flutter/foundation.dart';

import 'mini_app.dart';

typedef MiniAppPageFetcher = Future<MiniAppDirectory> Function({
  required String sort,
  required String query,
  required bool favorites,
  required int page,
});

/// Owns query generations so a late search/page response cannot replace a new
/// filter or append results belonging to an earlier query/account.
class MiniAppDirectoryController extends ChangeNotifier {
  MiniAppDirectoryController(this.fetch);
  final MiniAppPageFetcher fetch;
  String sort = 'latest', query = '';
  bool favorites = false, loading = false, loadingMore = false, hasMore = false;
  List<MiniApp> apps = const [];
  int total = 0, _page = -1, _generation = 0;
  Object? error;
  bool _disposed = false;

  void invalidate() {
    _generation++;
    loading = false;
    loadingMore = false;
    hasMore = false;
  }

  Future<void> update({String? sort, String? query, bool? favorites}) {
    this.sort = sort ?? this.sort;
    this.query = query ?? this.query;
    this.favorites = favorites ?? this.favorites;
    return refresh(clear: true);
  }

  Future<void> refresh({bool clear = false}) async {
    final generation = ++_generation;
    loading = true;
    loadingMore = false;
    error = null;
    if (clear) {
      apps = const [];
      total = 0;
      hasMore = false;
      _page = -1;
    }
    notifyListeners();
    await _load(generation, 0, append: false);
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore || _disposed) return;
    loadingMore = true;
    error = null;
    notifyListeners();
    await _load(_generation, _page + 1, append: true);
  }

  Future<void> _load(int generation, int page, {required bool append}) async {
    try {
      final result = await fetch(
        sort: sort,
        query: query,
        favorites: favorites,
        page: page,
      );
      if (_disposed || generation != _generation) return;
      final unique = {
        if (append)
          for (final app in apps) app.id: app,
      };
      for (final app in result.apps) {
        unique[app.id] = app;
      }
      apps = List.unmodifiable(unique.values);
      _page = result.page;
      total = result.total;
      hasMore = result.hasMore && result.apps.isNotEmpty;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
