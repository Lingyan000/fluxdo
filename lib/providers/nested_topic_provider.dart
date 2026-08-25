import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/nested_topic.dart';
import '../models/topic.dart';
import '../services/discourse/discourse_service.dart';
import '../services/preloaded_data_service.dart';
import 'core_providers.dart';

/// 嵌套视图参数
class NestedTopicParams {
  final int topicId;

  /// 非空时进入 context 定位模式（通知等带楼层进入）:
  /// 只加载祖先链 → 目标帖 → 子树,不加载根帖子列表
  final int? targetPostNumber;

  const NestedTopicParams({required this.topicId, this.targetPostNumber});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NestedTopicParams &&
          topicId == other.topicId &&
          targetPostNumber == other.targetPostNumber;

  @override
  int get hashCode => Object.hash(topicId, targetPostNumber);
}

/// 嵌套视图状态
class NestedTopicState {
  final Map<String, dynamic>? topicJson;
  final Post? opPost;
  final List<NestedNode> roots;
  final bool hasMoreRoots;
  final int currentPage;
  final String sort;
  final List<int> pinnedPostIds;
  final bool isLoadingMore;
  final List<int> newRootPostIds;
  final NestedChildCreatedEvent? lastChildCreated;

  /// context 定位模式（通知带楼层进入）
  final bool contextMode;

  /// 祖先逐层包裹目标帖构成的单链根节点（仅 context 模式）
  final NestedNode? contextChain;

  /// 定位的目标楼层号（仅 context 模式）
  final int? targetPostNumber;

  /// 祖先链被 max_depth 截断,还有更早的上下文可看
  final bool ancestorsTruncated;

  /// 当前链最顶端祖先的楼层号（「查看更早的上下文」跳转目标）
  final int? topAncestorPostNumber;

  const NestedTopicState({
    this.topicJson,
    this.opPost,
    this.roots = const [],
    this.hasMoreRoots = false,
    this.currentPage = 0,
    this.sort = 'old',
    this.pinnedPostIds = const [],
    this.isLoadingMore = false,
    this.newRootPostIds = const [],
    this.lastChildCreated,
    this.contextMode = false,
    this.contextChain,
    this.targetPostNumber,
    this.ancestorsTruncated = false,
    this.topAncestorPostNumber,
  });

  String get title => topicJson?['title'] as String? ?? '';

  NestedTopicState copyWith({
    Map<String, dynamic>? topicJson,
    Post? opPost,
    List<NestedNode>? roots,
    bool? hasMoreRoots,
    int? currentPage,
    String? sort,
    List<int>? pinnedPostIds,
    bool? isLoadingMore,
    List<int>? newRootPostIds,
    NestedChildCreatedEvent? lastChildCreated,
    bool clearLastChildCreated = false,
    bool? contextMode,
    NestedNode? contextChain,
    int? targetPostNumber,
    bool? ancestorsTruncated,
    int? topAncestorPostNumber,
  }) {
    return NestedTopicState(
      topicJson: topicJson ?? this.topicJson,
      opPost: opPost ?? this.opPost,
      roots: roots ?? this.roots,
      hasMoreRoots: hasMoreRoots ?? this.hasMoreRoots,
      currentPage: currentPage ?? this.currentPage,
      sort: sort ?? this.sort,
      pinnedPostIds: pinnedPostIds ?? this.pinnedPostIds,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      newRootPostIds: newRootPostIds ?? this.newRootPostIds,
      lastChildCreated: clearLastChildCreated
          ? null
          : (lastChildCreated ?? this.lastChildCreated),
      contextMode: contextMode ?? this.contextMode,
      contextChain: contextChain ?? this.contextChain,
      targetPostNumber: targetPostNumber ?? this.targetPostNumber,
      ancestorsTruncated: ancestorsTruncated ?? this.ancestorsTruncated,
      topAncestorPostNumber:
          topAncestorPostNumber ?? this.topAncestorPostNumber,
    );
  }
}

/// 嵌套视图 Notifier
class NestedTopicNotifier extends AsyncNotifier<NestedTopicState> {
  NestedTopicNotifier(this.arg);
  final NestedTopicParams arg;

  @override
  Future<NestedTopicState> build() async {
    final service = ref.read(discourseServiceProvider);

    final target = arg.targetPostNumber;
    if (target != null) {
      return _loadContext(service, target, sort: 'old', trackVisit: true);
    }

    final response = await service.getNestedRoots(
      arg.topicId,
      sort: 'old',
      page: 0,
      trackVisit: true,
    );

    return NestedTopicState(
      topicJson: response.topicJson,
      opPost: response.opPost,
      roots: response.roots,
      hasMoreRoots: response.hasMoreRoots,
      currentPage: 0,
      sort: response.sort ?? 'old',
      pinnedPostIds: response.pinnedPostIds,
    );
  }

  /// 加载 context 定位数据并组装状态
  Future<NestedTopicState> _loadContext(
    DiscourseService service,
    int targetPostNumber, {
    required String sort,
    bool trackVisit = false,
  }) async {
    final response = await service.getNestedContext(
      arg.topicId,
      targetPostNumber,
      sort: sort,
      trackVisit: trackVisit,
    );
    final chain = response.buildContextChain();
    return NestedTopicState(
      topicJson: response.topicJson,
      opPost: response.opPost,
      sort: sort,
      contextMode: true,
      contextChain: chain,
      targetPostNumber: targetPostNumber,
      ancestorsTruncated: response.ancestorsTruncated,
      topAncestorPostNumber: response.ancestorChain.isNotEmpty
          ? response.ancestorChain.first.postNumber
          : null,
    );
  }

  /// 加载更多根帖子
  Future<void> loadMoreRoots() async {
    final current = state.value;
    if (current == null ||
        current.contextMode ||
        !current.hasMoreRoots ||
        current.isLoadingMore) {
      return;
    }

    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    state = AsyncValue.data(current.copyWith(isLoadingMore: true));

    try {
      final service = ref.read(discourseServiceProvider);
      final nextPage = current.currentPage + 1;
      final response = await service.getNestedRoots(
        arg.topicId,
        sort: current.sort,
        page: nextPage,
      );

      if (!ref.mounted) return;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state = AsyncValue.data(
        current.copyWith(
          roots: [...current.roots, ...response.roots],
          hasMoreRoots: response.hasMoreRoots,
          currentPage: nextPage,
          isLoadingMore: false,
        ),
      );
    } catch (e) {
      debugPrint('[NestedTopic] loadMoreRoots failed: $e');
      if (!ref.mounted) return;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state = AsyncValue.data(current.copyWith(isLoadingMore: false));
    }
  }

  /// 切换排序
  Future<void> changeSort(String newSort) async {
    final current = state.value;
    if (current == null || current.sort == newSort) return;

    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    state = const AsyncValue.loading();

    try {
      final service = ref.read(discourseServiceProvider);

      // context 模式:排序影响子树顺序,重新拉取 context
      if (current.contextMode && current.targetPostNumber != null) {
        final next = await _loadContext(
          service,
          current.targetPostNumber!,
          sort: newSort,
        );
        if (!ref.mounted) return;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        state = AsyncValue.data(next);
        return;
      }

      final response = await service.getNestedRoots(
        arg.topicId,
        sort: newSort,
        page: 0,
      );

      if (!ref.mounted) return;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state = AsyncValue.data(
        NestedTopicState(
          topicJson: current.topicJson,
          opPost: current.opPost,
          roots: response.roots,
          hasMoreRoots: response.hasMoreRoots,
          currentPage: 0,
          sort: newSort,
          pinnedPostIds: response.pinnedPostIds,
        ),
      );
    } catch (e, s) {
      if (!ref.mounted) return;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state = AsyncValue.error(e, s);
    }
  }

  /// 更新帖子的解决方案状态（树节点卡片重建时盖章不丢）
  ///
  /// 与平铺 [TopicDetailNotifier.updatePostSolution] 同语义:
  /// 单解决方案模式(`solved_allow_multiple_solutions=false`)接受新答案时清空其他。
  /// 懒加载的子节点挂在各卡片本地状态里、不在 provider 状态中,覆盖不到属正常
  /// (卡片本地 _acceptedAnswer 已即时反馈)。
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  void updatePostSolution(int postId, bool accepted) {
    final current = state.value;
    if (current == null) return;

    final allowMultiple =
        PreloadedDataService()
            .siteSettingsSync?['solved_allow_multiple_solutions'] ==
        true;

    Post mapPost(Post post) {
      if (post.id == postId) {
        return post.copyWith(
          acceptedAnswer: accepted,
          canUnacceptAnswer: accepted,
        );
      } else if (accepted && !allowMultiple && post.acceptedAnswer) {
        return post.copyWith(acceptedAnswer: false, canUnacceptAnswer: false);
      }
      return post;
    }

    NestedNode mapNode(NestedNode node) {
      final newPost = mapPost(node.post);
      if (node.children.isEmpty) {
        return identical(newPost, node.post)
            ? node
            : node.copyWith(post: newPost);
      }
      return node.copyWith(
        post: newPost,
        children: node.children.map(mapNode).toList(),
      );
    }

    final opPost = current.opPost;
    state = AsyncValue.data(
      current.copyWith(
        opPost: opPost == null ? null : mapPost(opPost),
        roots: current.roots.map(mapNode).toList(),
        contextChain: current.contextChain == null
            ? null
            : mapNode(current.contextChain!),
      ),
    );
  }

  /// 懒加载子回复
  Future<NestedChildrenResponse> loadChildren(
    int postNumber, {
    int page = 0,
    int depth = 1,
  }) async {
    final current = state.value;
    final service = ref.read(discourseServiceProvider);
    return service.getNestedChildren(
      arg.topicId,
      postNumber,
      sort: current?.sort ?? 'old',
      page: page,
      depth: depth,
    );
  }

  /// 添加新帖子（自己回复或 MessageBus 创建）
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  void addNewPost(Post post, {required bool isOwnPost}) {
    final current = state.value;
    if (current == null) return;

    // 去重
    if (current.roots.any((n) => n.post.id == post.id)) return;

    final replyTo = post.replyToPostNumber;
    final isRoot = replyTo <= 0 || replyTo == 1;

    if (isRoot) {
      // context 模式不渲染根列表,新根回复无处插入,忽略
      if (current.contextMode) return;
      if (isOwnPost) {
        final newNode = NestedNode(post: post);
        state = AsyncValue.data(
          current.copyWith(roots: [newNode, ...current.roots]),
        );
      } else {
        if (current.newRootPostIds.contains(post.id)) return;
        state = AsyncValue.data(
          current.copyWith(
            newRootPostIds: [...current.newRootPostIds, post.id],
          ),
        );
      }
    } else {
      state = AsyncValue.data(
        current.copyWith(
          lastChildCreated: NestedChildCreatedEvent(
            post: post,
            parentPostNumber: replyTo,
          ),
        ),
      );
    }
  }

  /// 加载他人新发的根回复
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  Future<void> loadNewRoots() async {
    final current = state.value;
    if (current == null ||
        current.contextMode ||
        current.newRootPostIds.isEmpty) {
      return;
    }

    final ids = List<int>.from(current.newRootPostIds);
    state = AsyncValue.data(current.copyWith(newRootPostIds: []));

    try {
      final service = ref.read(discourseServiceProvider);
      final newNodes = <NestedNode>[];
      for (final id in ids) {
        try {
          final post = await service.getPost(id);
          newNodes.add(NestedNode(post: post));
        } catch (e) {
          debugPrint('[NestedTopic] loadNewRoots: 加载帖子 $id 失败: $e');
        }
      }
      if (!ref.mounted || newNodes.isEmpty) return;

      final updated = state.value;
      if (updated == null) return;
      final existingIds = updated.roots.map((n) => n.post.id).toSet();
      final filtered = newNodes
          .where((n) => !existingIds.contains(n.post.id))
          .toList();
      if (filtered.isEmpty) return;

      state = AsyncValue.data(
        updated.copyWith(roots: [...filtered, ...updated.roots]),
      );
    } catch (e) {
      debugPrint('[NestedTopic] loadNewRoots failed: $e');
    }
  }

  /// 清除子回复创建事件（消费后调用）
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  void clearLastChildCreated() {
    final current = state.value;
    if (current == null || current.lastChildCreated == null) return;
    state = AsyncValue.data(current.copyWith(clearLastChildCreated: true));
  }
}

final nestedTopicProvider = AsyncNotifierProvider.family
    .autoDispose<NestedTopicNotifier, NestedTopicState, NestedTopicParams>(
      NestedTopicNotifier.new,
    );
