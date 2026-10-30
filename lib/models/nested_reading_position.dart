import 'nested_topic.dart';

/// 树形阅读的落点独立于服务端最高已读楼层，允许往回阅读。
class NestedReadingPosition {
  const NestedReadingPosition({
    required this.postNumber,
    required this.rootPostNumber,
    this.offset = 0,
    this.sort = 'old',
    this.expanded = const {},
  });

  final int postNumber;
  final int rootPostNumber;

  /// 帖子顶部相对阅读区域顶部的位置，可为负（长帖读到中段）。
  final double offset;
  final String sort;
  final Map<int, bool> expanded;

  Map<String, dynamic> toJson() => {
    'post': postNumber,
    'root': rootPostNumber,
    'offset': offset,
    'sort': sort,
    'expanded': expanded.map((key, value) => MapEntry('$key', value)),
  };

  static NestedReadingPosition? fromJson(Map<String, dynamic> json) {
    final post = json['post'];
    final root = json['root'];
    final offset = json['offset'];
    if (post is! int || post < 1 || root is! int || root < 1) return null;
    return NestedReadingPosition(
      postNumber: post,
      rootPostNumber: root,
      offset: offset is num && offset.isFinite ? offset.toDouble() : 0,
      sort: nestedSort(json['sort']),
      expanded: {
        if (json['expanded'] is Map)
          for (final entry in (json['expanded'] as Map).entries)
            if (int.tryParse('${entry.key}') != null && entry.value is bool)
              int.parse('${entry.key}'): entry.value as bool,
      },
    );
  }
}

String nestedSort(Object? sort) =>
    const ['old', 'new', 'top'].contains(sort) ? sort as String : 'old';

/// 同一页面实例临时离开时保留完整现场；不写入磁盘。
class NestedReadingSession {
  NestedReadingPosition? position;
  NestedReadingPosition? browsePosition;
  int? contextTarget;
  double scrollOffset = 0;
  String sort = 'old';
  bool enabled = true;
  final Map<int, bool> expanded = {};
  final Map<int, NestedBranchState> branches = {};
}

class NestedBranchState {
  NestedBranchState({
    required this.children,
    required this.hasMore,
    this.page = 0,
    this.visibleCount = 3,
    this.pendingChildren = const [],
  });
  List<NestedNode> children;
  bool hasMore;
  int page;
  int visibleCount;
  List<NestedNode> pendingChildren;
}
