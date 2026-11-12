import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../services/discourse_cache_manager.dart';
import '../../utils/url_helper.dart';
import '../common/emoji_text.dart';

/// 简介与帖子摘要的轻量预览，保留表情及显式分段，并按行数截断。
class CollapsedHtmlContent extends StatelessWidget {
  final String html;
  final TextStyle? textStyle;
  final int maxLines;
  final TextOverflow overflow;

  const CollapsedHtmlContent({
    super.key,
    required this.html,
    this.textStyle,
    this.maxLines = 2,
    this.overflow = TextOverflow.ellipsis,
  });

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(textStyle);
    final fragment = html_parser.parseFragment(html);
    final spans = <InlineSpan>[];
    final text = StringBuffer();

    // HTML 源码的缩进、换行均为空格；只有标签产生实际的分段。
    void appendText(String value) {
      text.write(value.replaceAll(RegExp(r'\s+'), ' '));
    }

    void flushText({bool last = false}) {
      var value = text
          .toString()
          .replaceAll(RegExp(r'[^\S\n]+'), ' ')
          .replaceAll(RegExp(r' *\n\s*'), '\n');
      if (spans.isEmpty) value = value.trimLeft();
      if (last) value = value.trimRight();
      if (value.isNotEmpty) {
        spans.addAll(EmojiText.buildEmojiSpans(context, value, style));
      }
      text.clear();
    }

    void appendNode(dom.Node node) {
      if (node is dom.Text) {
        appendText(node.data);
        return;
      }
      if (node is! dom.Element) return;

      switch (node.localName) {
        case 'script' || 'style' || 'template':
          return;
        case 'br':
          text.writeln();
          return;
        case 'img':
          final alt = node.attributes['alt'] ?? node.attributes['title'] ?? '';
          final src = node.attributes['src'];
          if (node.classes.contains('emoji') && src?.isNotEmpty == true) {
            flushText();
            final size = (style.fontSize ?? 14) * 1.2;
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Image(
                  image: emojiImageProvider(UrlHelper.resolveUrlWithCdn(src!)),
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                  semanticLabel: alt,
                  errorBuilder: (_, _, _) => Text(alt, style: style),
                ),
              ),
            );
          } else {
            appendText(alt);
          }
          return;
      }

      // 摘要压缩连续空段，但保留正文、列表与显式换行的阅读顺序。
      final block = switch (node.localName) {
        'p' ||
        'div' ||
        'blockquote' ||
        'pre' ||
        'li' ||
        'tr' ||
        'h1' ||
        'h2' ||
        'h3' ||
        'h4' ||
        'h5' ||
        'h6' => true,
        _ => false,
      };
      if (block) text.writeln();
      for (final child in node.nodes) {
        appendNode(child);
      }
      if (block) text.writeln();
    }

    for (final node in fragment.nodes) {
      appendNode(node);
    }
    flushText(last: true);

    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
      style: textStyle,
    );
  }
}
