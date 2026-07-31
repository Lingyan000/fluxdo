/// Discourse 引用格式构建器
///
/// 生成 Discourse BBCode 风格的引用标记，用于回复时引用选中内容。
class QuoteBuilder {
  /// 显示名里的各类引号字符要整个剥掉，否则 `[quote="..."]` 的属性串会被
  /// 提前截断产出非法 bbcode。字符集与官方 buildQuote 用的
  /// QUOTATION_MARKS 一致（discourse: lib/quote.js + features/bbcode-block.js）。
  static final RegExp _quotationMarks = RegExp('["\'«»“”‘’„‚‹›]');

  /// 构建 Discourse 引用格式
  ///
  /// [markdown] 选中内容转换后的 Markdown 文本
  /// [displayName] 被引用帖子作者的显示名（昵称），直接传 `post.name` 即可：
  ///   为 null/空时首字段自动退回 [username]，与官方 buildQuote 的
  ///   prioritizeNameFallback 行为一致。
  /// [username] 被引用帖子作者的登录用户名。有显示名时单独放 `username:`
  ///   参数——首字段官方语义是显示名，服务端靠 `username:` 查真实用户，
  ///   否则引用标题栏没有头像/跳转链接。
  /// [postNumber] 被引用帖子的楼层号
  /// [topicId] 话题 ID
  ///
  /// 返回格式（有显示名时；无显示名则首字段为 username 且不带 `username:` 参数）：
  /// ```
  /// [quote="displayName, post:N, topic:T, username:username"]
  /// markdown
  /// [/quote]
  ///
  /// ```
  static String build({
    required String markdown,
    String? displayName,
    required String username,
    required int postNumber,
    required int topicId,
  }) {
    final content = markdown.trim();
    final name = (displayName ?? '').replaceAll(_quotationMarks, '').trim();
    final header = name.isNotEmpty
        ? '$name, post:$postNumber, topic:$topicId, username:$username'
        : '$username, post:$postNumber, topic:$topicId';
    return '[quote="$header"]\n$content\n[/quote]\n\n';
  }
}
