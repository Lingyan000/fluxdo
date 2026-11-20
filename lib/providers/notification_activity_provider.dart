import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user_action.dart';
import '../utils/paged_async_notifier.dart';
import '../utils/pagination_helper.dart';
import 'core_providers.dart';

/// 通知页里由当前用户活动流提供的栏目，[types] 为 user_actions 的筛选类型
enum NotificationActionStream {
  // 回复栏目同时包含引用，与网页通知页一致
  replies([UserActionType.response, UserActionType.quote]),
  mentions([UserActionType.mention]),
  likes([UserActionType.wasLiked]),
  edits([UserActionType.edit]),
  links([UserActionType.linked]);

  const NotificationActionStream(this.types);
  final List<int> types;
}

/// 当前用户某类活动流（被回复、被提及、获赞等），offset 分页每页 30
class NotificationActionsNotifier extends AsyncNotifier<List<UserAction>>
    with PagedAsyncNotifierMixin<UserAction> {
  NotificationActionsNotifier(this.stream);

  final NotificationActionStream stream;

  static final _paginationHelper = PaginationHelpers.forList<UserAction>(
    keyExtractor: (a) => a.dedupeKey,
    expectedPageSize: 30,
  );

  String? get _username => ref.read(currentUserProvider).value?.username;

  Future<UserActionResponse> _fetch(String username, int offset) => ref
      .read(discourseServiceProvider)
      .getUserActions(username, filter: stream.types.join(','), offset: offset);

  Future<PagedPage<UserAction>> _loadFirstPage() async {
    final username = _username;
    if (username == null) return const PagedPage(items: [], hasMore: false);
    final response = await _fetch(username, 0);
    return PagedPage.fromPagination(
      _paginationHelper.processRefresh(
        PaginationResult(items: response.actions, expectedPageSize: 30),
      ),
    );
  }

  @override
  Future<List<UserAction>> build() async {
    ref.watch(currentUserProvider.select((user) => user.value?.username));
    resetPagingState();
    return completePagedRefresh(await _loadFirstPage());
  }

  Future<void> refresh() => runPagedRefresh(_loadFirstPage);

  Future<void> loadMore() => runPagedLoadMore((currentItems, _) async {
    final response = await _fetch(_username!, currentItems.length);
    return PagedPage.fromPagination(
      _paginationHelper.processLoadMore(
        PaginationState(items: currentItems),
        PaginationResult(items: response.actions, expectedPageSize: 30),
      ),
    );
  });

  Future<void> retryLoadMore() => retryPagedLoadMore(loadMore);
}

final notificationActionsProvider = AsyncNotifierProvider.family
    .autoDispose<
      NotificationActionsNotifier,
      List<UserAction>,
      NotificationActionStream
    >(NotificationActionsNotifier.new);

/// 当前用户收到的插件互动（回应、Boost），按条目 id 游标分页每页 20
abstract class _ReceivedFeedNotifier<T> extends AsyncNotifier<List<T>>
    with PagedAsyncNotifierMixin<T> {
  late final _paginationHelper = PaginationHelpers.forList<T>(
    keyExtractor: idOf,
    expectedPageSize: 20,
  );

  int idOf(T item);

  /// [beforeId] 为 null 时取第一页
  Future<List<T>> fetch(String username, int? beforeId);

  String? get _username => ref.read(currentUserProvider).value?.username;

  Future<PagedPage<T>> _loadFirstPage() async {
    final username = _username;
    if (username == null) return PagedPage<T>(items: const [], hasMore: false);
    return PagedPage.fromPagination(
      _paginationHelper.processRefresh(
        PaginationResult(
          items: await fetch(username, null),
          expectedPageSize: 20,
        ),
      ),
    );
  }

  @override
  Future<List<T>> build() async {
    ref.watch(currentUserProvider.select((user) => user.value?.username));
    resetPagingState();
    return completePagedRefresh(await _loadFirstPage());
  }

  Future<void> refresh() => runPagedRefresh(_loadFirstPage);

  Future<void> loadMore() => runPagedLoadMore((currentItems, _) async {
    final items = await fetch(_username!, idOf(currentItems.last));
    return PagedPage.fromPagination(
      _paginationHelper.processLoadMore(
        PaginationState(items: currentItems),
        PaginationResult(items: items, expectedPageSize: 20),
      ),
    );
  });

  Future<void> retryLoadMore() => retryPagedLoadMore(loadMore);
}

/// 收到的回应（discourse-reactions 插件）
class ReceivedReactionsNotifier extends _ReceivedFeedNotifier<UserReaction> {
  @override
  int idOf(UserReaction item) => item.id;

  @override
  Future<List<UserReaction>> fetch(String username, int? beforeId) async =>
      (await ref
              .read(discourseServiceProvider)
              .getUserReactionsReceived(
                username,
                beforeReactionUserId: beforeId,
              ))
          .reactions;
}

final receivedReactionsProvider =
    AsyncNotifierProvider.autoDispose<
      ReceivedReactionsNotifier,
      List<UserReaction>
    >(ReceivedReactionsNotifier.new);

/// 收到的 Boost（discourse-boosts 插件）
class ReceivedBoostsNotifier extends _ReceivedFeedNotifier<UserBoost> {
  @override
  int idOf(UserBoost item) => item.id;

  @override
  Future<List<UserBoost>> fetch(String username, int? beforeId) async =>
      (await ref
              .read(discourseServiceProvider)
              .getUserBoostsReceived(username, beforeBoostId: beforeId))
          .boosts;
}

final receivedBoostsProvider =
    AsyncNotifierProvider.autoDispose<ReceivedBoostsNotifier, List<UserBoost>>(
      ReceivedBoostsNotifier.new,
    );
