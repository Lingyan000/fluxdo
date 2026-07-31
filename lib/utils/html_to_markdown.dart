import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

/// HTML → Markdown 转换器
///
/// 复刻 Discourse 的 to-markdown.js 架构：
/// Tag 基类 + Element 类的双层递归转换
class HtmlToMarkdown {
  /// 将 HTML 转换为 Markdown
  static String convert(String html) {
    try {
      // 1. 代码块占位符
      final placeholders = <List<String>>[];
      var processedHtml = _putPlaceholders(html, placeholders);

      // 2. 预处理 HTML
      processedHtml = _trimUnwanted(processedHtml);

      // 3. 解析为 DOM 并转换
      final fragment = html_parser.parseFragment(processedHtml);
      final elements = _transformNodes(fragment.nodes);

      // 4. 解析为 Markdown
      var markdown = _MdElement.parse(elements).trim();

      // 5. 最终清理
      markdown = markdown
          .replaceAll(RegExp(r'^<b>'), '')
          .replaceAll(RegExp(r'<\/b>$'), '')
          .trim();
      markdown = markdown
          .replaceAll(RegExp(r'\n +'), '\n')
          .replaceAll(RegExp(r' +\n'), '\n')
          .replaceAll(RegExp(r' {2,}'), ' ')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .replaceAll('\t', '  ');

      // 6. 还原占位符
      return _replacePlaceholders(markdown, placeholders);
    } catch (_) {
      return '';
    }
  }

  /// 从 URL 提取扩展名（公开复用版）。
  ///
  /// 对齐官方把 extensionFromUrl/buildImageMarkdown 抽进共享模块
  /// markdown-image-builder.js 的做法：引用图片(quote-image)等
  /// HtmlToMarkdown 之外的场景也要构造同格式的图片 markdown。
  static String? extensionFromUrl(String? url) => _extensionFromUrl(url);

  /// 构建图片 Markdown（公开复用版，见 [extensionFromUrl] 说明）。
  static String buildImageMarkdown({
    required String src,
    String? alt,
    String? width,
    String? height,
    String? title,
  }) {
    return _buildImageMarkdown(
      src: src,
      alt: alt,
      width: width,
      height: height,
      title: title,
    );
  }

  /// 预处理：移除 body 标签、&nbsp; 等
  static String _trimUnwanted(String html) {
    final body = RegExp(r'<body[^>]*>([\s\S]*?)<\/body>').firstMatch(html);
    html = body != null ? body.group(1)! : html;
    html = html.replaceAll(RegExp(r'\r|\n|&nbsp;'), ' ');
    html = html.replaceAll('\u00A0', ' ');

    // 压缩标签间多余空白
    RegExpMatch? match;
    while ((match = RegExp(r'<[^\s>]+[^>]*>\s{2,}<[^\s>]+[^>]*>').firstMatch(html)) != null) {
      final original = match!.group(0)!;
      html = html.replaceFirst(original, original.replaceAll(RegExp(r'>\s{2,}<'), '> <'));
    }

    return html;
  }

  /// 代码块占位符：转换前将 <code> 内容替换为占位符
  static String _putPlaceholders(String html, List<List<String>> placeholders) {
    final codeRegex = RegExp(r'<code[^>]*>([\s\S]*?)<\/code>', caseSensitive: false);

    return html.replaceAllMapped(codeRegex, (match) {
      final placeholder = 'DISCOURSE_PLACEHOLDER_${placeholders.length + 1}';
      // 解码 HTML 实体
      var code = match.group(1)!;
      code = _decodeHtmlEntities(code);
      code = code.replaceAll(RegExp(r'^\n'), '').replaceAll(RegExp(r'\n$'), '');
      placeholders.add([placeholder, code]);
      return '<code>$placeholder</code>';
    });
  }

  /// 还原占位符
  static String _replacePlaceholders(String markdown, List<List<String>> placeholders) {
    for (final p in placeholders) {
      markdown = markdown.replaceFirst(p[0], p[1]);
    }
    return markdown;
  }

  /// HTML 实体解码
  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&#x2F;', '/')
        .replaceAll('&nbsp;', ' ');
  }

  /// 将 DOM 节点列表转换为内部 _NodeData 列表
  static List<_NodeData> _transformNodes(List<dom.Node> nodes) {
    final result = <_NodeData>[];
    for (final node in nodes) {
      if (node.nodeType == dom.Node.COMMENT_NODE) continue;
      result.add(_transformNode(node));
    }
    return result;
  }

  /// 将单个 DOM 节点转换为 _NodeData
  static _NodeData _transformNode(dom.Node node) {
    if (node.nodeType == dom.Node.TEXT_NODE) {
      return _NodeData(
        name: '#text',
        data: node.text,
        children: [],
        attributes: {},
      );
    }

    final element = node as dom.Element;
    final children = <_NodeData>[];
    for (final child in element.nodes) {
      if (child.nodeType != dom.Node.COMMENT_NODE) {
        children.add(_transformNode(child));
      }
    }

    final attributes = <String, String>{};
    element.attributes.forEach((key, value) {
      attributes[key.toString()] = value;
    });

    return _NodeData(
      name: element.localName!.toLowerCase(),
      data: null,
      children: children,
      attributes: attributes,
    );
  }
}

// ================================================================
// 内部数据结构
// ================================================================

/// 原始 DOM 节点数据
class _NodeData {
  final String name;
  final String? data;
  final List<_NodeData> children;
  final Map<String, String> attributes;

  _NodeData({
    required this.name,
    this.data,
    required this.children,
    required this.attributes,
  });
}

// ================================================================
// Tag 系统
// ================================================================

/// 可 trim 的标签集合（Block, Heading, Slice 等）
const _trimmableTags = <String>{
  // blocks
  'address', 'article', 'dd', 'dl', 'dt', 'fieldset', 'figcaption',
  'figure', 'footer', 'form', 'header', 'hgroup', 'hr', 'main',
  'nav', 'p', 'pre', 'section',
  // headings
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  // slices
  'thead', 'tbody', 'tfoot',
  // others
  'aside', 'li', 'td', 'th', 'br', 'blockquote', 'table', 'ol', 'tr', 'ul',
};

/// Tag 基类
class _Tag {
  String prefix;
  String suffix;
  bool inline;
  _MdElement? element;

  _Tag([this.prefix = '', this.suffix = '', this.inline = false]);

  String decorate(String text) {
    if (prefix.isNotEmpty || suffix.isNotEmpty) {
      text = '$prefix$text$suffix';
    }

    if (inline) {
      final prev = element?.prev;
      final next = element?.next;

      if (prev != null && prev.name != '#text') {
        text = ' $text';
      }
      if (next != null && next.name != '#text') {
        text = '$text ';
      }
    }

    return text;
  }

  String toMarkdown() {
    final text = element!.innerMarkdown();
    if (text.trim().isNotEmpty) {
      return decorate(text);
    }
    return text;
  }
}

/// Block Tag (p, div, pre, section, ...)
class _BlockTag extends _Tag {
  String gap;

  _BlockTag([super.prefix, super.suffix]) : gap = '\n\n';

  @override
  String decorate(String text) {
    final e = element;
    if (e != null && e.name == 'p' && e.parent?.name == 'li') {
      gap = '';
    }
    return '$gap$prefix$text$suffix$gap';
  }
}

/// Heading Tag (h1-h6)
class _HeadingTag extends _BlockTag {
  _HeadingTag(int level) : super('${'#' * level} ', '');
}

/// Emphasis Tag (b, strong, em, i, s, strike)
class _EmphasisTag extends _Tag {
  final String tagName;
  final String decorator;

  _EmphasisTag(this.tagName, this.decorator)
      : super(decorator, decorator, true);

  @override
  String decorate(String text) {
    if (text.contains('\n')) {
      prefix = '<$tagName>';
      suffix = '</$tagName>';
    }

    final leadingSpace = RegExp(r'^\s').firstMatch(text);
    if (leadingSpace != null) {
      prefix = '${leadingSpace.group(0)}$prefix';
    }

    final trailingSpace = RegExp(r'\s$').firstMatch(text);
    if (trailingSpace != null) {
      suffix = '$suffix${trailingSpace.group(0)}';
    }

    return super.decorate(text.trim());
  }
}

/// Code Tag
class _CodeTag extends _Tag {
  _CodeTag() : super('`', '`');

  @override
  String decorate(String text) {
    if (element!.parentNames.contains('pre')) {
      prefix = '\n\n```\n';
      suffix = '\n```\n\n';
    } else {
      inline = true;
    }
    // 解码 HTML 实体
    text = HtmlToMarkdown._decodeHtmlEntities(text);
    return super.decorate(text);
  }
}

/// Link Tag (a)
class _LinkTag extends _Tag {
  _LinkTag() : super('', '', true);

  @override
  String decorate(String text) {
    final e = element!;
    final attr = e.attributes;
    final cssClass = attr['class'] ?? '';

    // mention 链接
    if (cssClass.startsWith('mention') && text.startsWith('@')) {
      return text;
    }

    // hashtag 链接
    if (cssClass == 'hashtag' && text.startsWith('#')) {
      return text;
    }

    // hashtag-cooked
    if (cssClass.contains('hashtag-cooked')) {
      if (attr.containsKey('data-ref')) {
        return '#${attr['data-ref']}';
      } else {
        final type = attr.containsKey('data-type') ? '::${attr['data-type']}' : '';
        return '#${attr['data-slug'] ?? ''}$type';
      }
    }

    // lightbox / d-lazyload
    if (['lightbox', 'd-lazyload'].contains(cssClass)) {
      final img = e.children.where((c) => c.name == 'img').firstOrNull;
      if (img != null) {
        var href = attr['href'] ?? '';
        final base62SHA1 = img.attributes['data-base62-sha1'];
        text = attr['title'] ?? '';

        if (base62SHA1 != null && base62SHA1.isNotEmpty) {
          href = 'upload://$base62SHA1';
          final ext = _extensionFromUrl(img.attributes['src']) ??
              _extensionFromUrl(attr['href']) ??
              _extensionFromUrl(attr['data-download-href']);
          if (ext != null) href += '.$ext';
        } else {
          // 客户端 cook 预览形态(见 _ImageTag 同名注释):没有
          // data-base62-sha1 时,真实短链在 img 的 data-orig-src。
          final origSrc = img.attributes['data-orig-src'];
          if (origSrc != null && origSrc.startsWith('upload://')) {
            href = origSrc;
          }
        }

        final width = img.attributes['width'];
        final height = img.attributes['height'];
        if (width != null && height != null) {
          final pipe = e.parentNames.contains('table') ? r'\|' : '|';
          text = '$text$pipe${width}x$height';
        }

        return '![$text]($href)';
      }
    }

    // 普通链接
    final href = attr['href'];
    if (href != null && text != href) {
      text = text.replaceAll(RegExp(r'\n{2,}'), '\n');
      var linkModifier = '';
      if (cssClass.contains('attachment')) {
        linkModifier = '|attachment';
      }
      return '[$text$linkModifier]($href)';
    }

    return text;
  }
}

/// Image Tag (img)
class _ImageTag extends _Tag {
  _ImageTag() : super('', '', true);

  @override
  String toMarkdown() {
    final e = element!;
    final attr = e.attributes;
    final pAttr = e.parent?.attributes ?? {};
    final cssClass = attr['class'] ?? pAttr['class'] ?? '';

    var src = attr['src'] ?? pAttr['src'];

    final base62SHA1 = attr['data-base62-sha1'];
    if (base62SHA1 != null && base62SHA1.isNotEmpty) {
      src = 'upload://$base62SHA1';
      final ext = _extensionFromUrl(attr['src'] ?? pAttr['src']) ??
          _extensionFromUrl(attr['data-orig-src']);
      if (ext != null) src = '$src.$ext';
    } else {
      // 刚发帖/编辑后本地乐观渲染的「客户端 cook 预览形态」:src 是占位图
      // /images/transparent.png,没有 data-base62-sha1,真实短链在
      // data-orig-src(等服务端返回真 cooked 前一直是这个形态)。
      final origSrc = attr['data-orig-src'] ?? pAttr['data-orig-src'];
      if (origSrc != null && origSrc.startsWith('upload://')) {
        src = origSrc;
      }
    }

    // emoji
    if (cssClass.contains('emoji')) {
      if (cssClass.contains('user-status') || cssClass.contains('mention-status')) {
        return '';
      }
      return attr['title'] ?? pAttr['title'] ?? '';
    }

    if (src != null) {
      if (RegExp(r'^data:image\/([a-zA-Z]*);base64,').hasMatch(src)) {
        return '[image]';
      }

      final alt = attr['alt'] ?? pAttr['alt'] ?? '';
      final width = attr['width'] ?? pAttr['width'];
      final height = attr['height'] ?? pAttr['height'];
      final title = attr['title'];
      final escapeTablePipe = e.parentNames.contains('table');

      return _buildImageMarkdown(
        src: src,
        alt: alt,
        width: width,
        height: height,
        title: title,
        escapeTablePipe: escapeTablePipe,
      );
    }

    return '';
  }
}

/// Blockquote Tag
class _BlockquoteTag extends _Tag {
  _BlockquoteTag() : super('\n> ', '\n');

  @override
  String decorate(String text) {
    text = text
        .trim()
        .replaceAll(RegExp(r'\n{2,}>'), '\n>')
        .replaceAll('\n', '\n> ');
    return super.decorate(text);
  }
}

/// Aside Tag (aside.quote)
class _AsideTag extends _BlockTag {
  _AsideTag() : super('', '');

  @override
  String toMarkdown() {
    final cssClass = element!.attributes['class'] ?? '';
    if (!RegExp(r'\bquote\b').hasMatch(cssClass)) {
      return super.toMarkdown();
    }

    final blockquote = element!.children.where((c) => c.name == 'blockquote').firstOrNull;
    if (blockquote == null) {
      return super.toMarkdown();
    }

    var text = blockquote.innerMarkdown();
    text = text.trim().replaceAll(RegExp(r'^> ', multiLine: true), '').trim();
    if (text.isEmpty) return '';

    final username = element!.attributes['data-username'];
    final post = element!.attributes['data-post'];
    final topic = element!.attributes['data-topic'];
    // 首字段官方语义是**显示名**(昵称),不是登录用户名。官方 cooked 里
    // 显示名≠用户名时 aside 自带 data-display-name 属性(discourse
    // features/quotes.js),直接读它;不要从标题栏 DOM 反查——同主题引用
    // 的显示名是纯文本节点,跨主题引用标题里的 <a> 装的是话题标题而不是
    // 人名。有显示名时真实用户名单独放 username: 参数,服务端靠它查人。
    final displayName = element!.attributes['data-display-name'];
    final hasDisplayName = displayName != null &&
        displayName.isNotEmpty &&
        displayName != username;

    final quotePrefix = (username != null && post != null && topic != null)
        ? (hasDisplayName
            ? '[quote="$displayName, post:$post, topic:$topic, username:$username"]'
            : '[quote="$username, post:$post, topic:$topic"]')
        : '[quote]';

    return '\n$quotePrefix\n$text\n[/quote]\n';
  }
}

/// Li Tag
class _LiTag extends _SliceTag {
  _LiTag() : super('li', '\n');

  @override
  String decorate(String text) {
    final indent = element!
        .filterParentNames(['ol', 'ul'])
        .skip(1)
        .map((_) => '\t')
        .join();

    return super.decorate('$indent* ${text.trimLeft()}');
  }
}

/// OL Tag
class _OlTag extends _ListTag {
  _OlTag() : super('ol');

  @override
  String decorate(String text) {
    text = '\n$text';
    final bulletMatch = RegExp(r'\n\t*\*').firstMatch(text);
    if (bulletMatch == null) return super.decorate(text.substring(1));

    final bullet = bulletMatch.group(0)!;
    var i = int.tryParse(element!.attributes['start'] ?? '1') ?? 1;

    while (text.contains(bullet)) {
      text = text.replaceFirst(bullet, bullet.replaceFirst('*', '$i.'));
      i++;
    }

    return super.decorate(text.substring(1));
  }
}

/// List Tag (ul, ol)
class _ListTag extends _BlockTag {
  _ListTag(String name) : super('', '');

  @override
  String decorate(String text) {
    var smallGap = '';
    final parent = element?.parent;

    if (parent?.name == 'ul') {
      gap = '';
      suffix = '\n';
    }

    if ((element?.filterParentNames(['li']) ?? []).isNotEmpty) {
      gap = '';
      smallGap = '\n';
    }

    return smallGap + super.decorate(text.trimRight());
  }
}

/// Slice Tag (dt, dd, thead, tbody, tfoot)
class _SliceTag extends _Tag {
  _SliceTag(String name, [String suffix = '\n']) : super('', suffix);

  @override
  String decorate(String text) {
    if (element?.next == null) {
      suffix = '';
    }
    return '$text$suffix';
  }
}

/// Cell Tag (td, th)
class _CellTag extends _Tag {
  _CellTag() : super('|');

  @override
  String toMarkdown() {
    final text = element!.innerMarkdown().trim();

    if (text.contains('\n')) {
      // 表格不支持多行内容，标记为无效
      var e = element;
      while (e != null) {
        e = e.parent;
        if (e?.name == 'table') {
          final tag = e!.tag();
          if (tag is _TableTag) tag.isValid = false;
          break;
        }
      }
    }

    return decorate(text);
  }
}

/// TR Tag
class _TrTag extends _SliceTag {
  _TrTag() : super('tr', '|\n');

  @override
  String decorate(String text) {
    if (element?.next == null) {
      suffix = '|';
    }
    return '$text$suffix';
  }
}

/// Table Tag
class _TableTag extends _BlockTag {
  bool isValid = true;

  _TableTag() : super('', '');

  int _countPipes(String text) {
    return RegExp(r'(?<!\\)\|').allMatches(text).length;
  }

  @override
  String decorate(String text) {
    text = super.decorate(text).replaceAll(RegExp(r'\|\n{2,}\|'), '|\n|');
    final rows = text.trim().split('\n');
    if (rows.isEmpty) return text;

    final pipeCount = _countPipes(rows[0]);
    isValid = isValid &&
        rows.length > 1 &&
        pipeCount > 2 &&
        rows.every((r) => _countPipes(r) <= pipeCount);

    if (isValid) {
      final splitterRow = '${List.filled(pipeCount - 1, '| --- ').join('')}|\n';
      text = text.replaceFirst('|\n', '|\n$splitterRow');
    } else {
      text = text.replaceAll('|', ' ');
    }

    return text;
  }
}

/// Span Tag
class _SpanTag extends _Tag {
  _SpanTag() : super();

  @override
  String decorate(String text) {
    final attr = element!.attributes;
    final cssClass = attr['class'] ?? '';

    if (cssClass == 'badge badge-notification clicks') return '';
    if (cssClass.contains('click-count')) return '';

    if (RegExp(r'\bmathjax-math\b').hasMatch(cssClass)) return '';

    if (RegExp(r'\bmath\b').hasMatch(cssClass) &&
        attr.containsKey('data-applied-mathjax')) {
      return '\$$text\$';
    }

    return super.decorate(text);
  }
}

/// Div Tag
class _DivTag extends _BlockTag {
  _DivTag() : super('', '');

  @override
  String decorate(String text) {
    final attr = element!.attributes;
    final cssClass = attr['class'] ?? '';

    if (RegExp(r'\bmathjax-math\b').hasMatch(cssClass)) return '';

    if (RegExp(r'\bmath\b').hasMatch(cssClass) &&
        attr.containsKey('data-applied-mathjax')) {
      return '\n\$\$\n$text\n\$\$\n';
    }

    return super.decorate(text);
  }
}

/// Replace Tag (br, hr, head)
class _ReplaceTag extends _Tag {
  final String replacement;

  _ReplaceTag(this.replacement) : super('', '');

  @override
  String toMarkdown() => replacement;
}

/// Allowed Tag (ins, del, small, big, kbd, mark, ruby, ...)
class _AllowedTag extends _Tag {
  final String tagName;

  _AllowedTag(this.tagName) : super('<$tagName>', '</$tagName>');
}

// ================================================================
// Tag 注册表
// ================================================================

final Map<String, _Tag Function()> _tagFactories = _buildTagFactories();

Map<String, _Tag Function()> _buildTagFactories() {
  final map = <String, _Tag Function()>{};

  // Block tags
  for (final name in [
    'address', 'article', 'dd', 'dl', 'dt', 'fieldset', 'figcaption',
    'figure', 'footer', 'form', 'header', 'hgroup', 'hr', 'main',
    'nav', 'p', 'pre', 'section',
  ]) {
    map[name] = () => _BlockTag();
  }

  // Heading tags
  for (var i = 1; i <= 6; i++) {
    map['h$i'] = () => _HeadingTag(i);
  }

  // Slice tags
  for (final name in ['dt', 'dd', 'thead', 'tbody', 'tfoot']) {
    map[name] = () => _SliceTag(name);
  }

  // Emphasis tags
  for (final pair in [
    ['b', '**'], ['strong', '**'],
    ['i', '*'], ['em', '*'],
    ['s', '~~'], ['strike', '~~'],
  ]) {
    map[pair[0]] = () => _EmphasisTag(pair[0], pair[1]);
  }

  // Allowed tags
  for (final name in ['ins', 'del', 'small', 'big', 'kbd', 'ruby', 'rt', 'rb', 'rp', 'mark']) {
    map[name] = () => _AllowedTag(name);
  }

  // 特殊标签
  map['aside'] = () => _AsideTag();
  map['td'] = () => _CellTag();
  map['th'] = () => _CellTag();
  map['br'] = () => _ReplaceTag('\n');
  map['hr'] = () => _ReplaceTag('\n---\n');
  map['head'] = () => _ReplaceTag('');
  map['li'] = () => _LiTag();
  map['a'] = () => _LinkTag();
  map['img'] = () => _ImageTag();
  map['code'] = () => _CodeTag();
  map['blockquote'] = () => _BlockquoteTag();
  map['table'] = () => _TableTag();
  map['tr'] = () => _TrTag();
  map['ol'] = () => _OlTag();
  map['ul'] = () => _ListTag('ul');
  map['span'] = () => _SpanTag();
  map['div'] = () => _DivTag();

  return map;
}

_Tag _createTag(String name) {
  final factory = _tagFactories[name];
  if (factory != null) return factory();
  return _Tag();
}

// ================================================================
// Element 类
// ================================================================

/// Markdown 元素（对应 Discourse 的 Element 类）
class _MdElement {
  final String name;
  final String? data;
  final List<_MdElement> children;
  final Map<String, String> attributes;
  final List<String> parentNames;
  _MdElement? prev;
  _MdElement? next;
  _MdElement? parent;

  _MdElement({
    required this.name,
    this.data,
    required this.children,
    required this.attributes,
    required this.parentNames,
  });

  /// 从 _NodeData 列表解析为 Markdown 字符串
  static String parse(List<_NodeData> nodes, [_MdElement? parent]) {
    if (nodes.isEmpty) return '';

    final elements = <_MdElement>[];
    for (final node in nodes) {
      final parentNames = parent != null
          ? [...parent.parentNames, parent.name]
          : <String>[];

      // 处理子节点
      final children = <_MdElement>[];
      for (final childNode in node.children) {
        final childParentNames = [...parentNames, node.name];
        final child = _MdElement(
          name: childNode.name,
          data: childNode.data,
          children: [], // 递归时会处理
          attributes: childNode.attributes,
          parentNames: childParentNames,
        );
        child.children.addAll(_buildChildren(childNode, child));
        children.add(child);
      }

      final element = _MdElement(
        name: node.name,
        data: node.data,
        children: children,
        attributes: node.attributes,
        parentNames: parentNames,
      );
      element.parent = parent;

      // 设置子节点的 parent
      for (final child in children) {
        child.parent = element;
      }

      elements.add(element);
    }

    // 设置兄弟节点引用
    for (var i = 0; i < elements.length; i++) {
      if (i > 0) elements[i].prev = elements[i - 1];
      if (i < elements.length - 1) elements[i].next = elements[i + 1];
    }

    // 设置子节点的兄弟引用
    for (final element in elements) {
      _setChildSiblings(element);
    }

    return elements.map((e) => e.toMarkdown()).join('');
  }

  /// 递归构建子元素
  static List<_MdElement> _buildChildren(_NodeData nodeData, _MdElement parent) {
    final result = <_MdElement>[];
    for (final childNode in nodeData.children) {
      final childParentNames = [...parent.parentNames, parent.name];
      final child = _MdElement(
        name: childNode.name,
        data: childNode.data,
        children: [],
        attributes: childNode.attributes,
        parentNames: childParentNames,
      );
      child.parent = parent;
      child.children.addAll(_buildChildren(childNode, child));
      result.add(child);
    }
    return result;
  }

  /// 设置子节点的兄弟引用
  static void _setChildSiblings(_MdElement element) {
    for (var i = 0; i < element.children.length; i++) {
      if (i > 0) element.children[i].prev = element.children[i - 1];
      if (i < element.children.length - 1) {
        element.children[i].next = element.children[i + 1];
      }
      _setChildSiblings(element.children[i]);
    }
  }

  /// 获取对应的 Tag
  _Tag tag() {
    final t = _createTag(name);
    t.element = this;
    return t;
  }

  /// 获取内部 Markdown
  String innerMarkdown() {
    if (children.isEmpty) return '';

    // 设置兄弟引用
    for (var i = 0; i < children.length; i++) {
      if (i > 0) children[i].prev = children[i - 1];
      if (i < children.length - 1) children[i].next = children[i + 1];
    }

    return children.map((c) => c.toMarkdown()).join('');
  }

  /// 转换为 Markdown
  String toMarkdown() {
    if (name == '#text') return _text();
    return tag().toMarkdown();
  }

  /// 文本节点处理
  String _text() {
    var text = data ?? '';

    if (_leftTrimmable()) text = text.trimLeft();
    if (_rightTrimmable()) text = text.trimRight();

    text = text.replaceAll(RegExp(r'[\s\t]+'), ' ');
    return text;
  }

  bool _leftTrimmable() {
    return prev != null && _trimmableTags.contains(prev!.name);
  }

  bool _rightTrimmable() {
    return next != null && _trimmableTags.contains(next!.name);
  }

  /// 过滤出匹配指定名称列表的父级名称
  List<String> filterParentNames(List<String> names) {
    return parentNames.where((p) => names.contains(p)).toList();
  }
}

// ================================================================
// 工具函数
// ================================================================

/// 从 URL 中提取文件扩展名
String? _extensionFromUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final match = RegExp(r'\.([a-zA-Z0-9]+)(?:\?|$)').firstMatch(url);
  return match?.group(1)?.toLowerCase();
}

/// 构建图片 Markdown
String _buildImageMarkdown({
  required String src,
  String? alt,
  String? width,
  String? height,
  String? title,
  bool escapeTablePipe = false,
}) {
  var altText = alt ?? '';
  final pipe = escapeTablePipe ? r'\|' : '|';

  if (width != null && height != null) {
    altText = '$altText$pipe${width}x$height';
  }

  if (title != null && title.isNotEmpty) {
    return '![$altText]($src "$title")';
  }

  return '![$altText]($src)';
}
