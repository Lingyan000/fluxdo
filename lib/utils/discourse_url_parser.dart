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

  /// 标签链接:`/tag/<名字>`,数字型名字的标签 Discourse 会带上 id 段
  /// (`/tag/1534-tag/1534`,跟分类 `/c/slug/id` 同形态)。**id 段必须
  /// 一起截下来** —— 只取第一段拼出的 `/tag/1534-tag/l/latest.json`
  /// 服务端 404(实测)。
  static final _tagRegex = RegExp(
    r'/tag/([^/?#]+(?:/\d+)?)',
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

  /// 标签的展示名:去掉 [parseTag] 保留的 id 段(`1534-tag/1534` →
  /// `1534-tag`)。只用于显示,请求路径必须用带 id 的原串。
  static String tagDisplayName(String tag) {
    final slash = tag.lastIndexOf('/');
    if (slash <= 0) return tag;
    final tail = tag.substring(slash + 1);
    return int.tryParse(tail) == null ? tag : tag.substring(0, slash);
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
