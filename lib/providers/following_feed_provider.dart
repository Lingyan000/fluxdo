// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';

import '../models/following_feed.dart';
import 'core_providers.dart';

typedef FollowingFeedLoader = Future<FollowingFeedResponse> Function(
  String? before,
);

class FollowingFeedState {
  const FollowingFeedState({
    this.posts = const [],
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = true,
    this.error,
    this.moreError,
  });
  final List<FollowingPost> posts;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final Object? error;
  final Object? moreError;
}

class FollowingFeedNotifier extends StateNotifier<FollowingFeedState> {
  FollowingFeedNotifier(this._load) : super(const FollowingFeedState());
  final FollowingFeedLoader _load;
  int _revision = 0;
  String? _cursor;

  Future<void> refresh() async {
    final revision = ++_revision;
    state = FollowingFeedState(
      posts: state.posts,
      loading: true,
      hasMore: state.hasMore,
    );
    try {
      final result = await _load(null);
      if (!mounted || revision != _revision) return;
      _cursor = result.posts.lastOrNull?.createdAtRaw;
      state = FollowingFeedState(
        posts: _unique(result.posts),
        hasMore: result.hasMore && result.posts.isNotEmpty,
      );
    } catch (error) {
      if (!mounted || revision != _revision) return;
      state = FollowingFeedState(
        posts: state.posts,
        hasMore: state.hasMore,
        error: error,
      );
    }
  }

  Future<void> loadMore() async {
    if (state.loading ||
        state.loadingMore ||
        !state.hasMore ||
        _cursor == null) {
      return;
    }
    final revision = _revision;
    final previous = state;
    final cursor = _cursor;
    state = FollowingFeedState(
      posts: previous.posts,
      loadingMore: true,
      hasMore: true,
    );
    try {
      final result = await _load(cursor);
      if (!mounted || revision != _revision) return;
      final next = result.posts.lastOrNull?.createdAtRaw;
      _cursor = next ?? cursor;
      state = FollowingFeedState(
        posts: _unique([...previous.posts, ...result.posts]),
        hasMore: result.hasMore && next != null && next != cursor,
      );
    } catch (error) {
      if (!mounted || revision != _revision) return;
      state = FollowingFeedState(
        posts: previous.posts,
        hasMore: true,
        moreError: error,
      );
    }
  }

  List<FollowingPost> _unique(List<FollowingPost> posts) {
    final ids = <int>{};
    return posts.where((post) => ids.add(post.id)).toList();
  }
}

/// 按账号隔离，最后一个页面离开后释放，不运行后台监控。
final followingFeedProvider = StateNotifierProvider.autoDispose
    .family<FollowingFeedNotifier, FollowingFeedState, String>((ref, username) {
      final service = ref.watch(discourseServiceProvider);
      return FollowingFeedNotifier(
        (before) => service.getFollowingFeed(username, before: before),
      )..refresh();
    });
