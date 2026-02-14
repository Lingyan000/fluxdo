import 'package:flutter/material.dart';
import '../../services/emoji_handler.dart';
import '../../services/discourse_cache_manager.dart';

/// 轻量级 Emoji 文本组件
/// 
/// 将文本中的 :emoji_name: 替换为图片显示，
/// 使用 Text.rich + WidgetSpan 实现，无需完整 HTML 渲染库。
class EmojiText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final bool? softWrap;

  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.softWrap,
  });

  // 匹配 :emoji_name: 模式
  static final RegExp emojiRegex = RegExp(r':([a-zA-Z0-9_+-]+):');

  @override
  Widget build(BuildContext context) {
    final spans = _buildSpans(context);
    
    // 如果没有 emoji，直接返回普通 Text
    if (spans.length == 1 && spans.first is TextSpan) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
        softWrap: softWrap,
      );
    }

    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      softWrap: softWrap,
    );
  }

  List<InlineSpan> _buildSpans(BuildContext context) {
    return buildEmojiSpans(context, text, style);
  }

  /// 静态方法：构建包含 emoji 的 spans 列表
  /// 可被其他组件复用
  static List<InlineSpan> buildEmojiSpans(BuildContext context, String text, TextStyle? style) {
    final matches = emojiRegex.allMatches(text);
    
    if (matches.isEmpty) {
      return [TextSpan(text: text)];
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      // 添加 emoji 前的文本
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      // 添加 emoji 图片
      final emojiName = match.group(1)!;
      spans.add(_buildEmojiWidgetSpan(context, emojiName, style));

      lastEnd = match.end;
    }

    // 添加剩余文本
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return spans;
  }

  static WidgetSpan _buildEmojiWidgetSpan(BuildContext context, String emojiName, TextStyle? style) {
    // 获取当前文字大小，emoji 稍大于文字
    final fontSize = style?.fontSize ?? 
        DefaultTextStyle.of(context).style.fontSize ?? 
        14.0;
    final emojiSize = fontSize * 1.2;

    // 获取 emoji URL
    final emojiUrl = EmojiHandler().getEmojiUrl(emojiName);

    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Image(
          image: discourseImageProvider(emojiUrl),
          width: emojiSize,
          height: emojiSize,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            // 加载失败时显示原文本
            return Text(
              ':$emojiName:',
              style: style?.copyWith(fontSize: fontSize) ?? 
                  TextStyle(fontSize: fontSize),
            );
          },
        ),
      ),
    );
  }
}

/// 可选择的 Emoji 文本组件
/// 
/// 用于需要支持文本选择的场景（如话题详情页标题）
class SelectableEmojiText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final GlobalKey? textKey;

  const SelectableEmojiText(
    this.text, {
    super.key,
    this.style,
    this.textKey,
  });

  @override
  Widget build(BuildContext context) {
    final spans = EmojiText.buildEmojiSpans(context, text, style);
    
    // 如果没有 emoji，直接返回普通 SelectableText
    if (spans.length == 1 && spans.first is TextSpan) {
      return SelectableText(
        text,
        key: textKey,
        style: style,
      );
    }

    return SelectableText.rich(
      TextSpan(children: spans),
      key: textKey,
      style: style,
    );
  }
}

