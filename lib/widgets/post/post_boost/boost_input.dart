import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/s.dart';
import '../../../models/emoji.dart';
import '../../../utils/emoji_shortcodes.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/platform_utils.dart';
import '../../common/emoji_text.dart';
import '../../markdown_editor/emoji_picker.dart';

/// Boost 输入框的提交结果。
sealed class BoostInputResult {
  const BoostInputResult(this.raw);

  final String raw;
}

/// 可见长度在 Boost 限制内，继续创建 Boost。
class BoostInputBoostResult extends BoostInputResult {
  const BoostInputBoostResult(super.raw);
}

/// 可见长度超过 Boost 限制，应转为回复。
class BoostInputReplyResult extends BoostInputResult {
  const BoostInputReplyResult(super.raw);
}

/// 以底部浮层方式显示 Boost 输入框
/// 返回类型化提交结果，用户取消则返回 null
Future<BoostInputResult?> showBoostInputSheet(BuildContext context) {
  return showAppBottomSheet<BoostInputResult>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => const _BoostInputSheet(),
  );
}

class _BoostInputSheet extends ConsumerStatefulWidget {
  const _BoostInputSheet();

  @override
  ConsumerState<_BoostInputSheet> createState() => _BoostInputSheetState();
}

class _BoostTextEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final hasEmojiShortcode = emojiShortcodeRegex.hasMatch(text);
    final hasComposingRegion =
        withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed;

    if (!hasEmojiShortcode || hasComposingRegion) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    return TextSpan(
      style: style,
      children: EmojiText.buildEmojiSpans(
        context,
        text,
        style,
        preserveSourceLength: true,
      ),
    );
  }
}

class _BoostInputSheetState extends ConsumerState<_BoostInputSheet> {
  final _controller = _BoostTextEditingController();
  final _focusNode = FocusNode();
  // 默认展开表情面板，避免浮层过小
  bool _showEmojiPanel = true;
  bool _normalizingSelection = false;

  static const int _maxVisibleLength = 16;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_normalizeSelectionIfNeeded);
  }

  @override
  void dispose() {
    _controller.removeListener(_normalizeSelectionIfNeeded);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  int get _visibleLength {
    return visibleLengthWithEmojiShortcodes(_controller.text);
  }

  bool get _canSubmit => _controller.text.trim().isNotEmpty;

  bool get _isReplyIntent => _visibleLength > _maxVisibleLength;

  void _handleSubmit() {
    if (!_canSubmit) return;
    final raw = _controller.text.trim();
    Navigator.pop(
      context,
      _isReplyIntent ? BoostInputReplyResult(raw) : BoostInputBoostResult(raw),
    );
  }

  void _normalizeSelectionIfNeeded() {
    if (_normalizingSelection) {
      return;
    }

    final selection = _controller.selection;
    final normalizedSelection = normalizeEmojiShortcodeSelection(
      _controller.text,
      selection,
      preferEnd: true,
    );
    if (normalizedSelection == selection) {
      return;
    }

    _normalizingSelection = true;
    _controller.value = _controller.value.copyWith(
      selection: normalizedSelection,
      composing: TextRange.empty,
    );
    _normalizingSelection = false;
  }

  void _insertEmoji(Emoji emoji) {
    final text = _controller.text;
    final selection = normalizeEmojiShortcodeSelection(
      text,
      _controller.selection,
      expandSelection: true,
      preferEnd: true,
    );
    final shortcode = ':${emoji.name}:';

    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;

    final newText = text.replaceRange(start, end, shortcode);
    _controller.text = newText;
    _controller.selection = TextSelection.collapsed(
      offset: start + shortcode.length,
    );
    setState(() {});
  }

  /// 退格删除:光标前是完整 :shortcode: 时整体删除,否则删一个字符
  /// (与 EmojiShortcodeDeleteFormatter 的整体删除语义一致 —— 表情
  /// 面板打开时键盘收起,这是唯一的删除途径)。
  void _deleteBackward() {
    if (deleteBackwardWithEmojiShortcodes(_controller)) {
      setState(() {});
    }
  }

  void _toggleEmojiPanel() {
    setState(() {
      _showEmojiPanel = !_showEmojiPanel;
      if (_showEmojiPanel) {
        _focusNode.unfocus();
      } else {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final visibleLength = _visibleLength;
    final isReplyIntent = visibleLength > _maxVisibleLength;

    return Padding(
      padding: EdgeInsets.only(bottom: _showEmojiPanel ? 0 : bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖拽指示条
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),

          // 输入区域
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // 表情按钮
                IconButton(
                  onPressed: _toggleEmojiPanel,
                  icon: Icon(
                    _showEmojiPanel
                        ? Symbols.keyboard_rounded
                        : Symbols.emoji_emotions_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                // 输入框
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    inputFormatters: const [EmojiShortcodeDeleteFormatter()],
                    style: theme.textTheme.bodyMedium,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 16,
                      ),
                      hintText: context.l10n.boost_placeholder,
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      counterText: '',
                      suffixText: '$visibleLength/$_maxVisibleLength',
                      suffixStyle: theme.textTheme.labelSmall?.copyWith(
                        color: isReplyIntent
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.5,
                              ),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _handleSubmit(),
                    onTap: () {
                      // 移动端：点击输入框时收起表情面板（让虚拟键盘接管）
                      // 桌面端：保持表情面板，因为没有虚拟键盘来填充空间
                      if (_showEmojiPanel && PlatformUtils.isMobile) {
                        setState(() => _showEmojiPanel = false);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // 发送按钮
                IconButton(
                  onPressed: _canSubmit ? _handleSubmit : null,
                  tooltip: isReplyIntent
                      ? context.l10n.common_reply
                      : context.l10n.boost_send,
                  icon: Icon(
                    isReplyIntent
                        ? Symbols.reply_rounded
                        : Symbols.send_rounded,
                    color: _canSubmit
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.3,
                          ),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Emoji 面板(bottomPadding 给底部安全区 + 悬浮退格键留空)
          if (_showEmojiPanel)
            SizedBox(
              height: 280 + MediaQuery.of(context).padding.bottom,
              child: Stack(
                children: [
                  EmojiPicker(
                    onEmojiSelected: (emoji) => _insertEmoji(emoji),
                    bottomPadding:
                        MediaQuery.of(context).padding.bottom +
                        (PlatformUtils.isMobile ? 48 : 0),
                  ),
                  // 悬浮退格键,仅移动端(面板打开时软键盘收起,没有
                  // 它就无法删除;桌面端焦点常驻输入框,物理退格直接
                  // 可用)
                  if (PlatformUtils.isMobile)
                    Positioned(
                      right: 12,
                      bottom: MediaQuery.of(context).padding.bottom + 8,
                      child: Material(
                        color: theme.colorScheme.surfaceContainerHighest,
                        shape: const CircleBorder(),
                        elevation: 1,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _controller.text.isEmpty
                              ? null
                              : _deleteBackward,
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                              // 字形视觉重心偏右,向左 1px 光学补偿
                              child: Transform.translate(
                                offset: const Offset(-1, 0),
                                child: Icon(
                                  Symbols.backspace_rounded,
                                  size: 20,
                                  color: _controller.text.isEmpty
                                      ? theme.colorScheme.onSurfaceVariant
                                            .withValues(alpha: 0.3)
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // 底部安全区(面板打开时安全区已计入面板高度)
          if (!_showEmojiPanel)
            SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
