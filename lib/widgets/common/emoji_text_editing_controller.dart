import 'package:material_ui/material_ui.dart';

import '../../utils/emoji_shortcodes.dart';
import 'emoji_text.dart';

/// 输入框控制器：把 `:shortcode:` 内联显示成表情图。
///
/// 只改显示层：[text] 仍是原始短代码，草稿、发送等基于文本的逻辑零感知。
/// 表情图后用等长的零宽字符补位，渲染层与 [value] 的偏移一一对应，光标、
/// 点按定位、删除都不会错位；光标不会停在短代码中间；输入法组字期间
/// 只有组字区间保持原文，其余表情不受影响。
class EmojiTextEditingController extends TextEditingController {
  EmojiTextEditingController({super.text});

  @override
  set value(TextEditingValue newValue) {
    final selection = normalizeEmojiShortcodeSelection(
      newValue.text,
      newValue.selection,
      preferEnd: true,
    );
    super.value = selection == newValue.selection
        ? newValue
        : newValue.copyWith(selection: selection, composing: TextRange.empty);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!emojiShortcodeRegex.hasMatch(text)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : null;
    // 组字期间只让组字区间保持原文（带下划线），其余表情照常显示成图片；
    // 整段退回原文会让所有表情在打字时闪回 :shortcode:
    if (composing == null) {
      return TextSpan(
        style: style,
        children: _emojiSpans(context, text, style),
      );
    }
    return TextSpan(
      style: style,
      children: [
        ..._emojiSpans(context, composing.textBefore(text), style),
        TextSpan(
          text: composing.textInside(text),
          style: (style ?? const TextStyle()).merge(
            const TextStyle(decoration: TextDecoration.underline),
          ),
        ),
        ..._emojiSpans(context, composing.textAfter(text), style),
      ],
    );
  }

  /// 跨越组字边界的短代码被切开后不再匹配，自然保持原文
  static List<InlineSpan> _emojiSpans(
    BuildContext context,
    String segment,
    TextStyle? style,
  ) {
    if (segment.isEmpty) return const [];
    return EmojiText.buildEmojiSpans(
      context,
      segment,
      style,
      preserveSourceLength: true,
    );
  }
}
