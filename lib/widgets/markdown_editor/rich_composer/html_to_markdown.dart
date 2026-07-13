/// 剪贴板 HTML → markdown(富粘贴清洗层)。
///
/// 路线与 Discourse 传统 composer 的 to-markdown 同思路:外部富文本
/// (网页/Word/邮件)不直接进文档模型 —— 先降成 markdown,再走与纯文本
/// 粘贴同一条 cook 导入链(markdownToDoc)。脏 HTML(mso 样式/嵌套
/// div/内联样式 span)在 markdown 化时天然被丢弃,cook 产物必是引擎
/// 认识的干净 cooked,不会炸出未知岛。
library;

import 'package:html2md/html2md.dart' as html2md;

/// 剪贴板 HTML 转 markdown。转换失败/产物为空返回 null(调用方回落
/// 纯文本粘贴路径,内容不丢只丢格式)。
String? clipboardHtmlToMarkdown(String html) {
  var src = html;
  // 代码编辑器着色 dump 嗅探(VSCode/JetBrains 复制代码的 html 是
  // 每行一个 div + 满身着色 span,根 div style 声明等宽字体族):
  // markdown 化会拆成多个普通段落、缩进丢失 —— 返回 null 走纯文本
  // (剪贴板 text/plain 是带真实换行缩进的原始代码,最保真)。
  // 嗅探启发式,漏判/误判都无害:只影响格式取舍,内容两条路都不丢。
  final head = src.length > 600 ? src.substring(0, 600) : src;
  if (RegExp(
    "font-family:[^;\"']*(?:monospace|Menlo|Consolas|Courier|Monaco)",
    caseSensitive: false,
  ).hasMatch(head)) {
    return null;
  }
  // Word/Outlook 前清洗:条件注释块与 o: 命名空间标签(html 解析器
  // 不认识,不剥的话内容会漏出成正文)。
  src = src.replaceAll(RegExp(r'<!--\[if [\s\S]*?<!\[endif\]-->'), '');
  src = src.replaceAll(RegExp(r'</?o:p[^>]*>', caseSensitive: false), '');

  String md;
  try {
    md = html2md.convert(
      src,
      styleOptions: {
        'headingStyle': 'atx',
        'codeBlockStyle': 'fenced',
        'bulletListMarker': '-',
        'emDelimiter': '*',
        'strongDelimiter': '**',
        'hr': '---',
      },
      ignore: ['style', 'script', 'title', 'meta', 'link'],
    );
  } catch (_) {
    return null;
  }

  // 不可用图剥离:data:(base64 内联,Word 截图常见 —— 几 MB 的
  // markdown 会毁帖)与 file:(本地路径,发出去别人打不开)。留 alt
  // 文本占位,无 alt 剥净。
  md = md.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\((?:data|file):[^)]*\)'),
    (m) => m[1] ?? '',
  );

  // nbsp → 普通空格(Word 满篇 nbsp,markdown 里保留会拼出不折行怪串)
  md = md.replaceAll(' ', ' ');
  // 压缩连续空行(html2md 对深嵌套 div 会吐大段空白)
  md = md.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return md.isEmpty ? null : md;
}
