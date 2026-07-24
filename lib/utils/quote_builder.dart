/// Discourse 引用格式构建器
///
/// 生成 Discourse BBCode 风格的引用标记，用于回复时引用选中内容。
class QuoteBuilder {
  /// 构建 Discourse 引用格式
  ///
  /// [markdown] 选中内容转换后的 Markdown 文本
  /// [displayName] 被引用帖子作者的显示名(昵称;未设置昵称时调用方应传
  ///   username 本身)——首字段官方语义是**显示名**,不是登录用户名。
  /// [username] 被引用帖子作者的登录用户名,单独放 `username:` 参数;
  ///   引用标题的头像/跳转链接是靠这个字段查真实用户的,只把用户名塞进
  ///   首字段、不带这个参数,真机复现引用发送后标题栏没有链接(服务端
  ///   按首字段当纯显示文本处理,查不到人)。
  /// [postNumber] 被引用帖子的楼层号
  /// [topicId] 话题 ID
  ///
  /// 返回格式：
  /// ```
  /// [quote="displayName, post:N, topic:T, username:username"]
  /// markdown
  /// [/quote]
  ///
  /// ```
  static String build({
    required String markdown,
    required String displayName,
    required String username,
    required int postNumber,
    required int topicId,
  }) {
    final content = markdown.trim();
    return '[quote="$displayName, post:$postNumber, topic:$topicId, username:$username"]\n$content\n[/quote]\n\n';
  }
}
