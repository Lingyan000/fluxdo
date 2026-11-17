import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/topic.dart';
import '../../../models/topic_post_excerpt.dart';

/// 话题某个位置（stream 索引，1 起）可展示的信息
@immutable
class TopicPositionInfo {
  const TopicPositionInfo({this.date, this.username, this.excerpt});

  /// 已加载楼层取精确发帖时间，否则由 timeline_lookup 估到天
  final DateTime? date;
  final String? username;
  final String? excerpt;
}

typedef TopicExcerptFetcher =
    Future<List<TopicPostExcerpt>> Function(int topicId, List<int> postIds);

/// 话题任意位置的信息来源，底栏拖动定位气泡与时间线共用。
///
/// - 日期：已加载帖子取 createdAt，否则查 [TopicDetail.timelineLookup]
/// - 摘要：已加载帖子取 cooked 纯文本，否则防抖后按需拉取目标前后
///   [_window] 楼的摘要并缓存；拉到后 [notifyListeners]
class TopicPositionInfoSource extends ChangeNotifier {
  TopicPositionInfoSource({
    required this.topicId,
    required this.detailGetter,
    required this.fetchExcerpts,
  });

  final int topicId;

  /// 现取最新的（与列表同口径的）话题详情
  final TopicDetail? Function() detailGetter;
  final TopicExcerptFetcher fetchExcerpts;

  /// 单次拉取目标前后各多少楼（与官方前端一致）
  static const int _window = 20;
  static const Duration _debounce = Duration(milliseconds: 120);
  static const int _excerptMaxLength = 160;

  final Map<int, TopicPostExcerpt> _remote = {};
  final Map<int, String> _localText = {};
  Timer? _debounceTimer;
  bool _loading = false;
  int? _pendingIndex;
  bool _disposed = false;

  TopicDetail? get detail => detailGetter();

  int get totalCount => detail?.postStream.stream.length ?? 0;

  /// 上次阅读位置（stream 索引）；未登录或不在当前 stream 中为 null
  int? get lastReadIndex {
    final d = detail;
    final id = d?.lastReadPostId;
    if (d == null || id == null) return null;
    final index = d.postStream.stream.indexOf(id);
    return index < 0 ? null : index + 1;
  }

  Post? _loadedPost(TopicDetail d, int postId) {
    for (final post in d.postStream.posts) {
      if (post.id == postId) return post;
    }
    return null;
  }

  /// 仅日期（时间线刻度等高频场景用，不触发摘要拉取）
  DateTime? dateAt(int index) {
    final d = detail;
    if (d == null) return null;
    final stream = d.postStream.stream;
    if (index < 1 || index > stream.length) return null;
    final post = _loadedPost(d, stream[index - 1]);
    return post?.createdAt ?? d.timelineLookup.dateAt(index);
  }

  /// 位置信息；[loadExcerpt] 为 true 时未命中摘要会安排一次拉取
  TopicPositionInfo infoAt(int index, {bool loadExcerpt = true}) {
    final d = detail;
    if (d == null) return const TopicPositionInfo();
    final stream = d.postStream.stream;
    if (index < 1 || index > stream.length) return const TopicPositionInfo();
    final postId = stream[index - 1];

    final post = _loadedPost(d, postId);
    if (post != null) {
      final text = _localText.putIfAbsent(
        postId,
        () => TopicPostExcerpt.plainTextFromHtml(
          post.cooked,
          maxLength: _excerptMaxLength,
        ),
      );
      return TopicPositionInfo(
        date: post.createdAt,
        username: post.username,
        excerpt: text.isEmpty ? null : text,
      );
    }

    final remote = _remote[postId];
    if (remote == null && loadExcerpt) _schedule(index);
    return TopicPositionInfo(
      date: d.timelineLookup.dateAt(index),
      username: remote?.username,
      excerpt: remote == null || remote.text.isEmpty ? null : remote.text,
    );
  }

  void _schedule(int index) {
    _pendingIndex = index;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _flush);
  }

  Future<void> _flush() async {
    final index = _pendingIndex;
    final d = detail;
    if (_loading || index == null || d == null || _disposed) return;
    final stream = d.postStream.stream;
    final from = (index - 1 - _window).clamp(0, stream.length);
    final to = (index - 1 + _window).clamp(0, stream.length);
    final ids = [
      for (final id in stream.sublist(from, to))
        if (!_remote.containsKey(id)) id,
    ];
    if (ids.isEmpty) return;

    _loading = true;
    try {
      final excerpts = await fetchExcerpts(topicId, ids);
      if (_disposed) return;
      for (final excerpt in excerpts) {
        _remote[excerpt.postId] = excerpt;
      }
      // 服务端不返回的（隐藏 / 已删除）记空占位，避免反复请求
      for (final id in ids) {
        _remote.putIfAbsent(
          id,
          () => TopicPostExcerpt(postId: id, username: null, text: ''),
        );
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[TopicPositionInfo] 拉取摘要失败: $e');
    } finally {
      _loading = false;
    }
    // 拉取期间目标又移到了窗口外：补拉一次
    final latest = _pendingIndex;
    final latestDetail = detail;
    if (!_disposed &&
        latest != null &&
        latest != index &&
        latestDetail != null &&
        latest <= latestDetail.postStream.stream.length &&
        !_remote.containsKey(latestDetail.postStream.stream[latest - 1])) {
      unawaited(_flush());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
