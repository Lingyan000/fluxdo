/// 话题链接解析结果
class TopicLinkInfo {
  final int topicId;
  final String? slug;
  final int? postNumber;

  const TopicLinkInfo({required this.topicId, this.slug, this.postNumber});
}

/// 用户链接解析结果
class UserLinkInfo {
  final String username;

  const UserLinkInfo({required this.username});
}

/// 分类链接解析结果。
class CategoryLinkInfo {
  const CategoryLinkInfo({required this.categoryId});

  final int categoryId;
}

/// 聊天链接解析结果(/chat/c/:slug/:channelId[/t/:threadId][/:messageId])
class ChatLinkInfo {
  final int channelId;
  final int? threadId;
  final int? messageId;

  const ChatLinkInfo({required this.channelId, this.threadId, this.messageId});
}

class DiscourseUrlParser {
  DiscourseUrlParser._();

  /// 纯数字 ID 格式：/t/12345 或 /t/12345/1
  /// 必须优先匹配，否则 /t/12345/1 中的 12345 会被误当作 slug
  static final _topicIdOnlyRegex = RegExp(
    r'/t/(\d+)(?:/(\d+))?(?:[/?#]|$)',
    caseSensitive: false,
  );

  /// 带 slug 格式：/t/topic-slug/12345 或 /t/topic-slug/12345/1
  static final _topicWithSlugRegex = RegExp(
    r'/t/([^/]+)/(\d+)(?:/(\d+))?',
    caseSensitive: false,
  );

  /// 仅含 slug 格式：/t/some-slug（slug 不能以数字开头）
  static final _topicSlugOnlyRegex = RegExp(
    r'/t/([^/\d][^/?#]*)$',
    caseSensitive: false,
  );

  /// 用户链接格式：/u/username
  static final _userRegex = RegExp(r'/u/([^/?#]+)', caseSensitive: false);

  static final _categoryRegex = RegExp(
    r'/c/(?:[^/?#]+/)?(\d+)(?:[/?#]|$)',
    caseSensitive: false,
  );

  static final _tagRegex = RegExp(r'/tag/([^/?#]+)', caseSensitive: false);

  /// 聊天链接:官方 chat_message.url 口径
  /// - `/chat/c/:slug/:channelId/t/:threadId/:messageId?`(thread 内消息)
  /// - `/chat/c/:slug/:channelId/:messageId?`(频道消息;slug 常为 "-")
  static final _chatThreadRegex = RegExp(
    r'/chat/c/[^/?#]+/(\d+)/t/(\d+)(?:/(\d+))?(?:[/?#]|$)',
    caseSensitive: false,
  );
  static final _chatChannelRegex = RegExp(
    r'/chat/c/[^/?#]+/(\d+)(?:/(\d+))?(?:[/?#]|$)',
    caseSensitive: false,
  );

  /// 解析话题链接，返回 [TopicLinkInfo] 或 null
  ///
  /// 支持格式：
  /// - `/t/12345` → topicId=12345
  /// - `/t/12345/1` → topicId=12345, postNumber=1
  /// - `/t/topic-slug/12345` → topicId=12345, slug=topic-slug
  /// - `/t/topic-slug/12345/1` → topicId=12345, slug=topic-slug, postNumber=1
  static TopicLinkInfo? parseTopic(String url) {
    // 优先匹配纯数字 ID 格式
    final idOnlyMatch = _topicIdOnlyRegex.firstMatch(url);
    if (idOnlyMatch != null) {
      return TopicLinkInfo(
        topicId: int.parse(idOnlyMatch.group(1)!),
        postNumber: int.tryParse(idOnlyMatch.group(2) ?? ''),
      );
    }

    // 匹配带 slug 格式
    final withSlugMatch = _topicWithSlugRegex.firstMatch(url);
    if (withSlugMatch != null) {
      final slugStr = withSlugMatch.group(1)!;
      return TopicLinkInfo(
        topicId: int.parse(withSlugMatch.group(2)!),
        slug: slugStr != 'topic' ? slugStr : null,
        postNumber: int.tryParse(withSlugMatch.group(3) ?? ''),
      );
    }

    return null;
  }

  /// 解析仅含 slug 的话题链接（/t/some-slug），返回 slug 或 null
  ///
  /// 注意：此方法仅匹配没有数字 ID 的 slug 链接，
  /// 带 ID 的链接应使用 [parseTopic]。
  static String? parseTopicSlug(String url) {
    final match = _topicSlugOnlyRegex.firstMatch(url);
    return match?.group(1);
  }

  /// 解析用户链接，返回 [UserLinkInfo] 或 null
  static UserLinkInfo? parseUser(String url) {
    final match = _userRegex.firstMatch(url);
    if (match != null) {
      return UserLinkInfo(username: match.group(1)!);
    }
    return null;
  }

  static CategoryLinkInfo? parseCategory(String url) {
    final match = _categoryRegex.firstMatch(url);
    final id = int.tryParse(match?.group(1) ?? '');
    return id == null ? null : CategoryLinkInfo(categoryId: id);
  }

  static String? parseTag(String url) {
    final match = _tagRegex.firstMatch(url);
    final encoded = match?.group(1);
    return encoded == null ? null : Uri.decodeComponent(encoded);
  }

  /// 解析聊天链接,返回 [ChatLinkInfo] 或 null(thread 形态优先匹配,
  /// 否则 /t/:threadId 会被当成 messageId)
  static ChatLinkInfo? parseChat(String url) {
    final threadMatch = _chatThreadRegex.firstMatch(url);
    if (threadMatch != null) {
      return ChatLinkInfo(
        channelId: int.parse(threadMatch.group(1)!),
        threadId: int.parse(threadMatch.group(2)!),
        messageId: int.tryParse(threadMatch.group(3) ?? ''),
      );
    }
    final channelMatch = _chatChannelRegex.firstMatch(url);
    if (channelMatch != null) {
      return ChatLinkInfo(
        channelId: int.parse(channelMatch.group(1)!),
        messageId: int.tryParse(channelMatch.group(2) ?? ''),
      );
    }
    return null;
  }

  static bool isHomepage(String url) {
    final resolved = Uri.tryParse(url);
    if (resolved == null) return false;
    return (resolved.path.isEmpty || resolved.path == '/') &&
        resolved.query.isEmpty &&
        resolved.fragment.isEmpty;
  }

  /// 是否是用户链接（用于快速判断）
  static bool isUserLink(String url) {
    return _userRegex.hasMatch(url);
  }
}
