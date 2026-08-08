import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/chat/chat_models.dart';
import '../../providers/chat_providers.dart';
import '../../providers/core_providers.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/preloaded_data_service.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/time_utils.dart';
import '../../utils/url_helper.dart';
import '../../widgets/chat/chat_message_flag_sheet.dart';
import '../../widgets/chat/online_status_avatar.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/cached_image.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/markdown_editor/emoji_sticker_panel.dart';
import '../image_viewer_page.dart';
import '../user_profile_page.dart';

/// 消息串底部面板：串内消息与主聊 UI 对齐（气泡 / cooked / 图片 / 反应）。
class ChatThreadSheet extends ConsumerStatefulWidget {
  final int channelId;
  final ChatThread thread;
  final ChatMessage? originalMessage;

  const ChatThreadSheet({
    super.key,
    required this.channelId,
    required this.thread,
    this.originalMessage,
  });

  static Future<void> show(
    BuildContext context, {
    required int channelId,
    required ChatThread thread,
    ChatMessage? originalMessage,
  }) {
    return AppBottomSheet.showDraggable(
      context: context,
      showCloseButton: true,
      title: thread.title?.isNotEmpty == true ? thread.title : '消息串',
      maxSize: 0.92,
      initialSize: 0.78,
      minSize: 0.45,
      contentPadding: EdgeInsets.zero,
      bodyBuilder: (ctx, scrollController) => ChatThreadSheet(
        channelId: channelId,
        thread: thread,
        originalMessage: originalMessage,
      ),
    );
  }

  @override
  ConsumerState<ChatThreadSheet> createState() => _ChatThreadSheetState();
}

class _ChatThreadSheetState extends ConsumerState<ChatThreadSheet> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  bool _isUploadingImage = false;
  bool _showEmojiPicker = false;

  /// 编辑中的消息（null 表示新建回复）
  ChatMessage? _editingMessage;

  /// 上传中的文件 ID 列表
  final List<int> _uploadIds = [];

  /// 上传中图片的本地预览路径
  String? _uploadPreviewPath;

  /// 回复目标消息（用于展示回复提示条）
  ChatMessage? _replyToMessage;

  /// 消息串内回复目标消息ID
  int? _replyToId;

  /// 最近使用的反应表情 SharedPreferences key（与主聊共用）
  static const String _recentReactionEmojisKey = 'recent_reaction_emojis';

  bool get _pinEnabled =>
      PreloadedDataService().siteSettingsSync?['chat_pinned_messages'] == true;

  @override
  void dispose() {
    _textController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String? _avatarUrl(ChatUser? user) {
    if (user?.avatarTemplate == null) return null;
    return UrlHelper.resolveUrlWithCdn(
      user!.avatarTemplate!.replaceAll('{size}', '40'),
    );
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if ((text.isEmpty && _uploadIds.isEmpty) ||
        _isSending ||
        _isUploadingImage) {
      return;
    }
    final channel = ref.read(chatChannelDetailProvider(widget.channelId)).value;
    final currentUser = ref.read(currentUserProvider).value;
    final canSend =
        channel?.canSendMessages(
          isStaff: currentUser?.isStaff ?? false,
          userSilenced: currentUser?.isSilenced ?? false,
        ) ??
        false;
    if (!canSend) return;
    setState(() => _isSending = true);
    try {
      final notifier = ref.read(
        chatMessagesProvider(widget.channelId).notifier,
      );
      if (_editingMessage != null) {
        await notifier.editMessage(_editingMessage!.id, text);
        setState(() => _editingMessage = null);
      } else {
        await notifier.sendThreadMessage(
          widget.thread.id,
          text,
          inReplyToId: _replyToId,
          uploadIds: _uploadIds.isNotEmpty ? _uploadIds : null,
        );
        setState(() {
          _replyToId = null;
          _replyToMessage = null;
        });
      }
      _textController.clear();
      _uploadIds.clear();
      _uploadPreviewPath = null;
      ref.invalidate(
        chatThreadMessagesProvider((
          channelId: widget.channelId,
          threadId: widget.thread.id,
        )),
      );
      // 刷新主列表预览 + 消息串列表
      unawaitedRefresh();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败: $e')));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void unawaitedRefresh() {
    ref
        .read(chatMessagesProvider(widget.channelId).notifier)
        .loadMessages(preferLatest: true)
        .catchError((_) {});
    ref.invalidate(chatChannelThreadsProvider(widget.channelId));
  }

  Future<void> _toggleReaction(ChatMessage message, String emoji) async {
    final already =
        message.reactions?.any((r) => r.emoji == emoji && r.reacted) ?? false;
    try {
      await ref
          .read(chatMessagesProvider(widget.channelId).notifier)
          .toggleReaction(message.id, emoji, knownReacted: already);
      ref.invalidate(
        chatThreadMessagesProvider((
          channelId: widget.channelId,
          threadId: widget.thread.id,
        )),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('回应失败: $e')));
    }
  }

  Future<void> _toggleBookmark(ChatMessage message) async {
    try {
      await ref
          .read(chatMessagesProvider(widget.channelId).notifier)
          .toggleBookmark(
            message.id,
            knownBookmarked: message.bookmarked,
            knownBookmarkId: message.bookmarkId,
          );
      ref.invalidate(
        chatThreadMessagesProvider((
          channelId: widget.channelId,
          threadId: widget.thread.id,
        )),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message.bookmarked ? '已取消书签' : '已设为书签')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('书签操作失败: $e')));
    }
  }

  Future<void> _togglePin(ChatMessage message) async {
    try {
      await ref
          .read(chatMessagesProvider(widget.channelId).notifier)
          .togglePin(message.id, pin: !message.pinned);
      ref.invalidate(
        chatThreadMessagesProvider((
          channelId: widget.channelId,
          threadId: widget.thread.id,
        )),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message.pinned ? '已取消置顶' : '已置顶消息')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('置顶操作失败: $e')));
    }
  }

  void _onCopyMessage(ChatMessage message) {
    Clipboard.setData(ClipboardData(text: message.message));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 2)),
    );
  }

  void _onCopyShareLink(ChatMessage message) {
    final baseUrl = DiscourseService.baseUrl;
    final shareUrl =
        '$baseUrl/chat/channel/${widget.channelId}?message_id=${message.id}';
    Clipboard.setData(ClipboardData(text: shareUrl));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制分享链接到剪贴板')));
  }

  Future<void> _onDeleteMessage(ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('确定要删除这条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(chatMessagesProvider(widget.channelId).notifier)
          .deleteMessage(message.id);
      ref.invalidate(
        chatThreadMessagesProvider((
          channelId: widget.channelId,
          threadId: widget.thread.id,
        )),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  Future<void> _restoreMessage(ChatMessage message) async {
    try {
      await ref
          .read(chatMessagesProvider(widget.channelId).notifier)
          .restoreMessage(message.id);
      ref.invalidate(
        chatThreadMessagesProvider((
          channelId: widget.channelId,
          threadId: widget.thread.id,
        )),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已恢复消息')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('恢复失败: $e')));
    }
  }

  Future<void> _showFlagSheet(ChatMessage message) async {
    final username = message.user?.username ?? '用户';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => ChatMessageFlagSheet(
        channelId: widget.channelId,
        messageId: message.id,
        username: username,
        availableFlagKeys: message.availableFlags,
      ),
    );
  }

  void _onStartEdit(ChatMessage message) {
    setState(() {
      _editingMessage = message;
      _textController.text = message.message;
    });
    _inputFocusNode.requestFocus();
  }

  void _onCancelEdit() {
    setState(() {
      _editingMessage = null;
      _replyToMessage = null;
      _replyToId = null;
      _uploadIds.clear();
      _uploadPreviewPath = null;
      _textController.clear();
    });
    _inputFocusNode.unfocus();
  }

  Future<List<String>> _loadRecentReactionEmojis() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_recentReactionEmojisKey) ?? [];
  }

  Future<void> _saveRecentReactionEmoji(String emojiName) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_recentReactionEmojisKey) ?? [];
    list.remove(emojiName);
    list.insert(0, emojiName);
    final trimmed = list.length > 30 ? list.sublist(0, 30) : list;
    await prefs.setStringList(_recentReactionEmojisKey, trimmed);
  }

  Future<void> _pickAndUploadImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    setState(() {
      _isUploadingImage = true;
      _uploadPreviewPath = pickedFile.path;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final uploadResult = await service.uploadFile(pickedFile.path);
      setState(() {
        _uploadIds.add(uploadResult.id);
        _isUploadingImage = false;
      });
    } catch (e) {
      setState(() {
        _isUploadingImage = false;
        _uploadPreviewPath = null;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('上传失败: $e')));
    }
  }

  void _clearUpload() {
    setState(() {
      _uploadIds.clear();
      _uploadPreviewPath = null;
    });
  }

  Widget _buildUploadPreview(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(8),
      alignment: Alignment.centerLeft,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_uploadPreviewPath!),
              width: 64,
              height: 64,
              fit: BoxFit.cover,
            ),
          ),
          if (_isUploadingImage)
            Positioned.fill(
              child: Container(
                color: Colors.black38,
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: _clearUpload,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showFullEmojiPickerForReaction(ChatMessage message) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.45,
        child: EmojiStickerPanel(
          onEmojiSelected: (emoji) {
            Navigator.pop(ctx);
            _saveRecentReactionEmoji(emoji.name);
            _toggleReaction(message, emoji.name);
          },
          onStickerSelected: (_) {},
          onBackspace: null,
        ),
      ),
    );
  }

  /// 长按消息：弹出与主聊一致的操作面板
  void _showMessageActionSheet(ChatMessage message, bool isOwnMessage) {
    if (message.deleted) {
      showModalBottomSheet(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.restore_rounded),
                title: const Text('恢复消息'),
                onTap: () {
                  Navigator.pop(ctx);
                  _restoreMessage(message);
                },
              ),
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('取消'),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      );
      return;
    }

    final currentUser = ref.read(currentUserProvider).value;
    final canFlag =
        !isOwnMessage &&
        (message.availableFlags == null || message.availableFlags!.isNotEmpty);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 快捷 Emoji 回应工具栏
              FutureBuilder<List<String>>(
                future: _loadRecentReactionEmojis(),
                builder: (ctx, snapshot) {
                  final recentEmojis = snapshot.data ?? [];
                  final availableWidth =
                      MediaQuery.of(ctx).size.width - 32 - 46;
                  final maxCount = (availableWidth / 46).floor().clamp(
                    0,
                    recentEmojis.length,
                  );
                  final displayEmojis = recentEmojis.take(maxCount).toList();

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: displayEmojis.map((emoji) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      _saveRecentReactionEmoji(emoji);
                                      _toggleReaction(message, emoji);
                                    },
                                    borderRadius: BorderRadius.circular(24),
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Theme.of(ctx)
                                            .colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.7),
                                        shape: BoxShape.circle,
                                      ),
                                      child: EmojiText(
                                        ':$emoji:',
                                        style: const TextStyle(fontSize: 22),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(ctx);
                              _showFullEmojiPickerForReaction(message);
                            },
                            borderRadius: BorderRadius.circular(24),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Theme.of(ctx)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: 0.7),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.add_rounded,
                                size: 22,
                                color: Theme.of(
                                  ctx,
                                ).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('回复'),
                onTap: () {
                  Navigator.pop(ctx);
                  _onStartReplyInThread(message);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制'),
                onTap: () {
                  Navigator.pop(ctx);
                  _onCopyMessage(message);
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('复制分享链接'),
                onTap: () {
                  Navigator.pop(ctx);
                  _onCopyShareLink(message);
                },
              ),
              ListTile(
                leading: Icon(
                  message.bookmarked
                      ? Icons.bookmark_remove_rounded
                      : Icons.bookmark_add_outlined,
                  color: message.bookmarked
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                title: Text(message.bookmarked ? '取消书签' : '设为书签'),
                onTap: () {
                  Navigator.pop(ctx);
                  _toggleBookmark(message);
                },
              ),
              if (_pinEnabled)
                ListTile(
                  leading: Icon(
                    message.pinned
                        ? Icons.push_pin_rounded
                        : Icons.push_pin_outlined,
                    color: message.pinned
                        ? Theme.of(ctx).colorScheme.primary
                        : null,
                  ),
                  title: Text(message.pinned ? '取消置顶' : '置顶消息'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _togglePin(message);
                  },
                ),
              if (canFlag)
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('举报'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showFlagSheet(message);
                  },
                ),
              if (isOwnMessage || (currentUser?.isStaff ?? false)) ...[
                if (isOwnMessage)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('编辑'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _onStartEdit(message);
                    },
                  ),
                ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                  title: Text(
                    '删除',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _onDeleteMessage(message);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 在消息串内回复：以指定消息为 inReplyTo（仍在同一串内）
  void _onStartReplyInThread(ChatMessage message) {
    setState(() {
      _editingMessage = null;
      _textController.clear();
      _replyToMessage = message;
      _replyToId = message.id;
    });
    _inputFocusNode.requestFocus();
  }

  String _buildContextBannerTitle(bool isEditing) {
    if (isEditing) {
      return '正在编辑消息';
    }
    if (_replyToMessage != null) {
      final name =
          _replyToMessage!.user?.name ??
          _replyToMessage!.user?.username ??
          '用户';
      final preview =
          _replyToMessage!.excerpt ??
          _stripMarkdownForPreview(_replyToMessage!.message);
      return '正在回复 $name: $preview';
    }
    return '正在回复消息串中的消息';
  }

  /// 预览用纯文本：剥离 markdown 记号，避免回复条里出现 `**`/`[链接](url)`。
  static String _stripMarkdownForPreview(String raw) {
    var text = raw
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
        .replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1')
        .replaceAll(RegExp(r'^\s*>+\s?', multiLine: true), '')
        .replaceAll(RegExp(r'[*_~`]'), '');
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final params = (channelId: widget.channelId, threadId: widget.thread.id);
    final messagesAsync = ref.watch(chatThreadMessagesProvider(params));
    final currentUser = ref.watch(currentUserProvider).value;
    final channel = ref
        .watch(chatChannelDetailProvider(widget.channelId))
        .value;
    final isStaff = currentUser?.isStaff ?? false;
    final userSilenced = currentUser?.isSilenced ?? false;
    final canSend = channel == null
        ? false
        : channel.canSendMessages(isStaff: isStaff, userSilenced: userSilenced);
    final disabledReason =
        channel?.sendDisabledReason(
          isStaff: isStaff,
          userSilenced: userSilenced,
        ) ??
        '当前无法发送消息';
    final replyCount =
        widget.thread.preview?.replyCount ?? widget.thread.replyCount;

    final isEditing = _editingMessage != null;
    final composerHint = isEditing
        ? '编辑消息…'
        : (_replyToMessage != null
              ? '回复 ${_replyToMessage!.user?.name ?? _replyToMessage!.user?.username ?? ''}…'
              : '回复消息串…');

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Icon(
                Icons.forum_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                replyCount > 0 ? '$replyCount 条回复' : '消息串',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: messagesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('加载失败: $e'),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () =>
                          ref.invalidate(chatThreadMessagesProvider(params)),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
            data: (messages) {
              final items = <ChatMessage>[];
              final om = widget.originalMessage;
              if (om != null) items.add(om);
              for (final m in messages) {
                if (om != null && m.id == om.id) continue;
                items.add(m);
              }

              if (items.isEmpty) {
                return Center(
                  child: Text(
                    '还没有回复，来发第一条吧',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }

              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final message = items[index];
                  final isOriginal =
                      om != null && message.id == om.id && index == 0;
                  final isOwn =
                      currentUser != null &&
                      message.user != null &&
                      message.user!.id == currentUser.id;
                  return _ThreadChatBubble(
                    message: message,
                    avatarUrl: _avatarUrl(message.user),
                    theme: theme,
                    isOwnMessage: isOwn,
                    isOriginal: isOriginal,
                    onToggleReaction: (emoji) =>
                        _toggleReaction(message, emoji),
                    onLongPress: () => _showMessageActionSheet(message, isOwn),
                  );
                },
              );
            },
          ),
        ),
        const Divider(height: 1),
        // 键盘 inset 自适应：获取键盘高度
        Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 回复 / 编辑提示条
                if (canSend &&
                    (isEditing ||
                        _replyToMessage != null ||
                        _replyToId != null))
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      border: Border(
                        bottom: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isEditing ? Icons.edit_outlined : Icons.reply_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _buildContextBannerTitle(isEditing),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: _onCancelEdit,
                          tooltip: '取消',
                        ),
                      ],
                    ),
                  ),

                // 图片附件预览
                if (canSend && _uploadPreviewPath != null)
                  _buildUploadPreview(theme),

                if (!canSend)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            disabledReason,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (canSend)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // 图片附件上传按钮
                        IconButton(
                          tooltip: '上传图片',
                          onPressed: _isUploadingImage
                              ? null
                              : _pickAndUploadImage,
                          icon: const Icon(Icons.add_photo_alternate_rounded),
                        ),
                        // 表情按钮
                        IconButton(
                          tooltip: '表情',
                          onPressed: () {
                            setState(
                              () => _showEmojiPicker = !_showEmojiPicker,
                            );
                            if (_showEmojiPicker) {
                              _inputFocusNode.unfocus();
                            } else {
                              _inputFocusNode.requestFocus();
                            }
                          },
                          icon: Icon(
                            _showEmojiPicker
                                ? Icons.keyboard_alt_outlined
                                : Icons.emoji_emotions_outlined,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            focusNode: _inputFocusNode,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            onTap: () {
                              if (_showEmojiPicker) {
                                setState(() => _showEmojiPicker = false);
                              }
                            },
                            decoration: InputDecoration(
                              hintText: composerHint,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                              fillColor:
                                  theme.colorScheme.surfaceContainerHighest,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton.filled(
                          onPressed: (_isSending || _isUploadingImage)
                              ? null
                              : _send,
                          icon: _isSending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  isEditing
                                      ? Icons.check_rounded
                                      : Icons.send_rounded,
                                ),
                        ),
                      ],
                    ),
                  ),
                if (canSend && _showEmojiPicker)
                  SizedBox(
                    height: 240,
                    child: EmojiStickerPanel(
                      onEmojiSelected: (emoji) {
                        final text = _textController.text;
                        final selection = _textController.selection;
                        final code = ':${emoji.name}: ';
                        if (selection.isValid) {
                          final start = selection.start;
                          final newText = text.replaceRange(
                            start,
                            selection.end,
                            code,
                          );
                          _textController.value = TextEditingValue(
                            text: newText,
                            selection: TextSelection.collapsed(
                              offset: start + code.length,
                            ),
                          );
                        } else {
                          _textController.text = '$text$code';
                        }
                      },
                      onStickerSelected: (_) {},
                      onBackspace: () {
                        final text = _textController.text;
                        if (text.isNotEmpty) {
                          _textController.text = text.substring(
                            0,
                            text.length - 1,
                          );
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 与主聊天页对齐的消息串气泡
class _ThreadChatBubble extends StatefulWidget {
  final ChatMessage message;
  final String? avatarUrl;
  final ThemeData theme;
  final bool isOwnMessage;
  final bool isOriginal;
  final ValueChanged<String> onToggleReaction;
  final VoidCallback? onLongPress;

  const _ThreadChatBubble({
    required this.message,
    required this.avatarUrl,
    required this.theme,
    required this.isOwnMessage,
    required this.isOriginal,
    required this.onToggleReaction,
    this.onLongPress,
  });

  @override
  State<_ThreadChatBubble> createState() => _ThreadChatBubbleState();
}

class _ThreadChatBubbleState extends State<_ThreadChatBubble> {
  bool _hovered = false;

  ChatMessage get message => widget.message;
  String? get avatarUrl => widget.avatarUrl;
  ThemeData get theme => widget.theme;
  bool get isOwnMessage => widget.isOwnMessage;
  bool get isOriginal => widget.isOriginal;
  ValueChanged<String> get onToggleReaction => widget.onToggleReaction;
  VoidCallback? get onLongPress => widget.onLongPress;

  static final RegExp _uploadSha1 = RegExp(r'[0-9a-f]{40}');

  static bool _cookedRendersUrl(String cooked, String url) {
    if (cooked.isEmpty) return false;
    final sha = _uploadSha1.firstMatch(url)?.group(0);
    if (sha != null) return cooked.contains(sha);
    final path = Uri.tryParse(url)?.path ?? '';
    return path.isNotEmpty && cooked.contains(path);
  }

  List<String> _extractImageUrls() {
    final urls = <String>[];
    final seen = <String>{};

    bool isNonContentImage(String rawStr) {
      final lower = rawStr.toLowerCase();
      if (lower.contains('class="emoji"') ||
          lower.contains("class='emoji'") ||
          lower.contains('/images/emoji/') ||
          lower.contains('/emoji/')) {
        return true;
      }
      if (lower.contains('class="avatar"') ||
          lower.contains("class='avatar'") ||
          lower.contains('class="thumbnail"') ||
          lower.contains('class="site-icon"') ||
          lower.contains('class="favicon"') ||
          lower.contains('data-avatar')) {
        return true;
      }
      return false;
    }

    void addUrl(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      final trimmed = raw.trim();
      if (trimmed.startsWith('upload://')) return;
      if (isNonContentImage(trimmed)) return;
      final resolved = UrlHelper.resolveUrlWithCdn(trimmed);
      if (resolved.isNotEmpty &&
          !isNonContentImage(resolved) &&
          seen.add(resolved)) {
        urls.add(resolved);
      }
    }

    if (message.uploads != null) {
      for (final u in message.uploads!) {
        final path =
            u['url'] as String? ??
            u['full_url'] as String? ??
            u['short_path'] as String?;
        addUrl(path);
      }
    }

    final mdRegex = RegExp(r'!\[.*?\]\((.*?)\)');
    for (final match in mdRegex.allMatches(message.message)) {
      final urlCandidate = match.group(1);
      if (urlCandidate != null) addUrl(urlCandidate.split(' ').first);
    }

    if (message.cooked != null && message.cooked!.isNotEmpty) {
      final imgRegex = RegExp(r'<img[^>]+>', caseSensitive: false);
      for (final match in imgRegex.allMatches(message.cooked!)) {
        final imgTag = match.group(0) ?? '';
        if (isNonContentImage(imgTag)) continue;
        final srcMatch = RegExp(
          'src=["\']([^"\']+)["\']',
          caseSensitive: false,
        ).firstMatch(imgTag);
        if (srcMatch != null) addUrl(srcMatch.group(1));
      }
    }

    return urls;
  }

  @override
  Widget build(BuildContext context) {
    final alignment = isOwnMessage
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    final showSender = !isOwnMessage && message.user != null;
    final imageUrls = _extractImageUrls();
    final cookedHtml = message.cooked ?? '';
    final thumbnailUrls = cookedHtml.isEmpty
        ? imageUrls
        : imageUrls.where((u) => !_cookedRendersUrl(cookedHtml, u)).toList();

    String displayText = message.message;
    for (final url in imageUrls) {
      displayText = displayText.replaceAll(
        RegExp('!\\[.*?\\]\\(${RegExp.escape(url)}\\)'),
        '',
      );
    }
    displayText = displayText
        .replaceAll(RegExp(r'!\[.*?\]\(upload://[^\)]+\)'), '')
        .trim();

    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: alignment,
            children: [
              if (isOriginal)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.push_pin_outlined,
                        size: 12,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '原消息',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (showSender)
                    Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 4),
                      child: GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => UserProfilePage(
                                username: message.user!.username,
                              ),
                            ),
                          );
                        },
                        child: OnlineStatusAvatar(
                          userId: message.user!.id,
                          imageUrl: avatarUrl,
                          radius: 16,
                          fallbackText: message.user!.username,
                        ),
                      ),
                    ),
                  Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: alignment,
                      children: [
                        if (showSender)
                          Padding(
                            padding: const EdgeInsets.only(left: 4, bottom: 2),
                            child: Text(
                              message.user!.name ?? message.user!.username,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isOwnMessage
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16).copyWith(
                              bottomLeft: isOwnMessage
                                  ? const Radius.circular(16)
                                  : const Radius.circular(4),
                              bottomRight: isOwnMessage
                                  ? const Radius.circular(4)
                                  : const Radius.circular(16),
                            ),
                            border: isOriginal
                                ? Border.all(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.35,
                                    ),
                                  )
                                : null,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (thumbnailUrls.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: thumbnailUrls.asMap().entries.map(
                                      (entry) {
                                        final idx = entry.key;
                                        final url = entry.value;
                                        return GestureDetector(
                                          onTap: () {
                                            ImageViewerPage.open(
                                              context,
                                              url,
                                              galleryImages: thumbnailUrls,
                                              initialIndex: idx,
                                              enableShare: true,
                                            );
                                          },
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: CachedImage(
                                              url: url,
                                              width: 180,
                                              height: 120,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                        );
                                      },
                                    ).toList(),
                                  ),
                                ),
                              if (message.cooked != null &&
                                  message.cooked!.isNotEmpty)
                                FluxdoRenderCallbacks.generic(
                                  heroTagNamespace:
                                      'chat_thread_msg_${message.id}',
                                ).render(
                                  cookedHtml: message.cooked!,
                                  baseTextStyle: theme.textTheme.bodyMedium
                                      ?.copyWith(
                                        color: isOwnMessage
                                            ? theme
                                                  .colorScheme
                                                  .onPrimaryContainer
                                            : theme.colorScheme.onSurface,
                                      ),
                                  selectionEnabled: true,
                                  compact: true,
                                  trimTopMargin: true,
                                  trimBottomMargin: true,
                                )
                              else if (displayText.isNotEmpty)
                                SelectableEmojiText(
                                  displayText,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: isOwnMessage
                                        ? theme.colorScheme.onPrimaryContainer
                                        : theme.colorScheme.onSurface,
                                  ),
                                ),
                              const SizedBox(height: 2),
                              Text(
                                TimeUtils.formatCompactTime(message.createdAt),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color:
                                      (isOwnMessage
                                              ? theme
                                                    .colorScheme
                                                    .onPrimaryContainer
                                              : theme
                                                    .colorScheme
                                                    .onSurfaceVariant)
                                          .withValues(alpha: 0.6),
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (message.reactions != null &&
                            message.reactions!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: 4,
                              left: 4,
                              right: 4,
                            ),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: message.reactions!.map((r) {
                                final isReacted = r.reacted;
                                return Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () => onToggleReaction(r.emoji),
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isReacted
                                            ? theme.colorScheme.primaryContainer
                                            : theme.colorScheme.surface,
                                        border: Border.all(
                                          color: isReacted
                                              ? theme.colorScheme.primary
                                              : theme.colorScheme.outlineVariant
                                                    .withValues(alpha: 0.5),
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          EmojiText(
                                            ':${r.emoji}:',
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${r.count}',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  fontSize: 10,
                                                  fontWeight: isReacted
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  color: isReacted
                                                      ? theme
                                                            .colorScheme
                                                            .primary
                                                      : theme
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
