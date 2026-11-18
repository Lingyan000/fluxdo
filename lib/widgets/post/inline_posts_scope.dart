import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../models/topic.dart';

/// 帖子内联展开的帖子列表种类
enum InlinePostsKind {
  /// 底部展开的直接回复
  replies,

  /// 头部下方展开的父帖
  parents,
}

/// 帖子内联展开快照:展开状态、已加载的帖子与其中已展开全文的帖子
class InlinePostsSnapshot {
  final List<Post> posts;
  final bool expanded;
  final Set<int> unfoldedPostIds;

  const InlinePostsSnapshot({
    required this.posts,
    required this.expanded,
    this.unfoldedPostIds = const {},
  });
}

/// 一个话题页实例内的内联展开快照((种类, postId) → 快照)。
///
/// 帖子 header/footer 随 sliver 回收重建时读回,恢复展开状态与原高度。
/// 按页面实例 id 登记:页面 State 挂载时 [acquire]、销毁时 [release]。
/// 布局切换(全屏 ↔ 分栏)会以同一实例 id 重建页面,release 后宽限一段
/// 时间再丢弃,新 State 在宽限期内 acquire 即续用;重新打开话题是新的
/// 实例 id,拿到的是全新状态。
class InlinePostsStore {
  InlinePostsStore._();

  /// 与话题详情 provider 的保活宽限一致
  static const Duration _releaseGrace = Duration(seconds: 30);
  static final Map<String, _RegistryEntry> _registry = {};

  static InlinePostsStore acquire(String instanceId) {
    final entry = _registry.putIfAbsent(instanceId, _RegistryEntry.new);
    entry.releaseTimer?.cancel();
    entry.releaseTimer = null;
    entry.refCount++;
    return entry.store;
  }

  static void release(String instanceId) {
    final entry = _registry[instanceId];
    if (entry == null || --entry.refCount > 0) return;
    entry.releaseTimer = Timer(
      _releaseGrace,
      () => _registry.remove(instanceId),
    );
  }

  final Map<(InlinePostsKind, int), InlinePostsSnapshot> _snapshots = {};

  InlinePostsSnapshot? read(InlinePostsKind kind, int postId) =>
      _snapshots[(kind, postId)];

  void save(
    InlinePostsKind kind,
    int postId, {
    required List<Post> posts,
    required bool expanded,
    Set<int> unfoldedPostIds = const {},
  }) {
    if (posts.isEmpty && !expanded) {
      _snapshots.remove((kind, postId));
      return;
    }
    _snapshots[(kind, postId)] = InlinePostsSnapshot(
      posts: List.unmodifiable(posts),
      expanded: expanded,
      unfoldedPostIds: Set.unmodifiable(unfoldedPostIds),
    );
  }
}

class _RegistryEntry {
  final InlinePostsStore store = InlinePostsStore._();
  int refCount = 0;
  Timer? releaseTimer;
}

/// 把页面的 [InlinePostsStore] 提供给帖子组件。不在作用域内(回复弹层、
/// 个人页等)的帖子不保留展开状态。
class InlinePostsScope extends InheritedWidget {
  final InlinePostsStore store;

  const InlinePostsScope({
    super.key,
    required this.store,
    required super.child,
  });

  /// 只取不订阅:store 本身随页面固定,读写不需要触发重建,
  /// 也因此可以在 initState 里调用。
  static InlinePostsStore? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<InlinePostsScope>()?.store;

  @override
  bool updateShouldNotify(InlinePostsScope oldWidget) =>
      store != oldWidget.store;
}
