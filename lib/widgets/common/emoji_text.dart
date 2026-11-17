import 'package:material_ui/material_ui.dart';

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

  /// 短代码识别规则,见 [EmojiHandler.shortcodeMatches];null 跟随站点设置。
  final bool? inline;

  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.softWrap,
    this.inline,
  });

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
    return buildEmojiSpans(context, text, style, inline: inline);
  }

  /// 输入框里表情图之后的等长补位字符样式（字符数与短代码对齐，光标与
  /// 删除不错位）。补位字符本应零宽，但字体缺这个字形时会按缺字占宽，
  /// 主题的字间距也会逐字叠加——字号压到近零、间距归零，任何字体下都
  /// 不占宽度，否则表情之间会空出一大截
  static TextStyle sourceLengthFillerStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(
        color: Colors.transparent,
        fontSize: 0.01,
        letterSpacing: 0,
        wordSpacing: 0,
      );

  /// 静态方法：构建包含 emoji 的 spans 列表
  /// 可被其他组件复用
  static List<InlineSpan> buildEmojiSpans(
    BuildContext context,
    String text,
    TextStyle? style, {
    bool preserveSourceLength = false,
    bool? inline,
  }) {
    if (!text.contains(':')) {
      return [TextSpan(text: text)];
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in EmojiHandler.shortcodeMatches(text, inline: inline)) {
      // 添加 emoji 前的文本
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      final emojiName = match.group(1)!;
      // 添加 emoji 图片
      spans.add(_buildEmojiWidgetSpan(context, emojiName, style));
      if (preserveSourceLength && match.end - match.start > 1) {
        spans.add(
          TextSpan(
            text: '\u2060' * (match.end - match.start - 1),
            style: sourceLengthFillerStyle(style),
          ),
        );
      }

      lastEnd = match.end;
    }

    if (spans.isEmpty) {
      return [TextSpan(text: text)];
    }

    // 添加剩余文本
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return spans;
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
  final bool? inline;

  const SelectableEmojiText(
    this.text, {
    super.key,
    this.style,
    this.textKey,
    this.inline,
  });

  @override
  Widget build(BuildContext context) {
    final spans = EmojiText.buildEmojiSpans(
      context,
      text,
      style,
      inline: inline,
    );

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

/// 单个表情:表情名(`smile` / `:smile:` / `+1:t3`)渲染为 emoji 图,
/// Unicode emoji 字符直接按文字显示。
///
/// 用于用户状态等只存一个表情的字段。
class EmojiImage extends StatelessWidget {
  const EmojiImage(
    this.emoji, {
    super.key,
    required this.size,
    this.placeholder,
  });

  final String emoji;
  final double size;

  /// 图片加载中与加载失败时的占位;null 时不占位。
  final Widget? placeholder;

  static final _unicodeEmoji = RegExp(
    // lint 按非 unicode 模式校验,不认 \p{…}
    // ignore: valid_regexps
    r'\p{Extended_Pictographic}',
    unicode: true,
  );

  @override
  Widget build(BuildContext context) {
    if (_unicodeEmoji.hasMatch(emoji)) {
      return Text(emoji, style: TextStyle(fontSize: size, height: 1));
    }
    final fallback = placeholder ?? const SizedBox.shrink();
    return Image(
      image: emojiImageProvider(EmojiHandler().getEmojiUrl(emoji)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      frameBuilder: placeholder == null
          ? null
          : (_, child, frame, synchronous) =>
                synchronous || frame != null ? child : fallback,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
