import 'dart:io';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../l10n/s.dart';
import '../models/topic.dart';
import '../services/discourse/discourse_service.dart';
import '../constants.dart';
import 'share_utils.dart';

/// 导出范围
enum ExportScope {
  /// 仅主帖
  firstPostOnly,
  /// 全部帖子
  allPosts,
}

/// 导出格式
enum ExportFormat {
  markdown('Markdown', 'md'),
  html('HTML', 'html');

  const ExportFormat(this.displayName, this.extension);
  final String displayName;
  final String extension;
}

/// 导出工具类
class ExportUtils {
  ExportUtils._();

  static final DiscourseService _service = DiscourseService();

  /// Markdown 导出最大帖子数限制（需要逐个请求原始内容）
  static const int maxMarkdownPosts = 10;

  /// 批量获取帖子的每批数量
  static const int _batchSize = 20;

  /// 请求间隔（毫秒）
  static const int _requestDelayMs = 300;

  /// 导出话题
  /// [detail] - 话题详情（包含 postStream.stream 全部帖子 ID）
  /// [scope] - 导出范围
  /// [format] - 导出格式
  /// [onProgress] - 进度回调 (current, total)
  /// 返回实际导出的帖子数量
  static Future<int> exportTopic({
    required TopicDetail detail,
    required ExportScope scope,
    required ExportFormat format,
    void Function(int current, int total)? onProgress,
  }) async {
    // 获取需要导出的帖子 ID 列表
    List<int> postIds;
    if (scope == ExportScope.firstPostOnly) {
      // 仅主帖：取 stream 中的第一个
      if (detail.postStream.stream.isEmpty) {
        throw Exception(S.current.export_noPostsToExport);
      }
      postIds = [detail.postStream.stream.first];
    } else {
      // 全部帖子
      postIds = List.from(detail.postStream.stream);
    }

    if (postIds.isEmpty) {
      throw Exception(S.current.export_noPostsToExport);
    }

    // Markdown 格式限制最多导出前 N 条（因为需要逐个请求原始内容）
    if (format == ExportFormat.markdown && postIds.length > maxMarkdownPosts) {
      postIds = postIds.take(maxMarkdownPosts).toList();
    }

    // 批量获取帖子数据
    final posts = await _fetchPosts(
      topicId: detail.id,
      postIds: postIds,
      onProgress: format == ExportFormat.html ? onProgress : null,
    );

    if (posts.isEmpty) {
      throw Exception(S.current.export_fetchPostsFailed);
    }

    String content;
    switch (format) {
      case ExportFormat.markdown:
        content = await _exportToMarkdown(detail, posts, onProgress);
        break;
      case ExportFormat.html:
        content = _exportToHtml(detail, posts);
        break;
    }

    await _shareAsFile(content, detail.title, format.extension);
    return posts.length;
  }

  /// 批量获取帖子数据
  static Future<List<Post>> _fetchPosts({
    required int topicId,
    required List<int> postIds,
    void Function(int current, int total)? onProgress,
  }) async {
    final allPosts = <Post>[];
    final total = postIds.length;

    // 分批获取
    for (int i = 0; i < postIds.length; i += _batchSize) {
      if (i > 0) {
        await Future.delayed(const Duration(milliseconds: _requestDelayMs));
      }

      final batchIds = postIds.skip(i).take(_batchSize).toList();
      try {
        final postStream = await _service.getPosts(topicId, batchIds);
        allPosts.addAll(postStream.posts);
        onProgress?.call(allPosts.length, total);
      } catch (e) {
        debugPrint('[ExportUtils] getPosts failed for batch starting at $i: $e');
        // 继续尝试下一批
      }
    }

    // 按 postNumber 排序
    allPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));
    return allPosts;
  }

  /// 导出为 Markdown
  static Future<String> _exportToMarkdown(
    TopicDetail detail,
    List<Post> posts,
    void Function(int current, int total)? onProgress,
  ) async {
    final buffer = StringBuffer();

    // 标题
    buffer.writeln('# ${detail.title}');
    buffer.writeln();
    buffer.writeln('> 来源: ${AppConstants.baseUrl}/t/${detail.slug}/${detail.id}');
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln();

    // 获取每个帖子的原始 Markdown
    for (int i = 0; i < posts.length; i++) {
      final post = posts[i];
      onProgress?.call(i + 1, posts.length);

      // 请求间隔，避免被服务器限流
      if (i > 0) {
        await Future.delayed(const Duration(milliseconds: _requestDelayMs));
      }

      // 帖子头部
      buffer.writeln('## #${post.postNumber} @${post.username}');
      buffer.writeln();

      // 尝试获取原始 Markdown，如果失败则使用 cooked
      String? raw;
      try {
        raw = await _service.getPostRaw(post.id);
      } catch (e) {
        debugPrint('[ExportUtils] getPostRaw failed for post ${post.id}: $e');
      }

      if (raw != null && raw.isNotEmpty) {
        buffer.writeln(raw);
      } else {
        // 降级：使用 HTML 内容（移除 HTML 标签）
        buffer.writeln(_stripHtml(post.cooked));
      }

      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 导出为 HTML
  static String _exportToHtml(TopicDetail detail, List<Post> posts) {
    final buffer = StringBuffer();

    // HTML 头部
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('<meta charset="UTF-8">');
    buffer.writeln('<meta name="viewport" content="width=device-width, initial-scale=1.0">');
    buffer.writeln('<title>${_escapeHtml(detail.title)}</title>');
    buffer.writeln('<style>');
    buffer.writeln(_htmlStyles);
    buffer.writeln('</style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');

    // 标题
    buffer.writeln('<header>');
    buffer.writeln('<h1>${_escapeHtml(detail.title)}</h1>');
    buffer.writeln('<p class="source">来源: <a href="${AppConstants.baseUrl}/t/${detail.slug}/${detail.id}">${AppConstants.baseUrl}/t/${detail.slug}/${detail.id}</a></p>');
    buffer.writeln('</header>');

    // 帖子内容
    for (final post in posts) {
      buffer.writeln('<article class="post">');
      buffer.writeln('<div class="post-header">');
      buffer.writeln('<span class="post-number">#${post.postNumber}</span>');
      buffer.writeln('<span class="username">@${_escapeHtml(post.username)}</span>');
      buffer.writeln('</div>');
      buffer.writeln('<div class="post-content">');
      buffer.writeln(post.cooked);
      buffer.writeln('</div>');
      buffer.writeln('</article>');
    }

    buffer.writeln('</body>');
    buffer.writeln('</html>');

    return buffer.toString();
  }

  /// 分享文件
  static Future<void> _shareAsFile(String content, String title, String extension) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = _sanitizeFilename(title);
    final file = File('${tempDir.path}/$safeName.$extension');
    await file.writeAsString(content);

    final mimeType = switch (extension) {
      'md' => 'text/markdown',
      'html' => 'text/html',
      _ => 'application/octet-stream',
    };

    final xFile = XFile(file.path, mimeType: mimeType);
    await ShareUtils.shareOrSaveFile(xFile);
  }

  /// 移除 HTML 标签
  static String _stripHtml(String html) {
    // 替换常见的 HTML 实体
    String text = html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<p[^>]*>'), '\n')
        .replaceAll('</p>', '\n')
        .replaceAll(RegExp(r'<li[^>]*>'), '- ')
        .replaceAll('</li>', '\n')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");

    // 移除所有 HTML 标签
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');

    // 压缩多余空白行
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return text.trim();
  }

  /// 转义 HTML 特殊字符
  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// 清理文件名中的非法字符
  static String _sanitizeFilename(String name) {
    final sanitized = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return sanitized.length > 50 ? sanitized.substring(0, 50) : sanitized;
  }

  /// HTML 样式（参考 Discourse 官方样式）
  static const String _htmlStyles = '''
:root {
  --primary: #222;
  --primary-medium: #72859a;
  --primary-low: #d4dce3;
  --primary-very-low: #f0f3f5;
  --secondary: #fff;
  --tertiary: #0088cc;
  --tertiary-low: #e6f5fb;
  --success: #009900;
  --danger: #dc3545;
  --highlight: #fffbcc;
  --love: #fa6c8d;
}

* {
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, 'Noto Sans SC', 'PingFang SC', 'Microsoft YaHei', sans-serif;
  max-width: 800px;
  margin: 0 auto;
  padding: 20px;
  line-height: 1.6;
  color: var(--primary);
  background: var(--secondary);
}

/* 标题区域 */
header {
  margin-bottom: 24px;
  padding-bottom: 16px;
  border-bottom: 1px solid var(--primary-low);
}

h1 {
  font-size: 1.5rem;
  margin: 0 0 8px 0;
  line-height: 1.3;
}

.source {
  color: var(--primary-medium);
  font-size: 0.875rem;
}

.source a {
  color: var(--tertiary);
  text-decoration: none;
}

.source a:hover {
  text-decoration: underline;
}

/* 帖子卡片 */
.post {
  margin-bottom: 24px;
  padding-bottom: 16px;
  border-bottom: 1px solid var(--primary-low);
}

.post:last-child {
  border-bottom: none;
}

.post-header {
  margin-bottom: 12px;
  display: flex;
  align-items: center;
  gap: 8px;
}

.post-number {
  display: inline-block;
  padding: 2px 8px;
  background: var(--tertiary-low);
  color: var(--tertiary);
  border-radius: 4px;
  font-size: 0.75rem;
  font-weight: bold;
}

.username {
  color: var(--primary-medium);
  font-size: 0.875rem;
}

/* 帖子内容 - cooked 样式 */
.post-content {
  font-size: 0.9375rem;
  line-height: 1.5;
  overflow-wrap: break-word;
}

.post-content > *:first-child {
  margin-top: 0;
}

.post-content > *:last-child {
  margin-bottom: 0;
}

/* 标题 */
.post-content h1,
.post-content h2,
.post-content h3,
.post-content h4,
.post-content h5,
.post-content h6 {
  margin: 1.5rem 0 0.5rem;
  line-height: 1.3;
}

.post-content h1 { font-size: 1.5rem; }
.post-content h2 { font-size: 1.25rem; }
.post-content h3 { font-size: 1.125rem; }
.post-content h4 { font-size: 1rem; }
.post-content h5 { font-size: 0.875rem; }
.post-content h6 { font-size: 0.75rem; }

/* 链接 */
.post-content a {
  color: var(--tertiary);
  text-decoration: none;
  overflow-wrap: break-word;
}

.post-content a:hover {
  text-decoration: underline;
}

/* 图片 */
.post-content img {
  max-width: 100%;
  height: auto;
  display: inline-block;
}

.post-content img.emoji {
  width: 1.25em;
  height: 1.25em;
  vertical-align: text-bottom;
}

/* 代码 - 行内 */
.post-content code {
  background: var(--primary-very-low);
  padding: 2px 5px;
  border-radius: 3px;
  font-family: 'SF Mono', SFMono-Regular, Consolas, 'Liberation Mono', Menlo, monospace;
  font-size: 0.875em;
  white-space: pre-wrap;
}

/* 代码 - 块级 */
.post-content pre {
  background: var(--primary-very-low);
  padding: 12px;
  border-radius: 4px;
  overflow-x: auto;
  max-height: 500px;
  margin: 1em 0;
}

.post-content pre code {
  display: block;
  padding: 0;
  background: none;
  white-space: pre;
  line-height: 1.4;
}

/* 代码高亮 */
.hljs-comment, .hljs-doctag, .hljs-meta { color: #6a737d; font-style: italic; }
.hljs-keyword, .hljs-subst { color: #d73a49; }
.hljs-number { color: #005cc5; }
.hljs-string, .hljs-template-tag, .hljs-template-variable { color: #032f62; }
.hljs-title { color: #6f42c1; }
.hljs-name { color: #22863a; }
.hljs-attr { color: #005cc5; }
.hljs-variable { color: #e36209; }
.hljs-deletion { background: #ffeef0; color: #b31d28; }
.hljs-addition { background: #e6ffed; color: #22863a; }

/* 引用块 */
.post-content blockquote {
  margin: 1em 0;
  padding: 0.75em 1em;
  border-left: 4px solid var(--primary-low);
  background: var(--primary-very-low);
  color: var(--primary);
}

.post-content blockquote > *:first-child { margin-top: 0; }
.post-content blockquote > *:last-child { margin-bottom: 0; }

/* Discourse 引用样式 */
aside.quote {
  margin: 1em 0;
  background: var(--primary-very-low);
  border-radius: 4px;
  overflow: hidden;
}

aside.quote .title {
  padding: 8px 12px;
  background: var(--primary-low);
  color: var(--primary);
  font-size: 0.875rem;
  display: flex;
  align-items: center;
  gap: 6px;
}

aside.quote .title img.avatar {
  width: 20px;
  height: 20px;
  border-radius: 50%;
}

aside.quote blockquote {
  margin: 0;
  padding: 12px;
  border-left: none;
  background: none;
}

/* 列表 */
.post-content ul,
.post-content ol {
  margin: 1em 0;
  padding-left: 2em;
}

.post-content li {
  margin: 0.25em 0;
}

.post-content ul ul,
.post-content ol ol,
.post-content ul ol,
.post-content ol ul {
  margin: 0.25em 0;
}

/* 表格 */
.post-content table {
  width: 100%;
  border-collapse: collapse;
  margin: 1em 0;
  font-size: 0.875rem;
}

.post-content thead th {
  text-align: left;
  padding: 8px;
  border-bottom: 2px solid var(--primary-low);
  font-weight: bold;
  color: var(--primary);
}

.post-content tbody td {
  padding: 8px;
  border-bottom: 1px solid var(--primary-low);
}

.post-content tbody tr:last-child td {
  border-bottom: none;
}

/* 水平线 */
.post-content hr {
  border: none;
  border-top: 1px solid var(--primary-low);
  margin: 1.5em 0;
}

/* 标记和删除 */
.post-content mark {
  background-color: var(--highlight);
  padding: 0 2px;
}

.post-content del {
  background-color: #ffeef0;
  text-decoration: line-through;
}

.post-content ins {
  background-color: #e6ffed;
  text-decoration: underline;
}

/* 提及 */
a.mention, a.mention-group {
  background: var(--primary-very-low);
  padding: 2px 6px;
  border-radius: 8px;
  font-size: 0.9375em;
}

/* 键盘按键 */
kbd {
  display: inline-flex;
  align-items: center;
  border: 1px solid var(--primary-low);
  background: var(--primary-very-low);
  border-bottom-width: 2px;
  border-radius: 3px;
  padding: 2px 6px;
  font-size: 0.875em;
  font-family: inherit;
}

/* 详情/折叠 */
details {
  margin: 1em 0;
  padding: 0.5em;
  background: var(--primary-very-low);
  border-radius: 4px;
}

details summary {
  cursor: pointer;
  font-weight: bold;
  padding: 0.5em;
  margin: -0.5em;
}

details[open] summary {
  margin-bottom: 0.5em;
  border-bottom: 1px solid var(--primary-low);
}

/* 投票 */
.poll {
  margin: 1em 0;
  padding: 1em;
  background: var(--primary-very-low);
  border-radius: 4px;
}

/* Onebox 链接预览 */
.onebox {
  margin: 1em 0;
  padding: 12px;
  border: 1px solid var(--primary-low);
  border-radius: 4px;
}

.onebox img {
  max-width: 100%;
}

/* 响应式 */
@media (max-width: 600px) {
  body {
    padding: 12px;
  }

  .post-content pre {
    padding: 8px;
    font-size: 0.8125rem;
  }

  .post-content table {
    display: block;
    overflow-x: auto;
  }
}

/* 打印样式 */
@media print {
  body {
    max-width: none;
    padding: 0;
  }

  .source a::after {
    content: " (" attr(href) ")";
    font-size: 0.75em;
    color: #666;
  }

  .post-content a::after {
    content: " (" attr(href) ")";
    font-size: 0.75em;
    color: #666;
  }

  .post-content pre {
    white-space: pre-wrap;
    max-height: none;
  }
}
''';
}
