/// 判断一段 Markdown 是否含有块级格式：引用块、代码块、图片 / 附件、
/// 表格、折叠块、标题、HTML。
///
/// 快捷回复只如实显示纯文字与表情，这些内容在里面会露出源码；用来决定
/// 回复时直接打开完整编辑器。行内的粗体、链接等不算——源码形态仍可读。
bool markdownHasBlockFormatting(String markdown) {
  if (markdown.trim().isEmpty) return false;
  return _blockPatterns.any((pattern) => pattern.hasMatch(markdown));
}

final List<RegExp> _blockPatterns = [
  // Discourse 引用 / 折叠块 / 其他 BBCode 块
  RegExp(r'\[(quote|details|spoiler|poll|wrap)\b', caseSensitive: false),
  // 围栏代码块
  RegExp(r'^\s*(```|~~~)', multiLine: true),
  // 图片、上传附件
  RegExp(r'!\[[^\]]*\]\(|upload://'),
  // 表格（含表头分隔行）
  RegExp(r'^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$', multiLine: true),
  // Markdown 引用块、标题
  RegExp(r'^\s{0,3}(>|#{1,6}\s)', multiLine: true),
  // HTML 标签
  RegExp(r'<\/?[a-zA-Z][^>]*>'),
];
