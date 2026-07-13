import 'package:flutter/material.dart';
import '../callout/callout_builder.dart';
import '../callout/callout_config.dart';
import 'eye_care_quote_style.dart';

/// 构建普通引用块 (支持 Obsidian Callout)
Widget buildBlockquote({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Widget Function(String html, TextStyle? textStyle) htmlBuilder,
}) {
  final innerHtml = element.innerHtml as String;

  // 尝试解析 Obsidian Callout: [!type], [!type]+ (展开), [!type]- (折叠)
  // 只取当前 blockquote 的首个直接 <p> 内容，避免嵌套 blockquote 干扰
  String? firstLineText;
  String? firstLineHtml;
  final directParagraphs =
      element.children?.where((e) => e.localName == 'p').toList() ?? const [];
  if (directParagraphs.isNotEmpty) {
    final firstParagraphHtml = directParagraphs.first.innerHtml;
    final brMatch = RegExp(r'<br\s*/?>', caseSensitive: false)
        .firstMatch(firstParagraphHtml);
    firstLineHtml =
        brMatch == null ? firstParagraphHtml : firstParagraphHtml.substring(0, brMatch.start);
    final htmlWithLineBreaks =
        firstParagraphHtml.replaceAll(RegExp(r'<br\s*/?>'), '\n');
    final textContent = htmlWithLineBreaks.replaceAll(RegExp(r'<[^>]*>'), '');
    firstLineText = textContent.trim().split(RegExp(r'[\n\r]')).first.trim();
  } else {
    final htmlWithLineBreaks = innerHtml.replaceAll(RegExp(r'<br\s*/?>'), '\n');
    final textContent = htmlWithLineBreaks.replaceAll(RegExp(r'<[^>]*>'), '');
    firstLineText = textContent.trim().split(RegExp(r'[\n\r]')).first.trim();
  }

  // 匹配 [!type], [!type]+, [!type]- 以及可选的标题
  final calloutMatch =
      RegExp(r'^\[!([^\]]+)\]([+-])?\s*(.*)').firstMatch(firstLineText ?? '');

  if (calloutMatch != null) {
    var type = calloutMatch.group(1)!.trim().toLowerCase();
    final foldMarker = calloutMatch.group(2); // + 或 - 或 null
    final titleText = calloutMatch.group(3)?.trim();
    String? titleHtml;
    if (firstLineHtml != null) {
      titleHtml = firstLineHtml
          .replaceFirst(RegExp(r'^\s*\[![^\]]+\][+-]?\s*'), '')
          .trim();
      if (titleHtml.isEmpty) {
        titleHtml = null;
      }
    }

    if (!isKnownCalloutType(type)) {
      type = 'note';
    }

    // 确定折叠状态: null=不可折叠, true=默认展开, false=默认折叠
    bool? foldable;
    if (foldMarker == '+') {
      foldable = true; // 可折叠，默认展开
    } else if (foldMarker == '-') {
      foldable = false; // 可折叠，默认折叠
    }

    return buildCalloutBlock(
      context: context,
      theme: theme,
      innerHtml: innerHtml,
      type: type,
      title: titleText,
      titleHtml: titleHtml,
      foldable: foldable,
      htmlBuilder: htmlBuilder,
    );
  }

  // 普通引用块；护眼气泡开启时用半透明叠色，避免盖住楼主绿/回帖黄
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    decoration: BoxDecoration(
      color: eyeCareAwareQuoteBackground(context, theme),
      border: Border(
        left: BorderSide(
          color: eyeCareAwareQuoteBorder(context, theme),
          width: 4,
        ),
      ),
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(4),
        bottomRight: Radius.circular(4),
      ),
    ),
    child: htmlBuilder(
      innerHtml,
      theme.textTheme.bodyMedium?.copyWith(
        height: 1.5,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
