import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/s.dart';
import '../models/topic.dart';
import '../models/pending_post.dart';
import '../models/user.dart';
import '../services/preloaded_data_service.dart';
import '../widgets/common/anchor_guard_sliver.dart';
import 'core_providers.dart';
import 'message_bus/models.dart';

part 'topic_detail/_loading_methods.dart';
part 'topic_detail/_filter_methods.dart';
part 'topic_detail/_post_updates.dart';
part 'topic_detail/_gap_methods.dart';

/// 话题详情参数
/// 使用 instanceId 确保每次打开页面都是独立的 provider 实例
/// 解决：打开话题 -> 点击用户 -> 再进入同一话题时应该是新的页面状态
class TopicDetailParams {
  final int topicId;
  final int? postNumber;
  /// 唯一实例 ID，确保每次打开页面都创建新的 provider 实例
  /// 默认为空字符串，用于 MessageBus 等不需要精确匹配的场景
  final String instanceId;

  const TopicDetailParams(this.topicId, {this.postNumber, this.instanceId = ''});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicDetailParams &&
          topicId == other.topicId &&
          instanceId == other.instanceId;

  @override
  int get hashCode => Object.hash(topicId, instanceId);
}

/// 话题详情 Notifier (支持双向加载)
class TopicDetailNotifier extends AsyncNotifier<TopicDetail> {
  TopicDetailNotifier(this.arg);
  final TopicDetailParams arg;

  /// 活跃实例注册表:topicId → 该话题当前存活的 provider 参数(后注册在后)。
  ///
  /// 页面实例的 params 携带 UUID instanceId,深层组件(帖脚的 boost/
  /// reaction 本地操作落地)只知道 topicId —— 直接 new 一个空 instanceId
  /// 的 params 与页面实例不相等,只会凭空创建并 fetch 一个孤儿实例,
  /// 更新永远落不到在显示的那份数据上。经注册表找回真实实例。
  static final Map<int, List<TopicDetailParams>> _activeParams = {};

  /// 该话题最近激活的 provider 参数(同话题叠开多页时取最上层);无活跃
  /// 实例(如个人页等无话题上下文)返回 null,调用方自行跳过同步。
  static TopicDetailParams? activeParamsFor(int topicId) =>
      _activeParams[topicId]?.lastOrNull;

  bool _hasMoreAfter = true;
  bool _hasMoreBefore = true;

  /// 分页状态改由 ValueNotifier 驱动:加载指示器/重试按钮由列表内
  /// ValueListenableBuilder 就地切换,分页起止不再发射
  /// AsyncLoading.copyWithPrevious(那会触发整页 rebuild,滚动中掉帧)。
  final ValueNotifier<bool> loadingPreviousListenable = ValueNotifier(false);
  final ValueNotifier<bool> loadingMoreListenable = ValueNotifier(false);
  final ValueNotifier<bool> loadMoreFailedListenable = ValueNotifier(false);
  final ValueNotifier<bool> loadPreviousFailedListenable = ValueNotifier(false);

  // 私有 getter/setter 对:既有赋值点(_isLoadingMore = true 等)零改动。
  bool get _isLoadingPrevious => loadingPreviousListenable.value;
  set _isLoadingPrevious(bool v) => loadingPreviousListenable.value = v;
  bool get _isLoadingMore => loadingMoreListenable.value;
  set _isLoadingMore(bool v) => loadingMoreListenable.value = v;
  bool get _isLoadMoreFailed => loadMoreFailedListenable.value;
  set _isLoadMoreFailed(bool v) => loadMoreFailedListenable.value = v;
  bool get _isLoadPreviousFailed => loadPreviousFailedListenable.value;
  set _isLoadPreviousFailed(bool v) => loadPreviousFailedListenable.value = v;

  String? _filter;  // 当前过滤模式（如 'summary' 表示热门回复）
  String? _usernameFilter;  // 当前用户名过滤（如只看题主）
  bool _filterTopLevelReplies = false;  // 只看顶层回复
  /// 待加载的新帖子 ID 队列（对齐 Discourse _newPostsInStream）
  final List<int> _pendingNewPostIds = [];
  bool _isLoadingNewPosts = false;

  bool get hasMoreAfter => _hasMoreAfter;
  bool get hasMoreBefore => _hasMoreBefore;
  bool get isLoadingPrevious => _isLoadingPrevious;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;
  bool get isLoadPreviousFailed => _isLoadPreviousFailed;
  bool get isSummaryMode => _filter == 'summary';
  bool get isAuthorOnlyMode => _usernameFilter != null;
  bool get isTopLevelMode => _filterTopLevelReplies;
  bool get _isFilteredMode => _filter != null || _usernameFilter != null || _filterTopLevelReplies;

  /// 根据 posts 和 stream 统一计算边界状态
  ///
  /// 所有需要更新 hasMoreBefore/hasMoreAfter 的地方都应该调用此方法，
  /// 确保判断逻辑的一致性。
  void _updateBoundaryState(List<Post> posts, List<int> stream) {
    if (posts.isEmpty || stream.isEmpty) {
      _hasMoreBefore = false;
      _hasMoreAfter = false;
      return;
    }

    final firstPostId = posts.first.id;
    final firstIndex = stream.indexOf(firstPostId);
    _hasMoreBefore = firstIndex > 0;

    final lastPostId = posts.last.id;
    final lastIndex = stream.indexOf(lastPostId);
    _hasMoreAfter = lastIndex != -1 && lastIndex < stream.length - 1;
  }

  /// 更新单个帖子的辅助方法
  void _updatePostById(int postId, Post Function(Post) updater) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final oldPost = currentPosts[index];
    final newPost = updater(oldPost);

    // 数据没变则跳过，避免触发不必要的 rebuild
    if (oldPost == newPost) return;

    // 单帖状态落地(msgbus liked/boost 本地更新等):武装锚定哨兵,
    // 视口上方帖子的高度位移在下一帧被同帧补偿。用户主动操作(自己
    // 点赞/书签)也会经过这里 —— 无害:被操作的帖子必然可见,高度
    // 变化发生在锚(视口上沿 segment)的盒内或下方,锚不动、不修正。
    AnchorGuardSliver.arm();

    final newPosts = [...currentPosts];
    newPosts[index] = newPost;

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream, gaps: currentDetail.postStream.gaps),
    ));
  }

  @override
  Future<TopicDetail> build() async {
    debugPrint('[TopicDetailNotifier] build called with topicId=${arg.topicId}, postNumber=${arg.postNumber}');

    // 注册活跃实例(见 _activeParams);autoDispose 时反注册。
    // build 重跑(refresh)会重复进入,先去重再追加保持"最近激活在尾"。
    final registered = _activeParams.putIfAbsent(arg.topicId, () => []);
    registered.remove(arg);
    registered.add(arg);
    ref.onDispose(() {
      final list = _activeParams[arg.topicId];
      if (list == null) return;
      list.remove(arg);
      if (list.isEmpty) _activeParams.remove(arg.topicId);
    });

    // 保持存活，防止布局切换的短暂间隙被 autoDispose 清理
    // 使用 onCancel/onResume 模式：最后一个 watcher 移除后才开始倒计时
    final link = ref.keepAlive();
    Timer? disposeTimer;
    ref.onCancel(() {
      // 最后一个 watcher 移除后，延迟 30 秒再允许 dispose
      disposeTimer = Timer(const Duration(seconds: 30), link.close);
    });
    ref.onResume(() {
      // 新的 watcher 出现，取消清理定时器
      disposeTimer?.cancel();
    });
    ref.onDispose(() {
      disposeTimer?.cancel();
    });

    _hasMoreAfter = true;
    _hasMoreBefore = true;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;
    final service = ref.read(discourseServiceProvider);
    final detail = await service.getTopicDetail(arg.topicId, postNumber: arg.postNumber, trackVisit: true);

    _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

    return detail;
  }
}

final topicDetailProvider = AsyncNotifierProvider.family.autoDispose<TopicDetailNotifier, TopicDetail, TopicDetailParams>(
  TopicDetailNotifier.new,
);

/// 话题 AI 摘要 Provider
final topicSummaryProvider = StreamProvider.autoDispose
    .family<TopicSummary?, int>((ref, topicId) {
  final service = ref.read(discourseServiceProvider);
  return service.watchTopicSummary(topicId);
});
