import 'package:flutter/painting.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

String highlightQuoteExcerpt(
  String cooked,
  String excerpt, {
  required Color background,
  required Color foreground,
}) {
  final whitespace = RegExp(r'\s+');
  final needle = excerpt.replaceAll(whitespace, '');
  if (needle.isEmpty || cooked.isEmpty) return cooked;
  final fragment = html.parseFragment(cooked);
  final textNodes = <dom.Text>[];
  final buffer = StringBuffer();
  void collect(dom.Node node) {
    if (node is dom.Text) {
      textNodes.add(node);
      buffer.write(node.data);
    } else {
      for (final child in node.nodes) {
        collect(child);
      }
    }
  }

  collect(fragment);
  final text = buffer.toString();
  final offsets = <int>[];
  final compact = StringBuffer();
  for (final run in RegExp(r'\S+').allMatches(text)) {
    compact.write(run[0]);
    for (var index = run.start; index < run.end; index++) {
      offsets.add(index);
    }
  }
  final haystack = compact.toString();
  var target = needle;
  var position = haystack.indexOf(target);
  if (position == -1) {
    target = target.replaceFirst(RegExp(r'(?:…|\.{3})$'), '');
    if (target.isEmpty || target == needle) return cooked;
    position = haystack.indexOf(target);
  }
  if (position == -1 || haystack.indexOf(target, position + 1) != -1) {
    return cooked;
  }
  final matchStart = offsets[position];
  final matchEnd = offsets[position + target.length - 1] + 1;
  String hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
  final style = 'background-color:${hex(background)};color:${hex(foreground)}';
  var offset = 0;
  for (final node in textNodes) {
    final original = node.data;
    final start = (matchStart - offset).clamp(0, original.length);
    final end = (matchEnd - offset).clamp(0, original.length);
    offset += original.length;
    if (start < end) {
      final parent = node.parentNode!;
      if (start > 0) {
        parent.insertBefore(dom.Text(original.substring(0, start)), node);
      }
      parent.insertBefore(
        dom.Element.tag('span')
          ..attributes['style'] = style
          ..text = original.substring(start, end),
        node,
      );
      if (end < original.length) {
        parent.insertBefore(dom.Text(original.substring(end)), node);
      }
      node.remove();
    }
    if (offset >= matchEnd) break;
  }
  return fragment.outerHtml;
}
