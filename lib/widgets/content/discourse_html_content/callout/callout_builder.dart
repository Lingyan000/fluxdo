import 'package:flutter/material.dart';
import 'callout_config.dart';
import 'foldable_callout.dart';

/// 构建 Obsidian Callout 块
/// [foldable]: null=不可折叠, true=可折叠默认展开, false=可折叠默认折叠
Widget buildCalloutBlock({
  required BuildContext context,
  required ThemeData theme,
  required String innerHtml,
  required String type,
  required String? title,
  required String? titleHtml,
  required bool? foldable,
  required Widget Function(String html, TextStyle? textStyle) htmlBuilder,
}) {
  final config = getCalloutConfig(type);

  // 移除 callout 标记，保留其他内容
  // 注意：只处理 <p> 标签内的标记，不要影响 <pre>/<code> 和嵌套 blockquote 内的内容
  var contentHtml = innerHtml;

  // 只在嵌套 blockquote 之前的部分执行清理，避免破坏嵌套 callout 标记
  final nestedBlockquoteIndex = contentHtml.indexOf('<blockquote');
  var cleanPart = nestedBlockquoteIndex != -1
      ? contentHtml.substring(0, nestedBlockquoteIndex)
      : contentHtml;
  final preservedPart = nestedBlockquoteIndex != -1
      ? contentHtml.substring(nestedBlockquoteIndex)
      : '';

  // 情况1: <p>[!type]...<br> 格式，移除标记和标题，但保留 <p> 和后续内容
  cleanPart = cleanPart.replaceFirst(
    RegExp(r'<p>\s*\[![^\]]+\][+-]?.*?<br\s*/?>', dotAll: true),
    '<p>',
  );

  // 情况2: <p>[!type]...</p> 格式，整个 <p> 只包含标记/标题
  cleanPart = cleanPart.replaceFirst(
    RegExp(r'<p>\s*\[![^\]]+\][+-]?.*?</p>', dotAll: true),
    '',
  );

  contentHtml = cleanPart + preservedPart;

  // 清理空的 <p></p> 标签
  contentHtml = contentHtml.replaceAll(RegExp(r'<p>\s*</p>'), '');

  // 清理 <p> 标签后的前导空白（保留 <pre> 内的格式）
  contentHtml = contentHtml.replaceAll(RegExp(r'<p>\s+'), '<p>');
  contentHtml = contentHtml.trim();

  // 检查内容是否实际为空（排除代码块内容）
  // 先移除 <pre>...</pre> 和 <code>...</code>，再检查剩余文本
  final withoutCodeBlocks = contentHtml
      .replaceAll(RegExp(r'<pre>.*?</pre>', dotAll: true), '')
      .replaceAll(RegExp(r'<code>.*?</code>', dotAll: true), '');
  final textOnly = withoutCodeBlocks.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  // 如果有代码块，即使 textOnly 为空也算有内容
  final hasCodeBlock = contentHtml.contains('<pre>') || contentHtml.contains('<code>');
  final hasContent = textOnly.isNotEmpty || hasCodeBlock;

  final titleStyle = theme.textTheme.titleSmall?.copyWith(
    fontWeight: FontWeight.w500,
    color: config.color,
  );

  String? wrappedTitleHtml;
  if (titleHtml != null && titleHtml.isNotEmpty) {
    final colorHex = config.color.toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2);
    wrappedTitleHtml = '<span class="callout-title" style="color:#$colorHex">$titleHtml</span>';
  }

  Widget titleWidget;
  if (wrappedTitleHtml != null) {
    titleWidget = htmlBuilder(wrappedTitleHtml, titleStyle);
  } else {
    titleWidget = Text(
      title?.isNotEmpty == true ? title! : config.defaultTitle,
      style: titleStyle,
    );
  }

  // 构建标题行
  Widget titleRow = Row(
    children: [
      Icon(config.icon, size: 18, color: config.color),
      const SizedBox(width: 8),
      Expanded(
        child: titleWidget,
      ),
      if (foldable != null)
        Icon(
          Icons.expand_more,
          size: 18,
          color: config.color.withValues(alpha: 0.7),
        ),
    ],
  );

  // 构建内容
  Widget? contentWidget;
  if (hasContent) {
    contentWidget = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: htmlBuilder(
        contentHtml,
        theme.textTheme.bodyMedium?.copyWith(
          height: 1.5,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  // 如果可折叠，使用 FoldableCallout
  if (foldable != null && hasContent) {
    return FoldableCallout(
      config: config,
      titleWidget: titleWidget,
      contentWidget: contentWidget!,
      initiallyExpanded: foldable,
    );
  }

  // 不可折叠的普通 Callout
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      color: config.color.withValues(alpha: 0.1),
      border: Border(
        left: BorderSide(
          color: config.color,
          width: 4,
        ),
      ),
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(4),
        bottomRight: Radius.circular(4),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, hasContent ? 0 : 8),
          child: titleRow,
        ),
        if (contentWidget != null) contentWidget,
      ],
    ),
  );
}
