import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

final RegExp emojiShortcodeRegex = RegExp(r':([^\s:]+(?:\:t\d)?):');

/// 前后不贴 ASCII 单词字符的短代码(官方 `\B:…:\B`)。
final RegExp _boundedShortcodeRegex = RegExp(
  r'(?<![A-Za-z0-9_]):([^\s:]+(?:\:t\d)?):(?![A-Za-z0-9_])',
);

/// 可以紧挨在短代码前的字符:空白、Unicode 标点与符号(含 emoji)。
/// 取帖子 cook 的判定(markdown-it isPunctChar),全角标点后也转。
final RegExp _replaceablePrefixChar = RegExp(
  // lint 按非 unicode 模式校验,不认 \p{…}
  // ignore: valid_regexps
  r'^(?:\s|\p{P}|\p{S}|\p{Extended_Pictographic}|\uFE0F|\u200D)$',
  unicode: true,
);

/// 展示文本里应转成表情的短代码,与帖子 cook 的判定一致:
///
/// - [inline] 为 true(站点开启 `enable_inline_emoji_translation`)时,
///   任意位置的 `:name:` 都转;
/// - 否则短代码须在行首、空白、标点或 emoji 之后,且结尾不紧跟字母
///   数字 —— `谢谢:smile:`、`12:30:45` 保持原文。
///
/// `group(1)` 为表情名。
Iterable<RegExpMatch> displayEmojiShortcodeMatches(
  String text, {
  required bool inline,
}) sync* {
  if (!text.contains(':')) return;
  if (inline) {
    yield* emojiShortcodeRegex.allMatches(text);
    return;
  }
  for (final match in _boundedShortcodeRegex.allMatches(text)) {
    if (_isReplaceablePrefix(text, match.start)) yield match;
  }
}

bool _isReplaceablePrefix(String text, int index) {
  if (index == 0) return true;
  var start = index - 1;
  // 前一个字符是代理对低位时取完整码点
  if (start > 0 &&
      (text.codeUnitAt(start) & 0xFC00) == 0xDC00 &&
      (text.codeUnitAt(start - 1) & 0xFC00) == 0xD800) {
    start -= 1;
  }
  return _replaceablePrefixChar.hasMatch(text.substring(start, index));
}

final RegExp _emojiImgTag = RegExp(
  r'''<img\b[^>]*\bclass=["'][^"']*\bemoji\b[^>]*>''',
  caseSensitive: false,
);
final RegExp _emojiImgLabel = RegExp(
  r'''\b(?:alt|title)=["'](:[^\s:"']+(?::t\d)?:)["']''',
);

/// HTML 里的 emoji 图片(`<img class="emoji" alt=":smile:">`)还原成短代码。
///
/// 摘要等按正则去标签的场景先调用,否则表情随标签一起被删。
String emojiImagesToShortcodes(String html) {
  if (!html.contains('<img')) return html;
  return html.replaceAllMapped(
    _emojiImgTag,
    (m) => _emojiImgLabel.firstMatch(m.group(0)!)?.group(1) ?? '',
  );
}

String normalizeEmojiShortcodeName(String raw) {
  var value = raw.trim();
  if (value.startsWith(':') && value.endsWith(':') && value.length > 2) {
    value = value.substring(1, value.length - 1);
  }
  return value.trim();
}

int visibleLengthWithEmojiShortcodes(String text) {
  if (text.isEmpty) {
    return 0;
  }

  var length = 0;
  var lastEnd = 0;

  for (final match in emojiShortcodeRegex.allMatches(text)) {
    length += text.substring(lastEnd, match.start).runes.length;
    length += 1;
    lastEnd = match.end;
  }

  length += text.substring(lastEnd).runes.length;
  return length;
}

TextRange expandRangeToEmojiShortcodeBoundaries(String text, TextRange range) {
  if (text.isEmpty || !range.isValid) {
    return range;
  }

  var start = range.start.clamp(0, text.length);
  var end = range.end.clamp(0, text.length);
  if (start > end) {
    final tmp = start;
    start = end;
    end = tmp;
  }

  for (final match in emojiShortcodeRegex.allMatches(text)) {
    if (start < match.end && end > match.start) {
      if (match.start < start) {
        start = match.start;
      }
      if (match.end > end) {
        end = match.end;
      }
    }
  }

  return TextRange(start: start, end: end);
}

TextSelection normalizeEmojiShortcodeSelection(
  String text,
  TextSelection selection, {
  bool expandSelection = false,
  bool preferEnd = true,
}) {
  if (text.isEmpty || !selection.isValid) {
    return selection;
  }

  if (!selection.isCollapsed) {
    if (!expandSelection) {
      return selection;
    }

    final expanded = expandRangeToEmojiShortcodeBoundaries(
      text,
      TextRange(start: selection.start, end: selection.end),
    );
    return selection.copyWith(
      baseOffset: expanded.start,
      extentOffset: expanded.end,
    );
  }

  final offset = selection.baseOffset.clamp(0, text.length);
  final normalizedOffset = _snapOffsetOutOfEmojiShortcode(
    text,
    offset,
    preferEnd: preferEnd,
  );
  if (normalizedOffset == offset) {
    return selection;
  }

  return TextSelection.collapsed(
    offset: normalizedOffset,
    affinity: selection.affinity,
  );
}

/// 对 [controller] 执行一次"表情键盘退格":
/// 有选区删选区;光标前是完整 `:shortcode:` 时整体删除
/// (复用 [expandRangeToEmojiShortcodeBoundaries],与
/// [EmojiShortcodeDeleteFormatter] 的输入语义一致);
/// 否则按字素簇删一个字符(防拆 Unicode emoji 代理对)。
/// 返回是否发生了修改。
bool deleteBackwardWithEmojiShortcodes(TextEditingController controller) {
  final text = controller.text;
  final selection = controller.selection;
  if (text.isEmpty) return false;

  if (selection.isValid && !selection.isCollapsed) {
    final newText = text.replaceRange(selection.start, selection.end, '');
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start),
    );
    return true;
  }

  final cursor = selection.isValid ? selection.end : text.length;
  if (cursor <= 0) return false;

  final before = text.substring(0, cursor);
  final lastChar = before.characters.last;
  var start = cursor - lastChar.length;

  final expanded = expandRangeToEmojiShortcodeBoundaries(
    text,
    TextRange(start: start, end: cursor),
  );
  start = expanded.start;

  final newText = text.replaceRange(start, cursor, '');
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: start),
  );
  return true;
}

class EmojiShortcodeDeleteFormatter extends TextInputFormatter {
  const EmojiShortcodeDeleteFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalizedNewSelection = normalizeEmojiShortcodeSelection(
      newValue.text,
      newValue.selection,
      preferEnd: true,
    );

    if (oldValue.text.isEmpty || newValue.text.length >= oldValue.text.length) {
      if (normalizedNewSelection == newValue.selection) {
        return newValue;
      }
      return newValue.copyWith(
        selection: normalizedNewSelection,
        composing: TextRange.empty,
      );
    }

    final change = _findTextChange(oldValue.text, newValue.text);
    if (change == null ||
        !change.newRange.isCollapsed ||
        change.oldRange.isCollapsed) {
      if (normalizedNewSelection == newValue.selection) {
        return newValue;
      }
      return newValue.copyWith(
        selection: normalizedNewSelection,
        composing: TextRange.empty,
      );
    }

    final expandedRange = expandRangeToEmojiShortcodeBoundaries(
      oldValue.text,
      change.oldRange,
    );

    if (expandedRange == change.oldRange) {
      if (normalizedNewSelection == newValue.selection) {
        return newValue;
      }
      return newValue.copyWith(
        selection: normalizedNewSelection,
        composing: TextRange.empty,
      );
    }

    final text = oldValue.text.replaceRange(
      expandedRange.start,
      expandedRange.end,
      '',
    );
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: expandedRange.start),
    );
  }
}

int _snapOffsetOutOfEmojiShortcode(
  String text,
  int offset, {
  required bool preferEnd,
}) {
  for (final match in emojiShortcodeRegex.allMatches(text)) {
    if (offset > match.start && offset < match.end) {
      return preferEnd ? match.end : match.start;
    }
  }
  return offset;
}

_TextChange? _findTextChange(String oldText, String newText) {
  if (oldText == newText) {
    return null;
  }

  var prefixLength = 0;
  final minLength = oldText.length < newText.length
      ? oldText.length
      : newText.length;
  while (prefixLength < minLength &&
      oldText.codeUnitAt(prefixLength) == newText.codeUnitAt(prefixLength)) {
    prefixLength += 1;
  }

  var oldSuffixStart = oldText.length;
  var newSuffixStart = newText.length;
  while (oldSuffixStart > prefixLength &&
      newSuffixStart > prefixLength &&
      oldText.codeUnitAt(oldSuffixStart - 1) ==
          newText.codeUnitAt(newSuffixStart - 1)) {
    oldSuffixStart -= 1;
    newSuffixStart -= 1;
  }

  return _TextChange(
    oldRange: TextRange(start: prefixLength, end: oldSuffixStart),
    newRange: TextRange(start: prefixLength, end: newSuffixStart),
  );
}

class _TextChange {
  final TextRange oldRange;
  final TextRange newRange;

  const _TextChange({required this.oldRange, required this.newRange});
}
