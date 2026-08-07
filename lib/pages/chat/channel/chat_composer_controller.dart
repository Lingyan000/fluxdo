import 'package:flutter/material.dart';

import '../../../services/discourse_cache_manager.dart';
import '../../../services/emoji_handler.dart';
import '../../../utils/emoji_shortcodes.dart';

/// 聊天输入框控制器:把 :shortcode: 内联渲染成 emoji 图
///
/// 只改显示层(buildTextSpan),text 值仍是原始 shortcode 文本——
/// 草稿/发送/@补全等一切基于 text 的逻辑零感知;退格按底层字符删,
/// 删到 shortcode 不完整时自动还原为文本形态。
class ChatComposerController extends TextEditingController {
  ChatComposerController({super.text});

  static final RegExp _shortcode = RegExp(r':([a-zA-Z0-9_+\-]+):');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    if (text.isEmpty || !text.contains(':')) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    // IME 组合区间内不做替换(避免拼音候选时闪烁/区间错位)
    final composing = withComposing && value.composing.isValid
        ? value.composing
        : null;

    final handler = EmojiHandler();
    final children = <InlineSpan>[];
    var cursor = 0;
    final fontSize = style?.fontSize ?? 16;
    final emojiSize = fontSize * 1.35;

    for (final match in _shortcode.allMatches(text)) {
      if (composing != null &&
          match.start < composing.end &&
          match.end > composing.start) {
        continue; // 与组合区间重叠,保持原文
      }
      final name = normalizeEmojiShortcodeName(match.group(1)!);
      final url = handler.getEmojiUrl(name);
      if (url.isEmpty) continue; // 不是已知 emoji,保持原文
      if (match.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Image(
            image: emojiImageProvider(url),
            width: emojiSize,
            height: emojiSize,
            // 加载完成前占位同尺寸,避免行高跳动
            errorBuilder: (_, _, _) => Text(match.group(0)!, style: style),
          ),
        ),
      );
      // 等长补位(boost 输入条同款):WidgetSpan 只占 1 个字符位,
      // :shortcode: 是 N 个——不补齐的话渲染层与 value.text 错位,
      // 每过一个表情累积 N-1 偏差,光标画错位/点按定位错/删除与
      // 插入落在错误偏移(用户实测三症状同根)。
      // U+2060 词连接符零宽不可见,transparent 兜底选区高亮
      if (match.end - match.start > 1) {
        children.add(
          TextSpan(
            text: '⁠' * (match.end - match.start - 1),
            style: style?.copyWith(color: Colors.transparent),
          ),
        );
      }
      cursor = match.end;
    }

    if (children.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: style, children: children);
  }
}
