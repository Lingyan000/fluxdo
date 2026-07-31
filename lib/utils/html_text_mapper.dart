import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

/// 纯文本到 HTML 的映射器
///
/// 根据选中的纯文本反查原始 HTML 片段，用于划词引用功能。
/// 核心思路：DFS 遍历 DOM 文本节点，构建偏移映射，子串匹配定位对应 HTML。
class HtmlTextMapper {
  /// 从 cooked HTML 中提取与选中纯文本对应的 HTML 片段
  ///
  /// [cooked] 帖子的 HTML 内容 (post.cooked)
  /// [selectedPlainText] 用户选中的纯文本
  ///
  /// 全选整帖时直接返回完整 [cooked]（子串反查对图片等占位符文本的还原
  /// 不完全可靠，全选场景没必要冒这个险；放在这里而不是调用方，是让
  /// 划词引用/复制引用/回复弹层等所有入口统一受益）。
  ///
  /// 返回对应的 HTML 片段，如果无法匹配则返回 null
  static String? extractHtml(String cooked, String selectedPlainText) {
    if (cooked.isEmpty || selectedPlainText.isEmpty) return null;

    try {
      final fragment = html_parser.parseFragment(cooked);

      // 1. DFS 收集所有文本节点和对应的偏移量
      final textNodes = <_TextNodeInfo>[];
      final fullTextBuffer = StringBuffer();
      _collectTextNodes(fragment, textNodes, fullTextBuffer);

      final fullText = fullTextBuffer.toString();
      if (fullText.isEmpty) return null;

      // 2. 规范化后查找匹配位置
      final normalizedFull = _normalize(fullText);
      final normalizedSelected = _normalize(selectedPlainText);
      if (normalizedSelected.isEmpty) return null;

      // 全选：整帖即"对应片段"
      if (normalizedFull == normalizedSelected) return cooked;

      final matchStart = normalizedFull.indexOf(normalizedSelected);
      if (matchStart == -1) return null;
      final matchEnd = matchStart + normalizedSelected.length;

      // 3. 将规范化偏移量映射回原始偏移量
      final originalStart = _mapNormalizedOffset(fullText, matchStart);
      final originalEnd = _mapNormalizedOffset(fullText, matchEnd);
      if (originalStart == null || originalEnd == null) return null;

      // 4. 找到涉及的文本节点范围
      final involvedNodes = <_TextNodeInfo>[];
      for (final info in textNodes) {
        final nodeEnd = info.offset + info.length;
        if (nodeEnd > originalStart && info.offset < originalEnd) {
          involvedNodes.add(info);
        }
      }

      if (involvedNodes.isEmpty) return null;

      // 5. 提取 HTML 片段
      final startNode = involvedNodes.first;
      final endNode = involvedNodes.last;

      // 单文本节点
      if (involvedNodes.length == 1) {
        final isFullySelected = originalStart <= startNode.offset &&
            originalEnd >= startNode.offset + startNode.length;
        final codeContainer = _findCodeContainer(startNode.node);

        if (codeContainer != null) {
          final text = startNode.node.text ?? '';
          final trimStart = (originalStart - startNode.offset).clamp(0, text.length);
          final trimEnd = (originalEnd - startNode.offset).clamp(trimStart, text.length);
          final selectedCode = text.substring(trimStart, trimEnd);
          if (selectedCode.isEmpty) return null;
          return _buildPartialCodeHtml(codeContainer, selectedCode);
        }

        if (isFullySelected) {
          // 完整选中：返回父元素 HTML（保留 <b>、<em> 等格式标记）。
          // 但前提是父元素的全部文本内容 == 本节点文本 —— 否则父元素是
          // <p> 这类块级容器、内部还有其他 <br> 分隔的兄弟行/文本,
          // outerHtml 会把没选中的兄弟内容也带出来(实测:只选中三行中
          // 的一行,复制引用/引用出来变成整段三行)。这种情况没有格式
          // 需要保留,退化成纯文本更安全。
          final parent = startNode.node.parentNode;
          if (parent is dom.Element &&
              _normalize(parent.text) == _normalize(startNode.node.text ?? '')) {
            return parent.outerHtml;
          }
        }
        // 部分选中：纯文本节点内部没有格式需要保留，返回 null 降级纯文本
        return null;
      }

      // 多文本节点：找最小公共祖先
      final lca = _findLCA(startNode.node, endNode.node);
      if (lca == null) return null;

      // 提取 LCA 中仅覆盖选中范围的子节点，裁剪边界文本
      return _extractRelevantChildren(
        lca, involvedNodes, originalStart, originalEnd,
      );
    } catch (_) {
      return null;
    }
  }

  /// 如果节点位于代码块中，返回最外层的代码块容器（优先 pre，其次 code）
  static dom.Element? _findCodeContainer(dom.Node node) {
    dom.Node? current = node;
    dom.Element? codeElement;

    while (current != null) {
      if (current is dom.Element) {
        final name = current.localName?.toLowerCase();
        if (name == 'pre') {
          return current;
        }
        if (name == 'code') {
          codeElement ??= current;
        }
      }
      current = current.parentNode;
    }

    return codeElement;
  }

  /// 构建仅包含选中代码文本的 HTML，保留代码块语义
  static String _buildPartialCodeHtml(dom.Element container, String selectedCode) {
    final escapedCode = _escapeHtml(selectedCode);
    final name = container.localName?.toLowerCase();

    if (name == 'pre') {
      final codeChild = container.children
          .where((child) => child.localName?.toLowerCase() == 'code')
          .firstOrNull;
      if (codeChild != null) {
        final codeAttrs = _serializeAttributes(codeChild.attributes);
        return '<pre><code$codeAttrs>$escapedCode</code></pre>';
      }
      return '<pre><code>$escapedCode</code></pre>';
    }

    final attrs = _serializeAttributes(container.attributes);
    return '<code$attrs>$escapedCode</code>';
  }

  static String _extractSelectedTextFromContainer(
    dom.Element container,
    List<_TextNodeInfo> involvedNodes,
    int originalStart,
    int originalEnd,
  ) {
    final textInfos = involvedNodes
        .where((info) =>
            info.node.nodeType == dom.Node.TEXT_NODE &&
            _containsNode(container, info.node))
        .toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));

    final buffer = StringBuffer();
    for (final info in textInfos) {
      final text = info.node.text ?? '';
      final trimStart = (originalStart - info.offset).clamp(0, text.length);
      final trimEnd = (originalEnd - info.offset).clamp(trimStart, text.length);
      if (trimStart >= trimEnd) continue;
      buffer.write(text.substring(trimStart, trimEnd));
    }

    return buffer.toString();
  }

  static String _serializeAttributes(Map<dynamic, String> attributes) {
    if (attributes.isEmpty) return '';

    final buffer = StringBuffer();
    attributes.forEach((key, value) {
      buffer.write(' $key="${_escapeHtml(value)}"');
    });
    return buffer.toString();
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  /// 从 LCA 中只提取覆盖选中范围的子节点 HTML
  ///
  /// 而非返回整个 LCA 的 outerHtml，避免引用整段。
  /// 边界的纯文本节点会根据选中范围裁剪。
  static String? _extractRelevantChildren(
    dom.Node lca,
    List<_TextNodeInfo> involvedNodes,
    int originalStart,
    int originalEnd,
  ) {
    final children = lca.nodes.toList();
    if (children.isEmpty) {
      if (lca is dom.Element) return lca.outerHtml;
      return lca.text;
    }

    // 找第一个和最后一个包含选中节点的直接子节点索引
    int startIdx = -1;
    int endIdx = -1;

    final firstInvolved = involvedNodes.first.node;
    final lastInvolved = involvedNodes.last.node;

    for (int i = 0; i < children.length; i++) {
      if (startIdx == -1 && _containsNode(children[i], firstInvolved)) {
        startIdx = i;
      }
      if (_containsNode(children[i], lastInvolved)) {
        endIdx = i;
        break;
      }
    }

    if (startIdx == -1 || endIdx == -1) {
      if (lca is dom.Element) return lca.outerHtml;
      return lca.text;
    }

    // 拼接覆盖范围内的子节点 HTML，裁剪边界文本节点
    final buffer = StringBuffer();
    for (int i = startIdx; i <= endIdx; i++) {
      final child = children[i];
      final isBoundaryChild = i == startIdx || i == endIdx;

      if (child is dom.Element) {
        if (isBoundaryChild) {
          final partial = _extractNodeHtml(
            child,
            involvedNodes,
            originalStart,
            originalEnd,
          );
          buffer.write(partial ?? child.outerHtml);
        } else {
          buffer.write(child.outerHtml);
        }
      } else if (child.nodeType == dom.Node.TEXT_NODE) {
        final text = child.text ?? '';
        // 查找该文本节点对应的偏移信息
        final info = involvedNodes
            .where((n) => identical(n.node, child))
            .firstOrNull;

        if (info != null) {
          // 根据选中范围裁剪边界文本节点
          int trimStart = 0;
          int trimEnd = text.length;

          if (i == startIdx && originalStart > info.offset) {
            trimStart = originalStart - info.offset;
          }
          if (i == endIdx && originalEnd < info.offset + info.length) {
            trimEnd = originalEnd - info.offset;
          }

          trimEnd = trimEnd.clamp(trimStart, text.length);
          buffer.write(text.substring(trimStart, trimEnd));
        } else {
          // 不在 involvedNodes 中但在 startIdx..endIdx 之间（中间的文本节点）
          buffer.write(text);
        }
      }
    }

    final result = buffer.toString();
    return result.isEmpty ? null : result;
  }

  /// 递归提取边界节点中实际被选中的 HTML
  static String? _extractNodeHtml(
    dom.Node node,
    List<_TextNodeInfo> involvedNodes,
    int originalStart,
    int originalEnd,
  ) {
    if (node.nodeType == dom.Node.TEXT_NODE) {
      final info = involvedNodes.where((n) => identical(n.node, node)).firstOrNull;
      if (info == null) return null;

      final text = node.text ?? '';
      final trimStart = (originalStart - info.offset).clamp(0, text.length);
      final trimEnd = (originalEnd - info.offset).clamp(trimStart, text.length);
      final selected = text.substring(trimStart, trimEnd);
      return selected.isEmpty ? null : selected;
    }

    if (node is! dom.Element) return null;

    final name = node.localName?.toLowerCase();
    if (name == 'pre' || name == 'code') {
      final selectedCode = _extractSelectedTextFromContainer(
        node,
        involvedNodes,
        originalStart,
        originalEnd,
      );
      if (selectedCode.isEmpty) return null;
      return _buildPartialCodeHtml(node, selectedCode);
    }

    final buffer = StringBuffer();
    for (final child in node.nodes) {
      if (!_containsAnyInvolvedNode(child, involvedNodes)) continue;

      final extracted = _extractNodeHtml(
        child,
        involvedNodes,
        originalStart,
        originalEnd,
      );
      if (extracted != null) {
        buffer.write(extracted);
      }
    }

    final innerHtml = buffer.toString();
    if (innerHtml.isEmpty) return null;

    final attrs = _serializeAttributes(node.attributes);
    return '<${node.localName}$attrs>$innerHtml</${node.localName}>';
  }

  static bool _containsAnyInvolvedNode(dom.Node parent, List<_TextNodeInfo> involvedNodes) {
    for (final info in involvedNodes) {
      if (_containsNode(parent, info.node)) {
        return true;
      }
    }
    return false;
  }

  /// 检查 parent 是否包含 target 节点（包括 parent 自身）
  static bool _containsNode(dom.Node parent, dom.Node target) {
    if (identical(parent, target)) return true;
    for (final child in parent.nodes) {
      if (_containsNode(child, target)) return true;
    }
    return false;
  }

  /// DFS 遍历收集所有文本节点
  static void _collectTextNodes(
    dom.Node node,
    List<_TextNodeInfo> result,
    StringBuffer buffer,
  ) {
    // lightbox 锚点整体视为一张图,只收集内部 <img>(title/alt 投影文本),
    // 其余子节点全部吞掉——对齐官方 parseDOM 的 `a.lightbox` 规则
    // (prosemirror extensions/image.js 只从锚点里取 img)。悬浮遮罩层
    // `<div class="meta">` 的文件名/尺寸是纯 CSS hover 内容,渲染选区投影
    // 里不存在,计入缓冲区会与 img 的 title/alt 撞车,把后续偏移量全部
    // 错位,导致选区跨过图片时反查失败、退化成裸文本。
    if (node is dom.Element &&
        node.localName == 'a' &&
        (node.classes.contains('lightbox') ||
            node.classes.contains('d-lazyload'))) {
      final img = node.querySelector('img');
      if (img != null) {
        _collectTextNodes(img, result, buffer);
      }
      return;
    }

    if (node.nodeType == dom.Node.TEXT_NODE) {
      final text = node.text ?? '';
      if (text.isNotEmpty) {
        result.add(_TextNodeInfo(
          node: node,
          offset: buffer.length,
          length: text.length,
        ));
        buffer.write(text);
      }
      return;
    }

    // 块级元素添加换行
    if (node is dom.Element && _isBlockElement(node.localName ?? '')) {
      if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
        result.add(_TextNodeInfo(
          node: node,
          offset: buffer.length,
          length: 1,
        ));
        buffer.write('\n');
      }
    }

    // br 标签
    if (node is dom.Element && node.localName == 'br') {
      result.add(_TextNodeInfo(
        node: node,
        offset: buffer.length,
        length: 1,
      ));
      buffer.write('\n');
      return;
    }

    // img 标签：用 title 或 alt 作为替代文本
    // SelectableAdapter 使 emoji 被选中时返回 title 文本，
    // 这里需要匹配使其与 SelectionArea 返回的 plainText 一致
    if (node is dom.Element && node.localName == 'img') {
      final alt = node.attributes['title'] ?? node.attributes['alt'] ?? '';
      if (alt.isNotEmpty) {
        result.add(_TextNodeInfo(
          node: node,
          offset: buffer.length,
          length: alt.length,
        ));
        buffer.write(alt);
      }
      return;
    }

    for (final child in node.nodes) {
      _collectTextNodes(child, result, buffer);
    }

    // 块级元素结尾添加换行
    if (node is dom.Element && _isBlockElement(node.localName ?? '')) {
      if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
        buffer.write('\n');
      }
    }
  }

  /// 规范化文本：剥离特殊字符，折叠空白
  static String _normalize(String text) {
    return text
        .replaceAll('\u200B', '') // 零宽空格
        .replaceAll('\u00A0', ' ') // 不换行空格
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 将规范化后的偏移量映射回原始文本偏移量
  static int? _mapNormalizedOffset(String original, int normalizedOffset) {
    var nOffset = 0;
    var oOffset = 0;
    var inWhitespace = false;
    var started = false;

    while (oOffset <= original.length && nOffset <= normalizedOffset) {
      if (nOffset == normalizedOffset) return oOffset;

      if (oOffset >= original.length) break;

      final char = original[oOffset];

      // 跳过零宽空格
      if (char == '\u200B') {
        oOffset++;
        continue;
      }

      // 不换行空格 → 普通空格
      final normalizedChar = char == '\u00A0' ? ' ' : char;

      if (RegExp(r'\s').hasMatch(normalizedChar)) {
        if (!started) {
          // 前导空白被 trim 掉了
          oOffset++;
          continue;
        }
        if (!inWhitespace) {
          inWhitespace = true;
          nOffset++; // 折叠为单个空格
        }
        oOffset++;
      } else {
        started = true;
        inWhitespace = false;
        nOffset++;
        oOffset++;
      }
    }

    return nOffset == normalizedOffset ? oOffset : null;
  }

  /// 找两个节点的最小公共祖先 (LCA)
  static dom.Node? _findLCA(dom.Node a, dom.Node b) {
    final ancestorsA = <dom.Node>{};
    dom.Node? current = a;
    while (current != null) {
      ancestorsA.add(current);
      current = current.parentNode;
    }

    current = b;
    while (current != null) {
      if (ancestorsA.contains(current)) return current;
      current = current.parentNode;
    }

    return null;
  }

  /// 判断是否为块级元素
  static bool _isBlockElement(String name) {
    return const {
      'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'blockquote', 'pre', 'ul', 'ol', 'li', 'table', 'tr',
      'td', 'th', 'section', 'article', 'aside', 'header',
      'footer', 'nav', 'figure', 'figcaption', 'details',
      'summary', 'hr',
    }.contains(name);
  }
}

/// 文本节点信息
class _TextNodeInfo {
  final dom.Node node;
  final int offset;
  final int length;

  _TextNodeInfo({
    required this.node,
    required this.offset,
    required this.length,
  });
}
