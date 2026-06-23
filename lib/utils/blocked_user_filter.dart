import '../models/nested_topic.dart';
import '../models/notification.dart';
import '../models/topic.dart';

/// 本地内容屏蔽名单的匹配与数据过滤。
///
/// 名单只由 [AppPreferences] 持久化在当前设备；这里绝不向 Discourse
/// 发出 mute / ignore 请求。所有用户名以 trim + lowercase 的精确匹配处理。
class BlockedUserFilter {
  BlockedUserFilter._();

  /// 用户名输入框无需填写 Discourse 展示时常见的 `@` 前缀。
  ///
  /// 兼容用户误输入 `@alice` 的情况，持久化和匹配均使用不带前缀的用户名。
  static String stripAtPrefix(String username) {
    final trimmed = username.trim();
    return trimmed.startsWith('@') ? trimmed.substring(1).trim() : trimmed;
  }

  static String normalizeUsername(String username) =>
      stripAtPrefix(username).toLowerCase();

  /// 去空、按大小写无关的用户名去重，同时保留第一条输入的显示形式。
  static List<String> sanitizeUsernames(Iterable<String> usernames) {
    final seen = <String>{};
    final result = <String>[];
    for (final username in usernames) {
      final cleaned = stripAtPrefix(username);
      final normalized = normalizeUsername(cleaned);
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      result.add(cleaned);
    }
    return result;
  }

  static Set<String> normalizedUsernames(Iterable<String> usernames) {
    return Set.unmodifiable(
      usernames.map(normalizeUsername).where((username) => username.isNotEmpty),
    );
  }

  static bool isBlockedUsername(
    String? username,
    Set<String> blockedUsernames,
  ) {
    if (username == null || blockedUsernames.isEmpty) return false;
    return blockedUsernames.contains(normalizeUsername(username));
  }

  /// 话题列表的 posters[0] 是 Discourse 返回的 Original Poster。
  /// 无法确定楼主时宁可保留话题，避免把别人的话题误判为屏蔽对象。
  static bool isBlockedTopic(Topic topic, Set<String> blockedUsernames) {
    if (blockedUsernames.isEmpty || topic.posters.isEmpty) return false;
    return isBlockedUsername(
      topic.posters.first.user?.username,
      blockedUsernames,
    );
  }

  static List<Topic> visibleTopics(
    Iterable<Topic> topics,
    Set<String> blockedUsernames,
  ) {
    if (blockedUsernames.isEmpty) return List<Topic>.from(topics);
    return topics
        .where((topic) => !isBlockedTopic(topic, blockedUsernames))
        .toList(growable: false);
  }

  static List<Post> visiblePosts(
    Iterable<Post> posts,
    Set<String> blockedUsernames,
  ) {
    if (blockedUsernames.isEmpty) return List<Post>.from(posts);
    return posts
        .where((post) => !isBlockedUsername(post.username, blockedUsernames))
        .toList(growable: false);
  }

  static List<Boost> visibleBoosts(
    Iterable<Boost> boosts,
    Set<String> blockedUsernames,
  ) {
    if (blockedUsernames.isEmpty) return List<Boost>.from(boosts);
    return boosts
        .where(
          (boost) => !isBlockedUsername(boost.user.username, blockedUsernames),
        )
        .toList(growable: false);
  }

  static bool isBlockedNotification(
    DiscourseNotification notification,
    Set<String> blockedUsernames,
  ) {
    return isBlockedUsername(notification.username, blockedUsernames) ||
        isBlockedUsername(
          notification.data.originalUsername,
          blockedUsernames,
        ) ||
        isBlockedUsername(notification.data.username2, blockedUsernames);
  }

  /// 树状视图中会把被屏蔽节点的已加载子节点提升到最近可见祖先，
  /// 因此屏蔽某条回复不会连带吞掉其他用户对它的回复。
  static List<NestedNode> visibleNestedNodes(
    Iterable<NestedNode> nodes,
    Set<String> blockedUsernames,
  ) {
    if (blockedUsernames.isEmpty) return List<NestedNode>.from(nodes);

    final result = <NestedNode>[];
    for (final node in nodes) {
      final children = visibleNestedNodes(node.children, blockedUsernames);
      if (isBlockedUsername(node.post.username, blockedUsernames)) {
        result.addAll(children);
      } else {
        result.add(node.copyWith(children: children));
      }
    }
    return result;
  }
}
