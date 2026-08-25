/// post-voting(问答)评论输入底部弹层 —— 移动端定制体验。
///
/// 行内小输入框在移动端体验差(键盘顶起后输入区被挤/上下文丢失),
/// 改为 Boost 输入同款底部弹层:自动聚焦、emoji 面板(shortcode 内联
/// 渲染 + 悬浮退格)、字数上限提示(站点 post_voting_comment_max_raw_length,
/// 缺省 600)。提交在弹层内完成,失败不关闭不丢稿;成功返回新评论。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../models/emoji.dart';
import '../../../models/topic.dart';
import '../../../services/app_error_handler.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/preloaded_data_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/emoji_shortcodes.dart';
import '../../../utils/platform_utils.dart';
import '../../common/emoji_text.dart';
import '../../markdown_editor/emoji_picker.dart';

/// 弹出评论输入弹层。成功创建返回新评论;取消返回 null。
Future<PostVotingComment?> showPostVotingCommentSheet(
  BuildContext context, {
  required int postId,
  required String replyToUsername,
}) {
  return showAppBottomSheet<PostVotingComment>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _CommentInputSheet(
      postId: postId,
      replyToUsername: replyToUsername,
    ),
  );
}

/// emoji shortcode 内联渲染(boost 输入同款):非合成区间时把
/// :smile: 之类画成表情图,保持源文本长度不变。
class _CommentTextEditingController extends TextEditingController {
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

class _CommentInputSheet extends StatefulWidget {
  final int postId;
  final String replyToUsername;

  const _CommentInputSheet({
    required this.postId,
    required this.replyToUsername,
  });

  @override
  State<_CommentInputSheet> createState() => _CommentInputSheetState();
}

class _CommentInputSheetState extends State<_CommentInputSheet> {
  final _controller = _CommentTextEditingController();
  final _focusNode = FocusNode();
  bool _showEmojiPanel = false;
  bool _isSubmitting = false;
  bool _normalizingSelection = false;

  /// 评论字数上限:站点 post_voting_comment_max_raw_length,缺省 600
  late final int _maxLength = (PreloadedDataService()
              .siteSettingsSync?['post_voting_comment_max_raw_length']
          as num?)
          ?.toInt() ??
      600;

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

  bool get _overLimit => _controller.text.length > _maxLength;

  bool get _canSubmit =>
      !_isSubmitting && _controller.text.trim().isNotEmpty && !_overLimit;

  void _normalizeSelectionIfNeeded() {
    if (_normalizingSelection) return;
    final selection = _controller.selection;
    final normalized = normalizeEmojiShortcodeSelection(
      _controller.text,
      selection,
      preferEnd: true,
    );
    if (normalized == selection) return;
    _normalizingSelection = true;
    _controller.value = _controller.value.copyWith(
      selection: normalized,
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
    _controller.text = text.replaceRange(start, end, shortcode);
    _controller.selection = TextSelection.collapsed(
      offset: start + shortcode.length,
    );
    setState(() {});
  }

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

  /// 弹层内提交:成功 pop 返回评论;失败保持弹层与文字(不丢稿)。
  Future<void> _handleSubmit() async {
    if (!_canSubmit) return;
    setState(() => _isSubmitting = true);
    try {
      final comment = await DiscourseService().createPostVotingComment(
        postId: widget.postId,
        raw: _controller.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, comment);
    } on DioException catch (_) {
      // 业务错误(字数/每帖上限)已由 ErrorInterceptor 提示,留在弹层
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final length = _controller.text.length;

    return Padding(
      padding: EdgeInsets.only(bottom: _showEmojiPanel ? 0 : bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          // 上下文提示:评论给谁的帖子(键盘顶起后仍知道在评论什么)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(
                  Symbols.mode_comment_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    S.current.postVoting_commentSheetTitle(
                      widget.replyToUsername,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  '$length/$_maxLength',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _overLimit
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 输入区
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
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
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    inputFormatters: const [EmojiShortcodeDeleteFormatter()],
                    style: theme.textTheme.bodyMedium,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: PlatformUtils.isMobile
                        ? TextInputAction.newline
                        : TextInputAction.send,
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
                      hintText: S.current.postVoting_commentHint,
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _handleSubmit(),
                    onTap: () {
                      // 移动端点输入框收起表情面板,让虚拟键盘接管
                      if (_showEmojiPanel && PlatformUtils.isMobile) {
                        setState(() => _showEmojiPanel = false);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _canSubmit ? _handleSubmit : null,
                  tooltip: S.current.postVoting_commentSubmit,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Symbols.send_rounded,
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
          // Emoji 面板(boost 输入同款:悬浮退格仅移动端)
          if (_showEmojiPanel)
            SizedBox(
              height: 280 + MediaQuery.of(context).padding.bottom,
              child: Stack(
                children: [
                  EmojiPicker(
                    onEmojiSelected: _insertEmoji,
                    bottomPadding:
                        MediaQuery.of(context).padding.bottom +
                        (PlatformUtils.isMobile ? 48 : 0),
                  ),
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
          if (!_showEmojiPanel)
            SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
