import 'package:flutter/material.dart';
import '../../services/emoji_handler.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/emoji_shortcodes.dart';

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
  static final RegExp emojiRegex = emojiShortcodeRegex;

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
  static List<InlineSpan> buildEmojiSpans(
    BuildContext context,
    String text,
    TextStyle? style, {
    bool preserveSourceLength = false,
  }) {
    // 同时处理两种形态,统一换成站内 emoji 图片:
    // - `:shortcode:` 文本;
    // - 裸 Unicode emoji 字符 —— Windows 系统字体缺新版 emoji 会渲染成
    //   方块(tofu),经 Discourse 官方对照表转成 shortcode 后走图片。
    EmojiHandler().ensureUnicodeMapLoaded();

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    void addPlainText(String segment) {
      _addTextScanningUnicodeEmoji(
        context,
        spans,
        segment,
        style,
        preserveSourceLength: preserveSourceLength,
      );
    }

    for (final match in emojiRegex.allMatches(text)) {
      // 添加 emoji 前的文本
      if (match.start > lastEnd) {
        addPlainText(text.substring(lastEnd, match.start));
      }

      final emojiName = match.group(1)!;
      // 添加 emoji 图片
      spans.add(_buildEmojiWidgetSpan(context, emojiName, style));
      if (preserveSourceLength && match.end - match.start > 1) {
        spans.add(
          TextSpan(
            text: '\u2060' * (match.end - match.start - 1),
            style: style?.copyWith(color: Colors.transparent),
          ),
        );
      }

      lastEnd = match.end;
    }

    // 添加剩余文本
    if (lastEnd < text.length) {
      addPlainText(text.substring(lastEnd));
    }

    if (spans.isEmpty) return [TextSpan(text: text)];
    return spans;
  }

  /// 把纯文本段落追加进 [spans],其中的裸 Unicode emoji 替换为站内图片。
  static void _addTextScanningUnicodeEmoji(
    BuildContext context,
    List<InlineSpan> spans,
    String segment,
    TextStyle? style, {
    required bool preserveSourceLength,
  }) {
    final handler = EmojiHandler();
    int plainStart = 0;
    int i = 0;
    while (i < segment.length) {
      if (!EmojiHandler.maybeEmojiStart(segment.codeUnitAt(i))) {
        i++;
        continue;
      }
      final matched = handler.matchUnicodeEmoji(segment, i);
      if (matched == null) {
        i++;
        continue;
      }
      final (name, units) = matched;
      if (plainStart < i) {
        spans.add(TextSpan(text: segment.substring(plainStart, i)));
      }
      spans.add(_buildEmojiWidgetSpan(context, name, style));
      if (preserveSourceLength && units > 1) {
        spans.add(
          TextSpan(
            text: '⁠' * (units - 1),
            style: style?.copyWith(color: Colors.transparent),
          ),
        );
      }
      i += units;
      plainStart = i;
    }
    if (plainStart < segment.length) {
      spans.add(TextSpan(text: segment.substring(plainStart)));
    }
  }

  static WidgetSpan _buildEmojiWidgetSpan(
    BuildContext context,
    String emojiName,
    TextStyle? style,
  ) {
    // 获取当前文字大小，emoji 稍大于文字
    final fontSize =
        style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14.0;
    final emojiSize = fontSize * 1.2;

    // 获取 emoji URL
    final emojiUrl = EmojiHandler().getEmojiUrl(emojiName);

    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Image(
          image: emojiImageProvider(emojiUrl),
          width: emojiSize,
          height: emojiSize,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            // 加载失败时显示原文本
            return Text(
              ':$emojiName:',
              style:
                  style?.copyWith(fontSize: fontSize) ??
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

  const SelectableEmojiText(this.text, {super.key, this.style, this.textKey});

  @override
  Widget build(BuildContext context) {
    final spans = EmojiText.buildEmojiSpans(context, text, style);

    // 如果没有 emoji，直接返回普通 SelectableText
    if (spans.length == 1 && spans.first is TextSpan) {
      return SelectableText(text, key: textKey, style: style);
    }

    return SelectableText.rich(
      TextSpan(children: spans),
      key: textKey,
      style: style,
    );
  }
}
