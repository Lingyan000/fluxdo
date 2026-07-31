/// 块完成规则:回车时判定光标所在位置能否收尾成一个可渲染结构。
///
/// 与编辑器内核的 input rules 分工:
/// - 内核那套(`# `/`- `/`1. `/`> `/`--- `)敲**空格**即可判定,产物是
///   块属性或行内 mark,纯状态层就能完成;
/// - 这里这套的收尾时机是**回车**(围栏后面还要打语言名,不能一见第三个
///   反引号就转),且产物是**岛**(代码块/公式/表格)或需要 cook 才能解析
///   的 HTML —— 都得走宿主的 cook 链路,所以留在宿主层。
///
/// 本文件只做**判定**(纯函数,可单测),真正的替换/cook 由调用方执行。
library;

/// 命中的块完成结构。
class BlockCompletion {
  const BlockCompletion({
    required this.from,
    required this.to,
    required this.markdown,
    this.splitAfter = false,
  });

  /// 参与替换的块下标区间(闭区间)。
  final int from;
  final int to;

  /// 送 cook 的 markdown。
  final String markdown;

  /// 插入后是否还要分段。行内 HTML 场景为 true —— 回车本意仍是换行,
  /// 只是顺手把这段渲染了;围栏/公式/表格则由岛本身承载结构,回车被消耗。
  final bool splitAfter;

  @override
  String toString() =>
      'BlockCompletion($from..$to, splitAfter=$splitAfter, ${markdown.split('\n').first})';
}

/// ```` ```lang ```` 围栏起始行。
final _fenceRe = RegExp(r'^```([\w+#.-]*)$');

/// `$$` 公式块起始行。
final _mathRe = RegExp(r'^\$\$$');

/// 分割线独占一行(`---` / `***` / `___`)。
///
/// 内核的 hr 输入规则要求**尾随一个空格**(`^(---|\*\*\*|___) $`),
/// 打完 `***` 直接回车不匹配 —— 补上回车这条路径(实测三种写法 cook
/// 都出 `<hr>`)。
final _hrRe = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');

/// `| 列 | 列 |` 表头行(至少两列 —— 一根竖线的普通句子不该变表格)。
final _tableRe = RegExp(r'^\|[^|]*\|[^|]*\|\s*$');

/// 闭合标签独占一行。
final _closingRe = RegExp(r'^</([a-zA-Z][\w-]*)>$');

/// 任意开标签(行内 HTML 扫描用)。
final _openTagRe = RegExp(r'<([a-zA-Z][\w-]*)(\s[^>]*)?>');

/// Discourse 白名单里的**块级** HTML 标签:整段变岛。
const htmlBlockTags = {
  'details', 'summary', 'div', 'table', 'blockquote', 'pre', 'ul', 'ol',
  'aside', 'section', 'figure',
};

/// Discourse 白名单里的**行内** HTML 标签:不变岛,只把本段送 cook
/// 换成带正确行内节点的段落。
const htmlInlineTags = {
  'a', 'kbd', 'sup', 'sub', 'mark', 'small', 'big', 'ins', 'del', 's', 'u',
  'b', 'i', 'em', 'strong', 'code', 'span', 'abbr', 'ruby', 'rt', 'rp',
  'q', 'cite', 'dfn', 'time', 'var', 'samp', 'bdi', 'bdo',
};

/// 自闭合(void)行内标签:没有闭合标签,写出来就算完整。
const htmlVoidTags = {'img', 'br', 'wbr'};

/// 本段是否含**完整**的行内 HTML:成对闭合的(`<kbd>Ctrl</kbd>`、
/// `<a href="…">链接</a>`)或自闭合的(`<img src="…">`、`<br>`)。
bool hasCompleteInlineHtml(String text) {
  for (final m in _openTagRe.allMatches(text)) {
    final tag = m.group(1)!.toLowerCase();
    if (htmlVoidTags.contains(tag)) return true;
    if (!htmlInlineTags.contains(tag)) continue;
    if (text.contains('</$tag>', m.end)) return true;
  }
  return false;
}

/// 本行是否是**单行写完**的块级 HTML(`<div>内容</div>`)。
/// 返回标签名;不是则 null。
String? _singleLineBlockHtml(String text) {
  final m = RegExp(r'^<([a-zA-Z][\w-]*)(\s[^>]*)?>.*</([a-zA-Z][\w-]*)>$')
      .firstMatch(text);
  if (m == null) return null;
  final open = m.group(1)!.toLowerCase();
  if (open != m.group(3)!.toLowerCase()) return null;
  return htmlBlockTags.contains(open) ? open : null;
}

// ---------------------------------------------------------------------
// BBCode(Discourse 的另一套标记语法,与 HTML 并行)
// ---------------------------------------------------------------------

/// 块级 BBCode:整段变岛。
/// **只列 cook 引擎真支持的**。放进引擎不认的标签(曾经放过 `note`/
/// `aside`/`table`/`chat`/`floatl`/`floatr`)后果很具体:检测命中 → 送
/// cook → 原样吐回字面量 → 用户看到回车分了段但没渲染。增删前务必用
/// tools/discourse-cook-bundle 实跑一遍。
const bbcodeBlockTags = {
  'quote', 'details', 'grid', 'wrap', 'poll',
  // 这两个 cook 出来是块级容器(pre / div.spoiler),归块级
  'code', 'spoiler',
};

/// 行内 BBCode:只把本段送 cook,不变岛。
///
/// 只列**最终能渲染出来**的 —— 判据是 cook 引擎真认得。
/// - `color`/`bgcolor`/`size`:由内核 input rules 即打即渲染(打完闭
///   标记当场转换,attr 原样保留),不走块完成;
/// - `font`:引擎不认,不支持;
/// - `sup`/`sub`/`highlight`/`mark`:**BBCode 形式**引擎不认(HTML 形式
///   `<sup>` 才认,见 [htmlInlineTags])。
const bbcodeInlineTags = {
  'b', 'i', 'u', 's', 'url', 'email', 'img',
};

/// `[tag]` / `[tag=值]` / `[tag 属性=值]` 开标签。
final _bbOpenRe = RegExp(r'\[([a-zA-Z][\w-]*)(=[^\]]*|\s[^\]]*)?\]');

/// `[/tag]` 闭标签独占一行。
final _bbClosingRe = RegExp(r'^\[/([a-zA-Z][\w-]*)\]$');

/// 本段是否含**成对闭合**的行内 BBCode(`[color=#f00]红[/color]`)。
bool hasCompleteInlineBbcode(String text) {
  for (final m in _bbOpenRe.allMatches(text)) {
    final tag = m.group(1)!.toLowerCase();
    if (!bbcodeInlineTags.contains(tag)) continue;
    if (text.contains('[/$tag]', m.end)) return true;
  }
  return false;
}

/// 本行是否是**单行写完**的块级 BBCode(`[quote]内容[/quote]`)。
String? _singleLineBlockBbcode(String text) {
  final m = _bbOpenRe.matchAsPrefix(text);
  if (m == null) return null;
  final tag = m.group(1)!.toLowerCase();
  if (!bbcodeBlockTags.contains(tag)) return null;
  return text.endsWith('[/$tag]') ? tag : null;
}

/// 判定 [index] 块处按下回车能否收尾。
///
/// [blockTexts] 是全文档各块的文本;**岛块传 null**(结构不透明,HTML
/// 回溯不跨岛聚合)。返回 null = 不命中,调用方按普通分段处理。
///
/// 前置条件(光标在行尾、无浮层等)由调用方保证。
BlockCompletion? detectBlockCompletion(List<String?> blockTexts, int index) {
  if (index < 0 || index >= blockTexts.length) return null;
  final raw = blockTexts[index];
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;

  // ---- 单块即可判定 ----
  final fence = _fenceRe.firstMatch(text);
  if (fence != null) {
    return BlockCompletion(
      from: index,
      to: index,
      markdown: '```${fence.group(1)!}\n\n```',
    );
  }
  if (_hrRe.hasMatch(text)) {
    // 统一成 `---`:三种写法 cook 结果相同,序列化口径取一种就够
    return BlockCompletion(from: index, to: index, markdown: '---');
  }
  if (_mathRe.hasMatch(text)) {
    return BlockCompletion(
      from: index,
      to: index,
      markdown: r'$$' '\n\n' r'$$',
    );
  }
  if (_tableRe.hasMatch(text)) {
    // 表头 → 补分隔行 + 一行空数据(列数取表头)
    final cols = text.split('|').where((c) => c.trim().isNotEmpty).length;
    final sep = '|${List.filled(cols, '---').join('|')}|';
    final body = '|${List.filled(cols, '  ').join('|')}|';
    return BlockCompletion(
      from: index,
      to: index,
      markdown: '$text\n$sep\n$body',
    );
  }

  // ---- 成对块级 HTML:向前回溯找未闭合的开标签 ----
  final closing = _closingRe.firstMatch(text);
  if (closing != null) {
    final tag = closing.group(1)!.toLowerCase();
    if (htmlBlockTags.contains(tag)) {
      final openRe = RegExp('^<$tag' r'(\s[^>]*)?>$', caseSensitive: false);
      // 上限 64 块:防超长文档里一个孤立 </div> 全文回溯
      for (var j = index - 1; j >= 0 && index - j <= 64; j--) {
        final t = blockTexts[j];
        if (t == null) break; // 夹了岛 → 不跨岛聚合
        if (openRe.hasMatch(t.trim())) {
          return BlockCompletion(
            from: j,
            to: index,
            markdown: [for (var k = j; k <= index; k++) blockTexts[k]!]
                .join('\n'),
          );
        }
      }
    }
  }

  // ---- 成对块级 BBCode:`[quote]` … `[/quote]` 跨块回溯 ----
  final bbClosing = _bbClosingRe.firstMatch(text);
  if (bbClosing != null) {
    final tag = bbClosing.group(1)!.toLowerCase();
    if (bbcodeBlockTags.contains(tag)) {
      for (var j = index - 1; j >= 0 && index - j <= 64; j--) {
        final t = blockTexts[j];
        if (t == null) break; // 夹了岛 → 不跨岛聚合
        final om = _bbOpenRe.matchAsPrefix(t.trim());
        if (om != null &&
            om.group(1)!.toLowerCase() == tag &&
            om.end == t.trim().length) {
          return BlockCompletion(
            from: j,
            to: index,
            markdown: [for (var k = j; k <= index; k++) blockTexts[k]!]
                .join('\n'),
          );
        }
      }
    }
  }

  // ---- 单行写完的块级 BBCode / HTML ----
  if (_singleLineBlockBbcode(text) != null) {
    return BlockCompletion(from: index, to: index, markdown: raw);
  }
  if (_singleLineBlockHtml(text) != null) {
    return BlockCompletion(from: index, to: index, markdown: raw);
  }

  // ---- 行内 HTML / BBCode:只换本段,结构不动 ----
  if (hasCompleteInlineHtml(raw) || hasCompleteInlineBbcode(raw)) {
    return BlockCompletion(
      from: index,
      to: index,
      markdown: raw,
      splitAfter: true,
    );
  }
  return null;
}
