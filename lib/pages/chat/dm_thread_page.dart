import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluxdo_render/editor.dart'
    show
        observeModifierKeyEvent,
        primaryModifierHeldForReversibleAction,
        shiftModifierHeld;
import 'package:fluxdo_render/fluxdo_render.dart' show LocalDateRun;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../constants.dart';
import '../../models/chat/chat_message.dart';
import '../../models/emoji.dart';
import '../../models/mention_user.dart';
import '../../providers/core_providers.dart';
import '../../providers/message_bus/chat_providers.dart';
import '../../services/toast_service.dart';
import '../../utils/clipboard_image_native.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/time_utils.dart';
import '../../widgets/bookmark/bookmark_edit_sheet_launcher.dart';
import '../../widgets/chat/chat_upload_view.dart';
import '../../widgets/chat/overlay_anchor.dart';
import '../../widgets/chat/reaction_chip.dart';
import '../../widgets/common/cached_image.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/common/user_status_icon.dart';
import '../../widgets/user/user_card.dart';
import '../../widgets/markdown_editor/emoji_sticker_panel.dart';
import '../../widgets/markdown_editor/markdown_toolbar.dart'
    show MarkdownToolbarState;
import '../../widgets/markdown_editor/rich_composer/local_date_edit_dialog.dart';
import '../../widgets/markdown_editor/template_insert_dialog.dart';
import '../../widgets/post/post_item/widgets/post_flag_sheet.dart';
import '../image_viewer_page.dart';
import 'dm_channel_detail_page.dart';

/// 表情包走"伪上传":不占用真实 upload_ids,发送时直接把它的 markdown
/// 拼进正文,沿用旧 CDN 链接,不产生新 upload 记录(见
/// dm_channel_detail_page.dart 同名类的详细注释)。
class _PendingUpload {
  const _PendingUpload({
    this.id,
    required this.name,
    this.localPath,
    this.stickerMarkdown,
    this.stickerPreviewUrl,
  });
  final int? id;
  final String name;
  final String? localPath;
  final String? stickerMarkdown;
  final String? stickerPreviewUrl;

  bool get isSticker => stickerMarkdown != null;

  bool get isImage =>
      isSticker ||
      const {
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.webp',
        '.bmp',
      }.contains(p.extension(name).toLowerCase());
}

/// 消息串(thread)页:某条消息下的独立对话流 + 回复框。图片/文件发送
/// 跟频道主体([DmChannelDetailPage])同一套:选文件先上传拿 id 挂进
/// 待发区,点发送时随文字一起 uploadIds 带出去。
class DmThreadPage extends ConsumerStatefulWidget {
  const DmThreadPage({
    super.key,
    required this.channelId,
    required this.threadId,
    this.title,
    this.embeddedMode = false,
    this.onEmbeddedBack,
  });

  final int channelId;
  final int threadId;
  final String? title;

  /// 嵌入平行视界右栏时为 true:不显示系统返回键,返回走 [onEmbeddedBack]。
  final bool embeddedMode;
  final VoidCallback? onEmbeddedBack;

  @override
  ConsumerState<DmThreadPage> createState() => _DmThreadPageState();
}

class _DmThreadPageState extends ConsumerState<DmThreadPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _sending = false;
  bool _uploading = false;
  final List<_PendingUpload> _pendingUploads = [];
  ChatMessage? _replyTo;
  ChatMessage? _editing;

  (int, int) get _arg => (widget.channelId, widget.threadId);

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _startReply(ChatMessage message) {
    setState(() {
      _editing = null;
      _replyTo = message;
    });
    _inputFocusNode.requestFocus();
  }

  void _startEdit(ChatMessage message) {
    setState(() {
      _replyTo = null;
      _editing = message;
      _pendingUploads.clear();
    });
    _inputController.text = message.message ?? '';
    _inputController.selection =
        TextSelection.collapsed(offset: _inputController.text.length);
    _inputFocusNode.requestFocus();
  }

  void _cancelComposeExtras() {
    setState(() {
      _replyTo = null;
      if (_editing != null) {
        _editing = null;
        _inputController.clear();
      }
    });
  }

  /// 点状态图标时弹出完整状态内容(悬浮 Tooltip 之外的触屏可达路径)。
  void _showUserStatus(MentionUser user) {
    final status = user.status;
    if (status == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(user.displayName),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserStatusIcon(status: status, size: 22),
            const SizedBox(width: 8),
            Flexible(child: Text(status.description ?? '')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _bookmarkMessage(ChatMessage message) async {
    final notifier = ref.read(chatThreadMessagesProvider(_arg).notifier);
    final existing = message.bookmark;
    int bookmarkId;
    try {
      if (existing == null) {
        final service = ref.read(discourseServiceProvider);
        bookmarkId = await service.bookmarkChatMessage(message.id);
        notifier.applyBookmark(message.id, ChatBookmark(id: bookmarkId));
        ToastService.showSuccess('已加入书签');
      } else {
        bookmarkId = existing.id;
      }
    } on DioException catch (e) {
      final errors = (e.response?.data is Map)
          ? ((e.response!.data as Map)['errors'] as List?)
          : null;
      ToastService.showError(errors?.firstOrNull?.toString() ?? '加书签失败');
      return;
    } catch (e) {
      ToastService.showError('加书签失败: $e');
      return;
    }
    if (!mounted) return;

    final result = await showBookmarkEditSheetWithCachedNames(
      context,
      ref,
      bookmarkId: bookmarkId,
      initialName: existing?.name,
      initialReminderAt: existing?.reminderAt,
      source: 'chat_message_bookmark',
    );
    if (result == null || !mounted) return;
    if (result.deleted) {
      notifier.applyBookmark(message.id, null);
    } else {
      notifier.applyBookmark(
        message.id,
        ChatBookmark(
          id: bookmarkId,
          name: result.name,
          reminderAt: result.reminderAt,
        ),
      );
    }
  }

  /// 举报:复用全应用同一套举报组件,和主私聊/话题同源同 UI。
  Future<void> _showFlagDialog(ChatMessage message) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false,
      builder: (ctx) => PostFlagSheet(
        postId: message.id,
        postUsername: message.user?.username ?? '',
        service: ref.read(discourseServiceProvider),
        chatChannelId: widget.channelId,
        chatMessageId: message.id,
        onSuccess: () {
          if (mounted) ToastService.showSuccess('已提交举报');
        },
      ),
    );
  }

  Future<void> _uploadPathAsAttachment(String path) async {
    final service = ref.read(discourseServiceProvider);
    final result = await service.uploadFile(path);
    final uploadId = result.id;
    if (uploadId == null) throw Exception('上传成功但未返回附件 id');
    if (!mounted) return;
    setState(() {
      _pendingUploads.add(
        _PendingUpload(id: uploadId, name: p.basename(path), localPath: path),
      );
    });
  }

  Future<void> _uploadBytesAsAttachment(Uint8List bytes, String ext) async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = 'paste_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes);
      await _uploadPathAsAttachment(tempFile.path);
    } catch (e) {
      if (mounted) ToastService.showError('上传图片失败: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  static const _pastedImageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.avif',
  };

  KeyEventResult _handlePasteKey(FocusNode node, KeyEvent event) {
    observeModifierKeyEvent(event);
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (isEnter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }

    final isPasteCombo =
        event.logicalKey == LogicalKeyboardKey.keyV &&
        !shiftModifierHeld() &&
        !HardwareKeyboard.instance.isAltPressed &&
        primaryModifierHeldForReversibleAction(event);
    if (!isPasteCombo) return KeyEventResult.ignored;

    unawaited(_maybePasteImage());
    return KeyEventResult.ignored;
  }

  Future<void> _maybePasteImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return;
    final reader = await clipboard.read();
    final img = await MarkdownToolbarState.readImageFromReader(reader);
    if (img != null) {
      unawaited(_uploadBytesAsAttachment(img.$1, img.$2));
      return;
    }
    final native = readClipboardImageNative();
    if (native != null) {
      unawaited(_uploadBytesAsAttachment(native, 'png'));
      return;
    }
    for (final item in reader.items) {
      if (!item.canProvide(Formats.fileUri)) continue;
      final uri = await item.readValue(Formats.fileUri);
      if (uri == null) continue;
      final path = uri.toFilePath(windows: Platform.isWindows);
      if (_pastedImageExtensions.contains(p.extension(path).toLowerCase())) {
        await _uploadPathAsAttachment(path);
      }
    }
  }

  /// 选图片/文件上传后挂进待发附件区,和文字一起随消息发出——跟频道
  /// 主体的"附加文件"同一个入口,不区分图片和其它文件类型。
  Future<void> _pickAndAttachFile() async {
    if (_uploading) return;
    final picked = await FilePicker.platform.pickFiles(withData: false);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      await _uploadPathAsAttachment(path);
    } catch (e) {
      if (mounted) ToastService.showError('上传文件失败: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 光标处插入文字,替换当前选区。
  void _insertTextAtCursor(String text) {
    final value = _inputController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final newText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    _inputController.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
    _inputFocusNode.requestFocus();
  }

  String _serializeLocalDate(LocalDateRun n) {
    final buf = StringBuffer('[date=${n.date}');
    if (n.time != null) buf.write(' time=${n.time}');
    if (n.timezone != null) buf.write(' timezone="${n.timezone}"');
    if (n.format != null) buf.write(' format="${n.format}"');
    if (n.timezones.isNotEmpty) {
      buf.write(' timezones="${n.timezones.join('|')}"');
    }
    if (n.displayedTimezone != null) {
      buf.write(' displayedTimezone="${n.displayedTimezone}"');
    }
    if (n.countdown) buf.write(' countdown="true"');
    buf.write(']');
    return buf.toString();
  }

  Future<void> _insertDateTime() async {
    final run = await showLocalDateEditDialog(context);
    if (run == null || !mounted) return;
    _insertTextAtCursor(_serializeLocalDate(run));
  }

  Future<void> _insertTemplate() async {
    final template = await showTemplateInsertDialog(context);
    if (template == null || !mounted) return;
    _insertTextAtCursor(template.content);
  }

  Future<void> _showSummarizeDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => ChatSummaryDialog(channelId: widget.channelId),
    );
  }

  Future<void> _showComposeMenu(BuildContext anchorContext) async {
    final btnBox = anchorContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (btnBox == null || overlay == null) return;
    final btnRect =
        btnBox.localToGlobal(Offset.zero, ancestor: overlay) & btnBox.size;
    final scheme = Theme.of(context).colorScheme;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        btnRect.left,
        btnRect.top - 8,
        overlay.size.width - btnRect.right,
        overlay.size.height - btnRect.top + 8,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      color: scheme.surfaceContainerLow,
      constraints: const BoxConstraints(maxWidth: 220),
      items: [
        PopupMenuItem(
          value: 'file',
          child: _row(Icons.attach_file_rounded, '附加文件'),
        ),
        PopupMenuItem(
          value: 'date',
          child: _row(Icons.event_rounded, '插入日期/时间'),
        ),
        PopupMenuItem(
          value: 'template',
          child: _row(Icons.description_outlined, '插入模板'),
        ),
        PopupMenuItem(
          value: 'summarize',
          child: _row(Icons.auto_awesome_rounded, '总结消息'),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    switch (selected) {
      case 'file':
        await _pickAndAttachFile();
      case 'date':
        await _insertDateTime();
      case 'template':
        await _insertTemplate();
      case 'summarize':
        await _showSummarizeDialog();
    }
  }

  Widget _row(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
  );

  void _insertEmoji(Emoji emoji) {
    final text = _inputController.text;
    final selection = _inputController.selection;
    final shortcode = ':${emoji.name}:';
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;
    final newText = text.replaceRange(start, end, shortcode);
    _inputController.text = newText;
    _inputController.selection = TextSelection.collapsed(
      offset: start + shortcode.length,
    );
  }

  static final _stickerMarkdownPattern = RegExp(r'^!\[([^|\]]+).*?\]\((.+)\)$');

  void _addStickerAsPseudoUpload(String markdown) {
    final match = _stickerMarkdownPattern.firstMatch(markdown);
    setState(() {
      _pendingUploads.add(_PendingUpload(
        name: match?.group(1) ?? markdown,
        stickerMarkdown: markdown,
        stickerPreviewUrl: match?.group(2),
      ));
    });
  }

  Future<void> _showEmojiPicker(BuildContext anchorContext) async {
    final emoji = await showAnchoredPopup<Emoji>(
      context: context,
      anchorContext: anchorContext,
      closeOnScroll: _scrollController,
      builder: (ctx, close) => EmojiStickerPanel(
        onEmojiSelected: (e) => close(e),
        onStickerSelected: (markdown) {
          close(null);
          _addStickerAsPseudoUpload(markdown);
        },
      ),
    );
    if (emoji != null) _insertEmoji(emoji);
  }

  Future<void> _pickReaction(int messageId) async {
    final emoji = await showDialog<Emoji>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 420,
          height: 480,
          child: EmojiStickerPanel(
            showStickerTab: false,
            onEmojiSelected: (e) => Navigator.of(ctx).pop(e),
            // 回应场景不露出表情包页签,onStickerSelected 走不到。
            onStickerSelected: (_) {},
          ),
        ),
      ),
    );
    if (emoji == null || !mounted) return;
    unawaited(
      ref
          .read(chatThreadMessagesProvider(_arg).notifier)
          .toggleReaction(messageId, emoji.name),
    );
  }

  /// 悬浮条上"更多表情"点了之后,面板贴在点击位置附近弹出——对齐官方
  /// 网页端悬浮工具条的表现,而不是屏幕正中的对话框。
  Future<void> _pickReactionNear(BuildContext anchorContext, int messageId) {
    return showAnchoredPopup<Emoji>(
      context: context,
      anchorContext: anchorContext,
      closeOnScroll: _scrollController,
      builder: (ctx, close) => EmojiStickerPanel(
        compact: true,
        inlineSearch: true,
        showStickerTab: false,
        onEmojiSelected: (e) => close(e),
        onStickerSelected: (_) {},
      ),
    ).then((emoji) {
      if (emoji == null || !mounted) return;
      unawaited(
        ref
            .read(chatThreadMessagesProvider(_arg).notifier)
            .toggleReaction(messageId, emoji.name),
      );
    });
  }

  static const _quickReactionEmojis = [
    '+1',
    'heart',
    'joy',
    'open_mouth',
    'cry',
    'tada',
  ];

  Future<void> _showThreadMessageMenu(ChatMessage message, bool isOwn) async {
    final notifier = ref.read(chatThreadMessagesProvider(_arg).notifier);
    final canManagePins = ref
            .read(chatChannelListProvider)
            .value
            ?.where((c) => c.id == widget.channelId)
            .firstOrNull
            ?.canManagePins ??
        false;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!message.isDeleted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    for (final name in _quickReactionEmojis)
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop('react:$name'),
                        icon: ReactionEmoji(name: name, size: 26),
                      ),
                    IconButton(
                      tooltip: '更多表情',
                      onPressed: () => Navigator.of(ctx).pop('react_more'),
                      icon: const Icon(Icons.add_reaction_outlined),
                    ),
                  ],
                ),
              ),
            if (!message.isDeleted) const Divider(height: 1),
            if (!message.isDeleted)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('回复'),
                onTap: () => Navigator.of(ctx).pop('reply'),
              ),
            if (!message.isDeleted)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制文本'),
                onTap: () => Navigator.of(ctx).pop('copy'),
              ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('复制链接'),
              onTap: () => Navigator.of(ctx).pop('copy_link'),
            ),
            if (!message.isDeleted)
              ListTile(
                leading: Icon(message.bookmark != null
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded),
                title: Text(message.bookmark != null ? '修改书签' : '书签'),
                onTap: () => Navigator.of(ctx).pop('bookmark'),
              ),
            if (!message.isDeleted)
              ListTile(
                leading: const Icon(Icons.select_all_rounded),
                title: const Text('选择文本'),
                onTap: () => Navigator.of(ctx).pop('select'),
              ),
            if (!message.isDeleted && canManagePins)
              ListTile(
                leading: Icon(message.pinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined),
                title: Text(message.pinned ? '取消置顶' : '置顶'),
                onTap: () => Navigator.of(ctx).pop('pin'),
              ),
            if (isOwn && !message.isDeleted)
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('编辑'),
                onTap: () => Navigator.of(ctx).pop('edit'),
              ),
            if (isOwn && !message.isDeleted)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除'),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
            if (isOwn && message.isDeleted)
              ListTile(
                leading: const Icon(Icons.restore_rounded),
                title: const Text('恢复'),
                onTap: () => Navigator.of(ctx).pop('restore'),
              ),
            if (!isOwn && !message.isDeleted)
              ListTile(
                leading: Icon(Icons.flag_outlined,
                    color: Theme.of(ctx).colorScheme.error),
                title: Text('举报',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () => Navigator.of(ctx).pop('flag'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    if (action.startsWith('react:')) {
      unawaited(notifier.toggleReaction(message.id, action.substring(6)));
      return;
    }
    switch (action) {
      case 'react_more':
        await _pickReaction(message.id);
      case 'reply':
        _startReply(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.message ?? ''));
        if (mounted) ToastService.showSuccess('已复制文本');
      case 'copy_link':
        await Clipboard.setData(ClipboardData(
          text:
              '${AppConstants.baseUrl}/chat/c/-/${widget.channelId}/${message.id}',
        ));
        if (mounted) ToastService.showSuccess('已复制链接');
      case 'bookmark':
        await _bookmarkMessage(message);
      case 'select':
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('选择文本'),
            content: SelectableText(message.message ?? ''),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      case 'pin':
        try {
          await notifier.togglePinned(message.id);
        } catch (e) {
          if (mounted) ToastService.showError('置顶操作失败: $e');
        }
      case 'edit':
        _startEdit(message);
      case 'delete':
        try {
          await notifier.deleteMessage(message.id);
        } catch (e) {
          if (mounted) ToastService.showError('删除失败: $e');
        }
      case 'restore':
        try {
          await notifier.restoreMessage(message.id);
        } catch (e) {
          if (mounted) ToastService.showError('恢复失败: $e');
        }
      case 'flag':
        await _showFlagDialog(message);
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingUploads.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      final editing = _editing;
      final stickerMarkdowns = _pendingUploads
          .where((u) => u.isSticker && u.stickerMarkdown != null)
          .map((u) => u.stickerMarkdown!);
      final realUploadIds = _pendingUploads
          .where((u) => !u.isSticker)
          .map((u) => u.id!)
          .toList();
      final combinedText =
          [text, ...stickerMarkdowns].where((s) => s.isNotEmpty).join('\n');
      if (editing != null) {
        await ref
            .read(chatThreadMessagesProvider(_arg).notifier)
            .editMessage(editing.id, combinedText);
      } else {
        final service = ref.read(discourseServiceProvider);
        await service.sendChatMessage(
          widget.channelId,
          combinedText,
          threadId: widget.threadId,
          inReplyToId: _replyTo?.id,
          uploadIds: realUploadIds.isEmpty ? null : realUploadIds,
        );
      }
      _inputController.clear();
      setState(() {
        _pendingUploads.clear();
        _replyTo = null;
        _editing = null;
      });
      ref.invalidate(chatThreadMessagesProvider(_arg));
    } catch (e) {
      if (mounted) ToastService.showError('发送失败: $e');
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _inputFocusNode.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(chatThreadMessagesProvider(_arg));
    final currentUsername = ref.watch(
      currentUserProvider.select((s) => s.value?.username),
    );
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        automaticallyImplyLeading: !widget.embeddedMode,
        leading: widget.embeddedMode && widget.onEmbeddedBack != null
            ? BackButton(onPressed: widget.onEmbeddedBack)
            : null,
        title: Text(widget.title ?? '消息串'),
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(
                    child: Text('还没有回复', style: TextStyle(color: Colors.grey)),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  cacheExtent: 1200,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  // 同 dm_channel_detail_page.dart:findChildIndexCallback +
                  // addAutomaticKeepAlives:false 这套滚动调优上线后出现了新的
                  // 原生层空指针崩溃,已回退,只保留 ValueKey 本身的正确性修复。
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final chronoIndex = messages.length - 1 - index;
                    final message = messages[chronoIndex];
                    final previous =
                        chronoIndex > 0 ? messages[chronoIndex - 1] : null;
                    final isOwn =
                        currentUsername != null &&
                        message.user?.username == currentUsername;
                    final showHeader = previous == null ||
                        previous.user?.username != message.user?.username;
                    return _ThreadMessageTile(
                      key: ValueKey('thread_msg_${message.id}'),
                      message: message,
                      isOwn: isOwn,
                      showHeader: showHeader,
                      scheme: scheme,
                      onToggleReaction: (emoji) => unawaited(
                        ref
                            .read(chatThreadMessagesProvider(_arg).notifier)
                            .toggleReaction(message.id, emoji),
                      ),
                      onAddReaction: (anchorCtx) =>
                          _pickReactionNear(anchorCtx, message.id),
                      onOpenMenu: () => _showThreadMessageMenu(message, isOwn),
                      onReply: () => _startReply(message),
                      onBookmark: () => _bookmarkMessage(message),
                      onShowStatus: message.user != null
                          ? () => _showUserStatus(message.user!)
                          : null,
                    );
                  },
                );
              },
              loading: () => const Center(child: LoadingSpinner()),
              error: (error, stack) => ErrorView(
                error: error,
                stackTrace: stack,
                onRetry: () => ref.invalidate(chatThreadMessagesProvider(_arg)),
              ),
            ),
          ),
          if (_uploading) const LinearProgressIndicator(minHeight: 2),
          if (_replyTo != null || _editing != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: scheme.surfaceContainerLow,
              child: Row(
                children: [
                  Icon(
                    _editing != null ? Icons.edit_rounded : Icons.reply_rounded,
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _editing != null
                          ? '编辑消息'
                          : '回复 ${_replyTo!.user?.displayName ?? ''}: '
                              '${_replyTo!.excerpt ?? _replyTo!.message ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  InkWell(
                    onTap: _cancelComposeExtras,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          if (_pendingUploads.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: scheme.surfaceContainerLow,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final upload in _pendingUploads)
                    if (upload.isImage && upload.localPath != null)
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: GestureDetector(
                              onTap: () {
                                final bytes = File(
                                  upload.localPath!,
                                ).readAsBytesSync();
                                Navigator.of(context).push(
                                  PageRouteBuilder(
                                    opaque: false,
                                    barrierColor: Colors.transparent,
                                    pageBuilder:
                                        (_, animation, secondaryAnimation) =>
                                            ImageViewerPage(imageBytes: bytes),
                                  ),
                                );
                              },
                              child: Image.file(
                                File(upload.localPath!),
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                                errorBuilder: (context, e, s) => Container(
                                  width: 64,
                                  height: 64,
                                  color: scheme.surfaceContainerHighest,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: InkWell(
                              onTap: () => setState(
                                () => _pendingUploads.remove(upload),
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: BoxShape.circle,
                                ),
                                padding: const EdgeInsets.all(2),
                                child: const Icon(
                                  Icons.close_rounded,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (upload.isSticker && upload.stickerPreviewUrl != null)
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedImage(
                              url: upload.stickerPreviewUrl!,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: InkWell(
                              onTap: () => setState(
                                () => _pendingUploads.remove(upload),
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: BoxShape.circle,
                                ),
                                padding: const EdgeInsets.all(2),
                                child: const Icon(
                                  Icons.close_rounded,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      InputChip(
                        avatar: const Icon(Icons.attach_file_rounded, size: 16),
                        label: Text(
                          upload.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        visualDensity: VisualDensity.compact,
                        onDeleted: () =>
                            setState(() => _pendingUploads.remove(upload)),
                      ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Builder(
                    builder: (btnCtx) => IconButton(
                      tooltip: '更多',
                      onPressed: (_uploading || _editing != null)
                          ? null
                          : () => _showComposeMenu(btnCtx),
                      icon: const Icon(Icons.add_circle_outline_rounded),
                    ),
                  ),
                  Builder(
                    builder: (btnCtx) => IconButton(
                      tooltip: '表情',
                      onPressed: () => _showEmojiPicker(btnCtx),
                      icon: const Icon(Icons.emoji_emotions_outlined),
                    ),
                  ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _handlePasteKey,
                      child: TextField(
                        controller: _inputController,
                        focusNode: _inputFocusNode,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: _editing != null ? '编辑消息…' : '回复消息串',
                          filled: true,
                          fillColor: scheme.surfaceContainerHigh,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: _editing != null ? '保存编辑' : '发送',
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: LoadingSpinner(size: 18),
                          )
                        : Icon(_editing != null
                            ? Icons.check_rounded
                            : Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 线程内的简化消息行:头像 + 名字/时间 + 正文 + 回应。桌面悬浮出操作条,
/// 头像可点开资料卡,姓名旁带自定义状态——对齐主私聊 `_ChatMessageBubble`。
class _ThreadMessageTile extends ConsumerStatefulWidget {
  const _ThreadMessageTile({
    super.key,
    required this.message,
    required this.isOwn,
    required this.showHeader,
    required this.scheme,
    required this.onToggleReaction,
    required this.onAddReaction,
    required this.onOpenMenu,
    required this.onReply,
    required this.onBookmark,
    this.onShowStatus,
  });

  final ChatMessage message;
  final bool isOwn;
  final bool showHeader;
  final ColorScheme scheme;
  final ValueChanged<String> onToggleReaction;
  final ValueChanged<BuildContext> onAddReaction;
  final VoidCallback onOpenMenu;
  final VoidCallback onReply;
  final VoidCallback onBookmark;
  final VoidCallback? onShowStatus;

  @override
  ConsumerState<_ThreadMessageTile> createState() => _ThreadMessageTileState();
}

class _ThreadMessageTileState extends ConsumerState<_ThreadMessageTile> {
  ChatMessage get message => widget.message;

  @override
  Widget build(BuildContext context) {
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'chat_thread_msg_${message.id}',
    );
    final scheme = widget.scheme;
    final status = message.user?.status;

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          widget.showHeader
              ? Builder(
                  builder: (avatarCtx) => GestureDetector(
                    onTap: message.user == null
                        ? null
                        : () {
                            final box =
                                avatarCtx.findRenderObject() as RenderBox?;
                            if (box == null || !box.hasSize) return;
                            showUserCard(
                              context: avatarCtx,
                              anchorRect:
                                  box.localToGlobal(Offset.zero) & box.size,
                              username: message.user!.username,
                              nameFallback: message.user!.name,
                              avatarFallbackUrl: message.user!
                                  .getAvatarUrl(AppConstants.baseUrl, size: 144),
                            );
                          },
                    child: SmartAvatar(
                      imageUrl: message.user?.getAvatarUrl(
                        AppConstants.baseUrl,
                        size: 40,
                      ),
                      radius: 16,
                      fallbackText: (message.user?.username ?? '?').isNotEmpty
                          ? message.user!.username[0]
                          : '?',
                      isOnline: message.user?.id != null &&
                          (ref.watch(chatOnlinePresenceProvider).value ??
                                  const {})
                              .contains(message.user!.id),
                    ),
                  ),
                )
              : const SizedBox(width: 32),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showHeader)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          '${message.user?.displayName ?? ''} · '
                          '${TimeUtils.formatCompactTime(message.createdAt)}',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (status != null) ...[
                        const SizedBox(width: 4),
                        UserStatusIcon(
                          status: status,
                          size: 14,
                          onTap: widget.onShowStatus,
                        ),
                      ],
                    ],
                  ),
                if (widget.showHeader) const SizedBox(height: 2),
                message.isDeleted
                    ? const Text(
                        '(消息已删除)',
                        style: TextStyle(color: Colors.grey),
                      )
                    : (message.cooked?.isNotEmpty ?? false)
                    ? callbacks.render(
                        cookedHtml: message.cooked!,
                        compact: true,
                      )
                    : Text(message.message ?? ''),
                // 图片/附件不在 cooked 里,得单独渲染(见 chat_upload_view.dart)
                if (!message.isDeleted)
                  for (final upload in message.uploads)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ChatUploadView(upload: upload),
                    ),
                if (!message.isDeleted && message.reactions.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final reaction in message.reactions)
                        ReactionChip(
                          reaction: reaction,
                          onTap: () => widget.onToggleReaction(reaction.emoji),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    final tappableRow = GestureDetector(
      onLongPress: widget.onOpenMenu,
      onSecondaryTap: widget.onOpenMenu,
      child: row,
    );

    if (message.isDeleted) return tappableRow;

    return HoverPopupAnchor(
      alignRight: true,
      gap: -10,
      popupBuilder: (overlayCtx, closePopup) => _buildHoverPanel(
          Theme.of(overlayCtx).colorScheme, closePopup),
      child: tappableRow,
    );
  }

  Widget _buildHoverPanel(ColorScheme scheme, VoidCallback closePopup) {
    final recentReactions = ref.watch(recentChatReactionsProvider);
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(20),
      color: scheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final name in recentReactions)
              IconButton(
                tooltip: ':$name:',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  closePopup();
                  widget.onToggleReaction(name);
                },
                icon: ReactionEmoji(name: name, size: 18),
              ),
            Builder(
              builder: (btnCtx) => IconButton(
                tooltip: '更多表情',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  // 先同步用 btnCtx 发起(算锚点位置),再收起悬浮条。
                  widget.onAddReaction(btnCtx);
                  closePopup();
                },
                icon: Icon(Icons.add_reaction_outlined,
                    color: scheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              tooltip: message.bookmark != null ? '修改书签' : '书签',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                closePopup();
                widget.onBookmark();
              },
              icon: Icon(
                message.bookmark != null
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                color: message.bookmark != null
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
            IconButton(
              tooltip: '回复',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                closePopup();
                widget.onReply();
              },
              icon: Icon(Icons.reply_rounded, color: scheme.onSurfaceVariant),
            ),
            IconButton(
              tooltip: '更多',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                closePopup();
                widget.onOpenMenu();
              },
              icon: Icon(Icons.more_vert_rounded,
                  color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

