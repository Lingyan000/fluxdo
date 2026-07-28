import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fluxdo_render/editor.dart'
    show
        observeModifierKeyEvent,
        primaryModifierHeldForReversibleAction,
        shiftModifierHeld;
import 'package:fluxdo_render/fluxdo_render.dart' show LocalDateRun;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../models/chat/chat_message.dart';
import '../../models/emoji.dart';
import '../../models/mention_user.dart';
import '../../providers/core_providers.dart';
import '../../providers/message_bus/chat_providers.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';
import '../../services/toast_service.dart';
import '../../utils/clipboard_image_native.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/time_utils.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../widgets/common/cached_image.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/common/user_status_icon.dart';
import '../../utils/platform_utils.dart';
import '../../widgets/post/post_item/widgets/post_flag_sheet.dart';
import '../../widgets/bookmark/bookmark_edit_sheet_launcher.dart';
import '../../widgets/user/user_card.dart' show showUserCard;
import '../../widgets/markdown_editor/rich_composer/local_date_edit_dialog.dart';
import '../../widgets/markdown_editor/template_insert_dialog.dart';
import '../image_viewer_page.dart';
import 'chat_search_dialog.dart';
import 'dm_thread_page.dart';
import '../../widgets/markdown_editor/emoji_sticker_panel.dart';
import '../../widgets/markdown_editor/markdown_toolbar.dart' show MarkdownToolbarState;
import '../../constants.dart';

/// 快速回应候选(对齐官方 chat 默认的常用表情,不用每次都翻表情面板)。
const _quickReactionEmojis = ['+1', 'heart', 'joy', 'open_mouth', 'cry', 'tada'];

/// 发送前暂存的附件(已上传拿到 id,等和文字一起随消息发出)。
class _PendingUpload {
  const _PendingUpload({required this.id, required this.name, this.localPath});
  final int id;
  final String name;

  /// 本地源文件路径,图片用来画缩略图预览
  final String? localPath;

  bool get isImage => const {
        '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp',
      }.contains(p.extension(name).toLowerCase());
}

/// Chat 插件 DM 频道详情页:消息流 + 发送框。
class DmChannelDetailPage extends ConsumerStatefulWidget {
  const DmChannelDetailPage({
    super.key,
    required this.channelId,
    this.title,
    this.embeddedMode = false,
    this.onEmbeddedBack,
  });

  final int channelId;
  final String? title;

  /// 嵌入平行视界右栏时为 true:不显示系统返回键,返回走 [onEmbeddedBack]
  /// (同 [TagTopicsPage]/[CategoryTopicsPage] 的做法)。
  final bool embeddedMode;
  final VoidCallback? onEmbeddedBack;

  @override
  ConsumerState<DmChannelDetailPage> createState() => _DmChannelDetailPageState();
}

class _DmChannelDetailPageState extends ConsumerState<DmChannelDetailPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _sending = false;
  bool _uploading = false;
  int _lastMessageId = -1;

  @override
  void initState() {
    super.initState();
    // reverse 列表里"顶部"是 maxScrollExtent 方向:快滚到顶就拉更早的消息
    _scrollController.addListener(() {
      final position = _scrollController.position;
      if (position.pixels >= position.maxScrollExtent - 200) {
        ref.read(chatMessagesProvider(widget.channelId).notifier).loadOlder();
      }
    });
  }

  /// 发送前暂存的附件:选文件/粘贴图片先上传拿 id 挂在输入框上方,
  /// 点发送时随文字一起发出(而不是一粘贴/一选中就立刻单独发一条)。
  final List<_PendingUpload> _pendingUploads = [];

  /// 正在回复的消息(显示在输入框上方,发送时带 in_reply_to_id)。
  ChatMessage? _replyTo;

  /// 正在编辑的消息(发送按钮变成"保存编辑")。
  ChatMessage? _editing;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      // 列表是 reverse:true,offset 0 就是最底(最新消息)。
      _scrollController.jumpTo(0);
    });
  }

  void _showError(String prefix, Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$prefix: $e')),
    );
  }

  Future<void> _toggleStarred(bool current) async {
    final next = !current;
    // 乐观更新:先改本地状态,失败再改回来,星标这种低风险操作不值得
    // 等接口回来再动 UI。
    ref.read(chatChannelListProvider.notifier).applyStarred(widget.channelId, next);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.setChatChannelStarred(widget.channelId, next);
    } catch (e) {
      if (!mounted) return;
      ref.read(chatChannelListProvider.notifier).applyStarred(widget.channelId, current);
      _showError('收藏失败', e);
    }
  }

  Future<void> _toggleMuted(bool current) async {
    final next = !current;
    ref.read(chatChannelListProvider.notifier).applyMuted(widget.channelId, next);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.setChatChannelMuted(widget.channelId, next);
    } catch (e) {
      if (!mounted) return;
      ref.read(chatChannelListProvider.notifier).applyMuted(widget.channelId, current);
      _showError('设置静音失败', e);
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final uploads = List<_PendingUpload>.from(_pendingUploads);
    if ((text.isEmpty && uploads.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      final service = ref.read(discourseServiceProvider);
      final editing = _editing;
      if (editing != null) {
        await ref
            .read(chatMessagesProvider(widget.channelId).notifier)
            .editMessage(editing.id, text);
      } else {
        await service.sendChatMessage(
          widget.channelId,
          text,
          inReplyToId: _replyTo?.id,
          uploadIds: uploads.map((u) => u.id).toList(),
        );
      }
      _inputController.clear();
      setState(() {
        _pendingUploads.clear();
        _replyTo = null;
        _editing = null;
      });
      // 发送成功后 MessageBus 会推回这条消息;兜底重拉一次最新消息,
      // 避免推送延迟导致用户以为没发出去。
      ref.invalidate(chatMessagesProvider(widget.channelId));
    } catch (e) {
      _showError('发送失败', e);
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        // 发完焦点回到输入框,连续聊天不用每条都点一下
        _inputFocusNode.requestFocus();
      }
    }
  }

  /// 上传一段字节流,成功后挂进待发附件区(不直接发送)。
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
      _showError('上传图片失败', e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadPathAsAttachment(String path) async {
    final service = ref.read(discourseServiceProvider);
    final result = await service.uploadFile(path);
    final uploadId = result.id;
    if (uploadId == null) throw Exception('上传成功但未返回附件 id');
    if (!mounted) return;
    setState(() {
      _pendingUploads.add(_PendingUpload(
        id: uploadId,
        name: p.basename(path),
        localPath: path,
      ));
    });
  }

  /// 选一个文件上传后挂进待发附件区,和输入框文字一起随消息发出。
  Future<void> _pickAndAttachFile() async {
    if (_uploading) return;
    final picked = await FilePicker.platform.pickFiles(withData: false);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      await _uploadPathAsAttachment(path);
    } catch (e) {
      _showError('上传文件失败', e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 在输入框光标处插入一段文字,替换掉当前选区(没有选区就是插入)。
  void _insertTextAtCursor(String text) {
    final value = _inputController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final newText = value.text.replaceRange(selection.start, selection.end, text);
    _inputController.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
    _inputFocusNode.requestFocus();
  }

  /// `[date=… time=… timezone="…"]` BBCode 重建,和富文本编辑器
  /// (rich_composer_editor.dart 的 `_serializeLocalDate`)同一套属性名——
  /// 聊天输入框是纯文本框,没有编辑器原子,只能直接拼 BBCode 文本。
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

  /// AI 总结频道近期消息(discourse-ai 插件,`POST
  /// /discourse-ai/summarization/channels/:id.json`):弹窗选时间范围,
  /// 展示只读摘要文本——对齐官方 chat-modal-channel-summary 组件的交互
  /// (不写回输入框,纯展示)。
  Future<void> _showSummarizeDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ChatSummaryDialog(channelId: widget.channelId),
    );
  }

  Future<void> _showComposeMenu(BuildContext anchorContext) async {
    final btnBox = anchorContext.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
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
      items: const [
        PopupMenuItem(value: 'file', child: _ComposeMenuRow(icon: Icons.attach_file_rounded, label: '附加文件')),
        PopupMenuItem(value: 'date', child: _ComposeMenuRow(icon: Icons.event_rounded, label: '插入日期/时间')),
        PopupMenuItem(value: 'template', child: _ComposeMenuRow(icon: Icons.description_outlined, label: '插入模板')),
        PopupMenuItem(value: 'summarize', child: _ComposeMenuRow(icon: Icons.auto_awesome_rounded, label: '总结消息')),
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

  /// Ctrl+V(mac 上是 Cmd+V)时先看剪贴板里有没有图片——有就上传挂到
  /// 待发附件区;没有(纯文本/没有剪贴板访问)放行给 TextField 走默认
  /// 粘贴,不吞事件。复用富文本编辑器同款的两段式图片读取
  /// (super_clipboard 常规格式 + Windows 原生 CF_DIB 兜底)。
  KeyEventResult _handlePasteKey(FocusNode node, KeyEvent event) {
    // 必须把每个按键喂给修饰键补偿窗口——Win+V 注入的 `V` 自身不带 Ctrl
    // 修饰位,可逆动作判定靠的是"刚收到过 Ctrl 按下"这个窗口;编辑器页
    // 是在页面级喂的,聊天页之前没喂,判定永远为假,Win+V 就一直死着。
    observeModifierKeyEvent(event);
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Enter 发送,Shift+Enter 换行(拦下不带修饰键的 Enter,不让编辑框
    // 插换行;Shift+Enter 放行走默认多行输入行为)。
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (isEnter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }

    // 粘贴是可逆动作,用吃补偿窗口的那版修饰键判定(同富文本编辑器):
    // Win+V 剪贴板历史注入的 `V` 键事件不带 Ctrl 修饰位,只认
    // HardwareKeyboard 真实状态会让整条 Win+V 粘图路径失效。
    final isPasteCombo = event.logicalKey == LogicalKeyboardKey.keyV &&
        !shiftModifierHeld() &&
        !HardwareKeyboard.instance.isAltPressed &&
        primaryModifierHeldForReversibleAction(event);
    if (!isPasteCombo) return KeyEventResult.ignored;

    unawaited(_maybePasteImage());
    return KeyEventResult.ignored; // 是否真有图片要异步才知道,先放行文本粘贴兜底
  }

  static const _pastedImageExtensions = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.avif',
  };

  /// 对齐富文本编辑器验证过的完整粘图链:super_clipboard 常规格式 →
  /// Windows 原生 CF_DIB 兜底(Win+V 剪贴板历史的 OLE data object 在
  /// super_clipboard 枚举不到位图) → 文件路径粘贴(CF_HDROP)。
  /// 不做"有文本就早退"——之前那个 plainText 早退把 Win+V 路径整个
  /// 挡死了(编辑器的成熟实现里没有这个判断)。
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
        setState(() => _uploading = true);
        try {
          await _uploadPathAsAttachment(path);
        } catch (e) {
          _showError('上传图片失败', e);
        } finally {
          if (mounted) setState(() => _uploading = false);
        }
      }
    }
  }

  void _insertEmoji(Emoji emoji) {
    final text = _inputController.text;
    final selection = _inputController.selection;
    final shortcode = ':${emoji.name}:';
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;
    final newText = text.replaceRange(start, end, shortcode);
    _inputController.text = newText;
    _inputController.selection = TextSelection.collapsed(offset: start + shortcode.length);
  }

  Future<void> _showEmojiPicker() async {
    final emoji = await _pickEmoji(allowSticker: true);
    if (emoji != null) _insertEmoji(emoji);
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

  /// 输入框上方的状态条:回复某条 / 正在编辑 / 待发附件。
  Widget? _buildComposeExtras(ColorScheme scheme) {
    final children = <Widget>[];
    final replyTo = _replyTo;
    final editing = _editing;
    if (replyTo != null || editing != null) {
      children.add(Row(
        children: [
          Icon(
            editing != null ? Icons.edit_rounded : Icons.reply_rounded,
            size: 16,
            color: scheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              editing != null
                  ? '编辑消息'
                  : '回复 ${replyTo!.user?.name ?? replyTo.user?.username ?? ''}: '
                      '${replyTo.excerpt ?? replyTo.message ?? ''}',
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
      ));
    }
    if (_pendingUploads.isNotEmpty) {
      children.add(Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final upload in _pendingUploads)
            // 图片给缩略图预览(右上角小 × 移除),其它文件保持 chip
            if (upload.isImage && upload.localPath != null)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: GestureDetector(
                      onTap: () {
                        // 待发图也能点开大图预览(本地文件字节直接喂查看器)
                        final bytes = File(upload.localPath!).readAsBytesSync();
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            opaque: false,
                            barrierColor: Colors.transparent,
                            pageBuilder: (_, animation, secondaryAnimation) =>
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
                          child: const Icon(Icons.broken_image_outlined,
                              size: 20),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: InkWell(
                      onTap: () =>
                          setState(() => _pendingUploads.remove(upload)),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(2),
                        child: const Icon(Icons.close_rounded,
                            size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              )
            else
              InputChip(
                avatar: const Icon(Icons.attach_file_rounded, size: 16),
                label: Text(upload.name, style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                onDeleted: () => setState(() => _pendingUploads.remove(upload)),
              ),
        ],
      ));
    }
    if (children.isEmpty) return null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            children[i],
          ],
        ],
      ),
    );
  }

  /// 成员列表(对齐官方"成员"标签页):走服务端分页搜索接口
  /// `GET /chat/api/channels/:id/memberships?username=`,常规频道几万
  /// 成员也能查,不做本地过滤。
  Future<void> _showMembers() async {
    final service = ref.read(discourseServiceProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        Timer? debounce;
        Future<List<MentionUser>> future = service.fetchChatChannelMembers(widget.channelId);
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SizedBox(
              height: 460,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      autofocus: false,
                      onChanged: (v) {
                        debounce?.cancel();
                        debounce = Timer(const Duration(milliseconds: 400), () {
                          setSheetState(() {
                            future = service.fetchChatChannelMembers(
                              widget.channelId,
                              username: v.trim(),
                            );
                          });
                        });
                      },
                      decoration: const InputDecoration(
                        hintText: '查找成员',
                        prefixIcon: Icon(Icons.search_rounded),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: FutureBuilder<List<MentionUser>>(
                      future: future,
                      builder: (ctx, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(child: LoadingSpinner());
                        }
                        if (snapshot.hasError) {
                          return Center(child: Text('加载成员失败: ${snapshot.error}'));
                        }
                        final members = snapshot.data ?? const [];
                        if (members.isEmpty) {
                          return const Center(
                              child: Text('没有匹配的成员',
                                  style: TextStyle(color: Colors.grey)));
                        }
                        return ListView.builder(
                          itemCount: members.length,
                          itemBuilder: (ctx, index) {
                            final user = members[index];
                            return ListTile(
                              leading: SmartAvatar(
                                imageUrl: user.getAvatarUrl(
                                    AppConstants.baseUrl, size: 40),
                                radius: 16,
                                fallbackText: user.username.isNotEmpty
                                    ? user.username[0]
                                    : '?',
                              ),
                              title: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      user.name?.isNotEmpty == true
                                          ? user.name!
                                          : user.username,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (user.status != null) ...[
                                    const SizedBox(width: 6),
                                    UserStatusIcon(status: user.status, size: 14),
                                  ],
                                ],
                              ),
                              subtitle: Text(user.username),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 点状态图标时弹出完整状态内容(悬浮 Tooltip 之外的触屏可达路径)。
  void _showUserStatus(MentionUser user) {
    final status = user.status;
    if (status == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(user.name?.isNotEmpty == true ? user.name! : user.username),
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

  /// 频道设置面板:免打扰 / 推送通知级别 / 离开频道(对齐官方网页端的
  /// 频道设置页,DM 和公共频道通用)。
  Future<void> _showChannelSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, sheetRef, _) {
          final channels = sheetRef.watch(chatChannelListProvider).value;
          final channel =
              channels?.where((c) => c.id == widget.channelId).firstOrNull;
          if (channel == null) {
            return const SizedBox(height: 120, child: Center(child: Text('频道信息未加载')));
          }
          final membership = channel.membership;
          final scheme = Theme.of(ctx).colorScheme;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text(
                    channel.isDirectMessage ? '私聊设置' : '频道设置',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  subtitle: Text(widget.title ?? channel.title ?? ''),
                  trailing: IconButton(
                    tooltip: membership.starred ? '取消收藏' : '收藏',
                    icon: Icon(
                      membership.starred
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      color: membership.starred ? Colors.amber : null,
                    ),
                    onPressed: () => _toggleStarred(membership.starred),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.group_outlined),
                  title: Text(
                    '成员 (${channel.membershipsCount ?? channel.participants.length})',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showMembers();
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_off_outlined),
                  title: const Text('将频道设为免打扰'),
                  value: membership.muted,
                  onChanged: (_) => _toggleMuted(membership.muted),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('发送推送通知'),
                  trailing: DropdownButton<int>(
                    value: membership.notificationLevel,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('从不')),
                      DropdownMenuItem(value: 1, child: Text('仅提及')),
                      DropdownMenuItem(value: 2, child: Text('所有活动')),
                    ],
                    onChanged: (level) {
                      if (level != null) _setNotificationLevel(level);
                    },
                  ),
                ),
                // 消息串开关:DM 里成员就能改(UpdateChannel 对 DM 放行,
                // 实测 meta.can_moderate 在 DM 里是 false,不能拿它当门槛);
                // 公共频道才需要管理权限,没权限就不显示,免得点了 403。
                if (channel.isDirectMessage || channel.canModerate)
                  SwitchListTile(
                    secondary: const Icon(Icons.forum_outlined),
                    title: const Text('消息串'),
                    subtitle: const Text(
                      '启用后,对聊天消息的回复将创建单独的对话,与主频道并存',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: channel.threadingEnabled,
                    onChanged: (_) =>
                        _toggleThreading(channel.threadingEnabled),
                  ),
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: const Text('置顶消息'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showPinnedMessages();
                  },
                ),
                const Divider(height: 1),
                // 频道信息(对照官方网页端的"频道信息"区)
                if ((channel.description ?? '').isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.notes_rounded),
                    title: const Text('描述'),
                    subtitle: Text(channel.description!),
                  ),
                if (channel.categoryName != null)
                  ListTile(
                    leading: const Icon(Icons.category_outlined),
                    title: const Text('类别'),
                    trailing: Text(channel.categoryName!,
                        style: Theme.of(ctx).textTheme.bodyMedium),
                  ),
                ListTile(
                  leading: const Icon(Icons.link_rounded),
                  title: const Text('复制频道链接'),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(
                      text:
                          '${AppConstants.baseUrl}/chat/c/${channel.slug ?? '-'}/${channel.id}',
                    ));
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('已复制频道链接'),
                            duration: Duration(seconds: 1)),
                      );
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.logout_rounded, color: scheme.error),
                  title: Text('离开频道',
                      style: TextStyle(color: scheme.error)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _confirmLeaveChannel();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _toggleThreading(bool current) async {
    final next = !current;
    ref
        .read(chatChannelListProvider.notifier)
        .applyThreadingEnabled(widget.channelId, next);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.setChatChannelThreadingEnabled(widget.channelId, next);
    } catch (e) {
      if (!mounted) return;
      ref
          .read(chatChannelListProvider.notifier)
          .applyThreadingEnabled(widget.channelId, current);
      _showError('设置消息串失败', e);
    }
  }

  Future<void> _setNotificationLevel(int level) async {
    final old = ref
        .read(chatChannelListProvider)
        .value
        ?.where((c) => c.id == widget.channelId)
        .firstOrNull
        ?.membership
        .notificationLevel;
    ref
        .read(chatChannelListProvider.notifier)
        .applyNotificationLevel(widget.channelId, level);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.setChatChannelNotificationLevel(widget.channelId, level);
    } catch (e) {
      if (!mounted) return;
      if (old != null) {
        ref
            .read(chatChannelListProvider.notifier)
            .applyNotificationLevel(widget.channelId, old);
      }
      _showError('设置通知级别失败', e);
    }
  }

  Future<void> _confirmLeaveChannel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开频道'),
        content: const Text('确定要离开这个频道吗?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('离开'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final service = ref.read(discourseServiceProvider);
      await service.leaveChatChannel(widget.channelId);
      if (!mounted) return;
      ref.read(chatChannelListProvider.notifier).removeChannel(widget.channelId);
      if (widget.embeddedMode) {
        widget.onEmbeddedBack?.call();
      } else {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      _showError('离开频道失败', e);
    }
  }

  /// 查看频道置顶消息列表(顺手把"有新置顶"的红点标掉)。
  Future<void> _showPinnedMessages() async {
    final service = ref.read(discourseServiceProvider);
    unawaited(service.markChatChannelPinsRead(widget.channelId).catchError((_) {}));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: 420,
        child: FutureBuilder<List<ChatMessage>>(
          future: service.fetchChatChannelPins(widget.channelId),
          builder: (ctx, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: LoadingSpinner());
            }
            if (snapshot.hasError) {
              return Center(child: Text('加载置顶消息失败: ${snapshot.error}'));
            }
            final pins = snapshot.data ?? const [];
            if (pins.isEmpty) {
              return const Center(
                child: Text('暂无置顶消息', style: TextStyle(color: Colors.grey)),
              );
            }
            return ListView.builder(
              itemCount: pins.length,
              itemBuilder: (ctx, index) {
                final pin = pins[index];
                return ListTile(
                  leading: SmartAvatar(
                    imageUrl:
                        pin.user?.getAvatarUrl(AppConstants.baseUrl, size: 40),
                    radius: 16,
                    fallbackText: (pin.user?.username ?? '?').isNotEmpty
                        ? pin.user!.username[0]
                        : '?',
                  ),
                  title: Text(
                    pin.user?.name ?? pin.user?.username ?? '',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  subtitle: Text(
                    pin.excerpt ?? pin.message ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '取消置顶',
                    icon: const Icon(Icons.push_pin_rounded, size: 18),
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      try {
                        await ref
                            .read(chatMessagesProvider(widget.channelId).notifier)
                            .togglePinned(pin.id);
                      } catch (e) {
                        _showError('取消置顶失败', e);
                      }
                    },
                  ),
                  onTap: () => Navigator.of(ctx).pop(),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// 消息书签:没加过 → 创建后弹编辑面板(名称/提醒,同帖子书签流程);
  /// 已加过 → 直接打开编辑面板(可改名/改提醒/右下角删除)。
  Future<void> _bookmarkMessage(ChatMessage message) async {
    final notifier = ref.read(chatMessagesProvider(widget.channelId).notifier);
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

  // ---- 消息操作菜单 ----

  Future<void> _showMessageMenu(ChatMessage message, bool isOwn) async {
    final notifier = ref.read(chatMessagesProvider(widget.channelId).notifier);
    // 置顶需要 meta.can_manage_pins,没权限不显示入口
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
                        icon: _ReactionEmoji(name: name, size: 26),
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
        final emoji = await _pickEmoji();
        if (emoji != null) {
          unawaited(notifier.toggleReaction(message.id, emoji.name));
        }
      case 'reply':
        _startReply(message);
      case 'bookmark':
        await _bookmarkMessage(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.message ?? ''));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制文本'), duration: Duration(seconds: 1)),
          );
        }
      case 'copy_link':
        // 官方消息链接格式:/chat/c/-/{channelId}/{messageId}(路由表里的
        // `get "#{base_c_route}/:message_id"`,channel_title 用 `-` 占位)。
        await Clipboard.setData(ClipboardData(
          text: '${AppConstants.baseUrl}/chat/c/-/${widget.channelId}/${message.id}',
        ));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制链接'), duration: Duration(seconds: 1)),
          );
        }
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
          _showError('置顶操作失败', e);
        }
      case 'edit':
        _startEdit(message);
      case 'delete':
        try {
          await notifier.deleteMessage(message.id);
        } catch (e) {
          _showError('删除失败', e);
        }
      case 'restore':
        try {
          await notifier.restoreMessage(message.id);
        } catch (e) {
          _showError('恢复失败', e);
        }
      case 'flag':
        await _showFlagDialog(message);
    }
  }

  /// 举报:复用全应用同一套举报组件(理由列表来自站点 post_action_types,
  /// 按 applies_to 含 Chat::Message 过滤,和话题/私信举报同源同 UI)。
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
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已提交举报')),
            );
          }
        },
      ),
    );
  }

  /// 表情选择:复用编辑器同款 [EmojiStickerPanel](最近使用/分组/搜索/
  /// 表情包都有)。PC 端悬浮面板(compact + 内联搜索),移动端底部弹层。
  /// [allowSticker] 为 true 时(输入框场景)选表情包直接把 markdown 插进
  /// 输入框;回应场景表情包无意义,点了只关面板。
  Future<Emoji?> _pickEmoji({bool allowSticker = false}) {
    Widget buildPanel(BuildContext ctx, {required bool compact}) {
      return EmojiStickerPanel(
        compact: compact,
        inlineSearch: compact,
        onEmojiSelected: (e) => Navigator.of(ctx).pop(e),
        onStickerSelected: (markdown) {
          Navigator.of(ctx).pop();
          if (allowSticker) {
            final text = _inputController.text;
            _inputController.text = text.isEmpty ? markdown : '$text $markdown';
            _inputController.selection = TextSelection.collapsed(
                offset: _inputController.text.length);
            _inputFocusNode.requestFocus();
          }
        },
      );
    }

    if (PlatformUtils.isDesktop) {
      return showDialog<Emoji>(
        context: context,
        builder: (ctx) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 420,
            height: 480,
            child: buildPanel(ctx, compact: true),
          ),
        ),
      );
    }
    return showModalBottomSheet<Emoji>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: 360,
        child: buildPanel(ctx, compact: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(chatMessagesProvider(widget.channelId));
    final currentUsername = ref.watch(
      currentUserProvider.select((s) => s.value?.username),
    );
    final scheme = Theme.of(context).colorScheme;

    // **最后一条**消息变了(首次加载/新消息进来)才滚到底;往上翻加载
    // 更早的消息是往列表头部插,不能触发滚底,不然翻着翻着被拽回去。
    messagesAsync.whenData((messages) {
      final lastId = messages.isEmpty ? -1 : messages.last.id;
      if (lastId != _lastMessageId) {
        _lastMessageId = lastId;
        _scrollToBottomSoon();
      }
    });

    // 收藏/静音状态从频道列表 provider 里取(详情页本身不单独拉频道详情),
    // 列表还没加载过(比如直接从通知点进来)时找不到,对应按钮就不显示。
    final channels = ref.watch(chatChannelListProvider).value;
    final channel = channels?.where((c) => c.id == widget.channelId).firstOrNull;

    final composeExtras = _buildComposeExtras(scheme);

    final otherUser = (channel != null && channel.isDirectMessage && currentUsername != null)
        ? channel.otherParticipant(currentUsername)
        : null;

    return Scaffold(
      appBar: AppBar(
        // 跟应用其它页面一致:不要 M3 滚动下的 surface tint 灰底
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(widget.title ?? '消息')),
            if (otherUser?.status != null) ...[
              const SizedBox(width: 6),
              UserStatusIcon(
                status: otherUser!.status,
                size: 16,
                onTap: () => _showUserStatus(otherUser),
              ),
            ],
          ],
        ),
        automaticallyImplyLeading: !widget.embeddedMode,
        leading: widget.embeddedMode && widget.onEmbeddedBack != null
            ? BackButton(onPressed: widget.onEmbeddedBack)
            : null,
        actions: [
          if (channel != null) ...[
            IconButton(
              tooltip: channel.membership.starred ? '取消收藏' : '收藏',
              icon: Icon(
                channel.membership.starred
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                color: channel.membership.starred ? Colors.amber : null,
              ),
              onPressed: () => _toggleStarred(channel.membership.starred),
            ),
            IconButton(
              tooltip: '搜索本频道',
              icon: const Icon(Icons.search_rounded),
              onPressed: () =>
                  showChatSearchDialog(context, channelId: widget.channelId),
            ),
            IconButton(
              tooltip: '置顶消息',
              icon: const Icon(Icons.push_pin_outlined),
              onPressed: _showPinnedMessages,
            ),
            IconButton(
              tooltip: '频道设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _showChannelSettings,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (_uploading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(
                    child: Text('暂无消息', style: TextStyle(color: Colors.grey)),
                  );
                }
                // reverse:true 是聊天列表的标准姿势:视口锚定在底部,上面的
                // 内容(图片加载、附件条出现等)高度变化不会把当前位置顶跑
                // ——之前"粘贴图片后列表跳到最上面"就是正向列表在布局高度
                // 突变时 offset 失锚导致的。
                final loadingOlder =
                    ref.watch(chatLoadingOlderProvider(widget.channelId));
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  // 多出的一项是列表顶端(reverse 的最后一项)的加载动画
                  itemCount: messages.length + 1,
                  itemBuilder: (context, index) {
                    if (index == messages.length) {
                      return AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        child: loadingOlder
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 10),
                                child: Center(child: LoadingSpinner(size: 22)),
                              )
                            : const SizedBox(width: double.infinity, height: 0),
                      );
                    }
                    final chronoIndex = messages.length - 1 - index;
                    final message = messages[chronoIndex];
                    final previous =
                        chronoIndex > 0 ? messages[chronoIndex - 1] : null;
                    final isOwn = currentUsername != null &&
                        message.user?.username == currentUsername;
                    final showHeader = previous == null ||
                        previous.user?.username != message.user?.username;
                    // 消息 user 序列化里不一定带 status,拿频道成员表兜底
                    final senderInChannel = channel?.participants
                        .where((p) => p.username == message.user?.username)
                        .firstOrNull;
                    final statusUser = message.user?.status != null
                        ? message.user
                        : senderInChannel;
                    return _ChatMessageBubble(
                      channelId: widget.channelId,
                      message: message,
                      isOwn: isOwn,
                      showHeader: showHeader,
                      userStatus: statusUser?.status,
                      onShowStatus: statusUser != null
                          ? () => _showUserStatus(statusUser)
                          : null,
                      onOpenMenu: () => _showMessageMenu(message, isOwn),
                      onReply: () => _startReply(message),
                      onBookmark: () => _bookmarkMessage(message),
                      pickEmoji: _pickEmoji,
                      onOpenThread: message.thread != null
                          ? () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => DmThreadPage(
                                    channelId: widget.channelId,
                                    threadId: message.thread!.id,
                                    title: message.thread!.title ??
                                        message.threadTitle ??
                                        '消息串',
                                  ),
                                ),
                              )
                          : null,
                    );
                  },
                );
              },
              loading: () => const Center(child: LoadingSpinner()),
              error: (error, stack) => ErrorView(
                error: error,
                stackTrace: stack,
                onRetry: () => ref.invalidate(chatMessagesProvider(widget.channelId)),
              ),
            ),
          ),
          ?composeExtras,
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
                  IconButton(
                    tooltip: '表情',
                    onPressed: _showEmojiPicker,
                    icon: const Icon(Icons.emoji_emotions_outlined),
                  ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _handlePasteKey,
                      // M3E 风格:填充式圆角胶囊输入框,无描边
                      child: TextField(
                        controller: _inputController,
                        focusNode: _inputFocusNode,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: _editing != null ? '编辑消息…' : '发送消息',
                          filled: true,
                          fillColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
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

/// 按 emoji 名字渲染成真正的表情图片(跟正文/表情选择器同一套资源+缓存),
/// 不用裸 unicode 字符——Windows 默认字体对大部分 emoji 只有轮廓/缺字形,
/// 裸文本渲染出来是方块或黑白轮廓,跟应用其它地方的彩色表情对不上。
class _ReactionEmoji extends StatelessWidget {
  const _ReactionEmoji({required this.name, this.size = 16});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: emojiImageProvider(EmojiHandler().getEmojiUrl(name)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => Text(
        ':$name:',
        style: TextStyle(fontSize: size * 0.6),
      ),
    );
  }
}

/// 聊天气泡:自己发的靠右、主题色底,别人发的靠左、灰底,贴近常见聊天
/// App 的观感,而不是像帖子列表那样整行左对齐。
class _ChatMessageBubble extends ConsumerStatefulWidget {
  const _ChatMessageBubble({
    required this.channelId,
    required this.message,
    required this.isOwn,
    required this.showHeader,
    required this.onOpenMenu,
    required this.onReply,
    required this.onBookmark,
    required this.pickEmoji,
    this.userStatus,
    this.onShowStatus,
    this.onOpenThread,
  });

  final int channelId;
  final ChatMessage message;
  final bool isOwn;
  final bool showHeader;
  final VoidCallback onOpenMenu;
  final VoidCallback onReply;
  final VoidCallback onBookmark;
  final UserCustomStatus? userStatus;
  final VoidCallback? onShowStatus;

  /// 打开表情选择器(PC 悬浮面板 / 移动端底部弹层,由页面统一提供)
  final Future<Emoji?> Function() pickEmoji;

  /// 这条消息开了消息串时,点"N 条回复"打开串;频道没开串则为 null
  final VoidCallback? onOpenThread;

  @override
  ConsumerState<_ChatMessageBubble> createState() => _ChatMessageBubbleState();
}

class _ChatMessageBubbleState extends ConsumerState<_ChatMessageBubble> {
  bool _hoverBubble = false;
  bool _hoverPanel = false;
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portalController = OverlayPortalController();

  /// 气泡或面板任意一个被悬浮就显示面板;都离开才收起(面板和气泡有
  /// 几像素重叠,鼠标能连续移过去不断触)。
  void _updateHover({bool? bubble, bool? panel}) {
    setState(() {
      if (bubble != null) _hoverBubble = bubble;
      if (panel != null) _hoverPanel = panel;
    });
    final shouldShow = (_hoverBubble || _hoverPanel) && !message.isDeleted;
    if (shouldShow && !_portalController.isShowing) {
      _portalController.show();
    } else if (!shouldShow && _portalController.isShowing) {
      _portalController.hide();
    }
  }

  ChatMessage get message => widget.message;
  bool get isOwn => widget.isOwn;
  bool get showHeader => widget.showHeader;
  int get channelId => widget.channelId;
  VoidCallback get onOpenMenu => widget.onOpenMenu;

  /// cooked 里含图片/表格/代码块/onebox 等复杂块时不做宽度测量,直接给
  /// 最大宽度让内容自己排(图片网格等场景内部用了 LayoutBuilder,不支持
  /// intrinsic 测量——之前用 IntrinsicWidth 收缩气泡,布局期直接抛
  /// "LayoutBuilder does not support returning intrinsic dimensions",
  /// release 下不红屏,整个 body 连输入栏一起画成空白,就是"直接不显示
  /// 信息了"的根因)。
  /// 真正的内容图片(排除 emoji——emoji 也 cook 成 `<img class="emoji">`,
  /// 之前一刀切匹配 `<img` 导致带 emoji 的消息全部放弃测宽,渲染出来的
  /// 块级段落又默认填满可用宽度,于是"一个 emoji 的消息框长得离谱")。
  static final _contentImgPattern = RegExp(r'<img(?![^>]*class="[^"]*emoji)');

  bool get _hasComplexContent {
    final cooked = message.cooked;
    if (cooked == null) return false;
    return _contentImgPattern.hasMatch(cooked) ||
        cooked.contains('<table') ||
        cooked.contains('<pre') ||
        cooked.contains('<svg') ||
        cooked.contains('<video') ||
        cooked.contains('<audio') ||
        cooked.contains('<iframe') ||
        cooked.contains('class="onebox') ||
        cooked.contains('<aside');
  }

  /// 纯文本消息按原始文字用 TextPainter 量一个"内容宽度",让短消息气泡
  /// 收缩到贴内容,长消息在 maxWidth 处换行。量的是 raw message 而不是
  /// cooked(近似值,够用),加一点余量容纳行内表情图片等稍宽的元素。
  static final _shortcodePattern = RegExp(r':[a-zA-Z0-9_+\-]+(?::t\d)?:');
  // 覆盖常见 emoji 平面:杂项符号/装饰符号区 + SMP 的 surrogate pair 区
  // (U+1F000–U+1FFFF)。不追求学术级精确,量宽度用的近似值足够。
  static final _unicodeEmojiPattern =
      RegExp(r'[☀-➿⬀-⯿]|[\uD83C-\uD83E][\uDC00-\uDFFF]');
  static final _emojiJoinerPattern = RegExp(r'[️‍]');

  double? _measuredWidth(BuildContext context, double maxContentWidth) {
    if (_hasComplexContent) return null;
    final text = message.isDeleted ? '(消息已删除)' : (message.message ?? '');
    if (text.isEmpty && message.inReplyTo == null && message.uploads.isEmpty) {
      return null;
    }

    // emoji 会被 cook 成行内图片,量原始文本时把 `:joy:` 这类 shortcode
    // 和裸 unicode emoji 都剔掉,改按"每个 emoji 一张定宽图"补偿——不然
    // ":distorted_face:" 按 16 个字符量出一大截宽度,渲染出来却只有一张
    // 小图,气泡右边就空一块(被吐槽"单emoji独立成行后面还有空白")。
    var emojiCount = _shortcodePattern.allMatches(text).length;
    var stripped = text.replaceAll(_shortcodePattern, '');
    emojiCount += _unicodeEmojiPattern.allMatches(stripped).length;
    stripped = stripped
        .replaceAll(_unicodeEmojiPattern, '')
        .replaceAll(_emojiJoinerPattern, '');

    // 纯 emoji 消息 Discourse 会放大显示(cooked 里带 only-emoji class)
    final emojiWidth =
        (message.cooked?.contains('only-emoji') ?? false) ? 34.0 : 22.0;

    final style = DefaultTextStyle.of(context).style.merge(
          Theme.of(context).textTheme.bodyMedium,
        );
    final painter = TextPainter(
      text: TextSpan(text: stripped, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxContentWidth);
    var width = painter.width + emojiCount * emojiWidth + 8;

    // 带引用条的消息:引用条(单行小字 + ↩ 图标 + 内边距)也量一次,
    // 气泡取"正文 vs 引用条"里较宽的那个——之前直接放弃测宽,块级渲染
    // 一填满就成了通栏,又被抓到"带回复的消息长度不对"。
    final inReplyTo = message.inReplyTo;
    if (inReplyTo != null && !message.isDeleted) {
      final quotePainter = TextPainter(
        text: TextSpan(
          text: '${inReplyTo.username ?? ''}: ${inReplyTo.excerpt ?? ''}',
          style: style.copyWith(fontSize: 12),
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: maxContentWidth);
      // 12 图标 + 4 间距 + 16 引用条内边距 + 少许余量
      final quoteWidth = quotePainter.width + 12 + 4 + 16 + 6;
      if (quoteWidth > width) width = quoteWidth;
    }

    // 带图片/附件:附件块最宽 320,气泡至少要容得下它
    if (message.uploads.isNotEmpty) {
      const uploadWidth = 320.0;
      if (uploadWidth > width) width = uploadWidth;
    }

    return width.clamp(24.0, maxContentWidth);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'chat_msg_${message.id}',
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPadding = 12.0;
        final maxBubbleWidth =
            (constraints.maxWidth * 0.72 - 72).clamp(160.0, 560.0);
        final maxContentWidth = maxBubbleWidth - horizontalPadding * 2;
        final contentWidth = _measuredWidth(context, maxContentWidth);

        final bubble = Container(
          width: contentWidth != null ? contentWidth + horizontalPadding * 2 : null,
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          padding: const EdgeInsets.symmetric(
              horizontal: horizontalPadding, vertical: 8),
          decoration: BoxDecoration(
            color: isOwn ? scheme.primaryContainer : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isOwn ? 16 : 4),
              bottomRight: Radius.circular(isOwn ? 4 : 16),
            ),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              color: isOwn ? scheme.onPrimaryContainer : scheme.onSurface,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.inReplyTo != null && !message.isDeleted)
                  // 引用条:不要通栏、不要"前端味"的左竖线,一行紧凑摘要
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.reply_rounded,
                            size: 12, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${message.inReplyTo!.username ?? ''}: '
                            '${message.inReplyTo!.excerpt ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!message.isDeleted &&
                    (message.cooked?.isNotEmpty ?? false))
                  callbacks.render(cookedHtml: message.cooked!, compact: true)
                else if (!message.isDeleted &&
                    (message.message?.isNotEmpty ?? false))
                  Text(message.message!),
                if (message.isDeleted)
                  const Text('(消息已删除)',
                      style: TextStyle(color: Colors.grey)),
                // 图片/附件不在 cooked 里(官方 MessageSerializer 单独给
                // uploads 数组,网页端也是正文下方另行渲染),这里补上
                if (!message.isDeleted)
                  for (final upload in message.uploads)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _ChatUploadView(upload: upload),
                    ),
                // 消息串入口:线程原始消息下挂"N 条回复"胶囊
                if (message.thread != null &&
                    widget.onOpenThread != null &&
                    !message.isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: widget.onOpenThread,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.surface.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.forum_outlined,
                                size: 13, color: scheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              '${message.thread!.replyCount} 条回复',
                              style: TextStyle(
                                  fontSize: 12, color: scheme.primary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if ((message.edited || message.pinned) && !message.isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.pinned) ...[
                          Icon(Icons.push_pin_rounded,
                              size: 11, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 2),
                        ],
                        if (message.edited)
                          Text(
                            '(已编辑)',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );

        final reactionsRow = message.reactions.isEmpty
            ? null
            : Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final reaction in message.reactions)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => ref
                          .read(chatMessagesProvider(channelId).notifier)
                          .toggleReaction(message.id, reaction.emoji),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: reaction.reacted
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                          border: reaction.reacted
                              ? Border.all(color: scheme.primary, width: 1)
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ReactionEmoji(name: reaction.emoji, size: 14),
                            const SizedBox(width: 3),
                            Text('${reaction.count}',
                                style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                ],
              );

        // 点头像弹用户资料卡(同帖子楼层头像的行为)
        final avatar = Builder(
          builder: (avatarCtx) => GestureDetector(
            onTap: message.user == null
                ? null
                : () {
                    final box = avatarCtx.findRenderObject() as RenderBox?;
                    if (box == null || !box.hasSize) return;
                    showUserCard(
                      context: avatarCtx,
                      anchorRect: box.localToGlobal(Offset.zero) & box.size,
                      username: message.user!.username,
                      nameFallback: message.user!.name,
                      avatarFallbackUrl: message.user!
                          .getAvatarUrl(AppConstants.baseUrl, size: 144),
                    );
                  },
            child: SmartAvatar(
              imageUrl:
                  message.user?.getAvatarUrl(AppConstants.baseUrl, size: 40),
              radius: 16,
              fallbackText: (message.user?.username ?? '?').isNotEmpty
                  ? message.user!.username[0]
                  : '?',
            ),
          ),
        );


        final tappableBubble = GestureDetector(
          onLongPress: onOpenMenu,
          onSecondaryTap: onOpenMenu,
          child: bubble,
        );

        // 锚点只挂在气泡本体上(不含头像上方的用户名/时间行)——否则悬浮
        // 面板会以整行(含头顶名字行)的顶部为基准,盖住名字/时间那一行。
        final bubbleRow = CompositedTransformTarget(
          link: _link,
          child: tappableBubble,
        );

        final children = <Widget>[
          if (!isOwn) ...[
            showHeader ? avatar : const SizedBox(width: 32),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (showHeader)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2, left: 4, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            message.user?.name ?? message.user?.username ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        if (widget.userStatus != null) ...[
                          const SizedBox(width: 4),
                          UserStatusIcon(
                            status: widget.userStatus,
                            size: 13,
                            onTap: widget.onShowStatus,
                          ),
                        ],
                        Text(
                          ' · ${TimeUtils.formatCompactTime(message.createdAt)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                bubbleRow,
                if (reactionsRow != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: reactionsRow,
                  ),
              ],
            ),
          ),
          if (isOwn) const SizedBox(width: 8),
        ];

        // 悬浮面板浮在消息**上方**(对齐官方网页端 message-actions 的位
        // 置)。不能用列表项内 Stack 负偏移——reverse 列表里上一行画得更
        // 晚会盖住它;OverlayPortal 挂到应用 Overlay 层,永远在最上面。
        return OverlayPortal(
          controller: _portalController,
          overlayChildBuilder: (overlayCtx) => CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: isOwn ? Alignment.topRight : Alignment.topLeft,
            followerAnchor: isOwn ? Alignment.bottomRight : Alignment.bottomLeft,
            // 往下压几像素让面板和消息行有重叠,鼠标能连续移过去
            offset: const Offset(0, 10),
            child: Align(
              alignment: isOwn ? Alignment.bottomRight : Alignment.bottomLeft,
              child: MouseRegion(
                onEnter: (_) => _updateHover(panel: true),
                onExit: (_) => _updateHover(panel: false),
                child: _buildHoverPanel(Theme.of(overlayCtx).colorScheme),
              ),
            ),
          ),
          child: MouseRegion(
            onEnter: (_) => _updateHover(bubble: true),
            onExit: (_) => _updateHover(bubble: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Row(
                mainAxisAlignment:
                    isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 悬浮小面板:最近用过的 3 个快捷回应 + 全量表情 + 书签 + 回复 + 更多。
  /// 桌面端 hover 出现;移动端没有 hover,长按气泡走完整底部菜单。
  Widget _buildHoverPanel(ColorScheme scheme) {
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
                onPressed: () => ref
                    .read(chatMessagesProvider(channelId).notifier)
                    .toggleReaction(message.id, name),
                icon: _ReactionEmoji(name: name, size: 18),
              ),
            IconButton(
              tooltip: '更多表情',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                final emoji = await widget.pickEmoji();
                if (emoji != null) {
                  unawaited(ref
                      .read(chatMessagesProvider(channelId).notifier)
                      .toggleReaction(message.id, emoji.name));
                }
              },
              icon: Icon(Icons.add_reaction_outlined,
                  color: scheme.onSurfaceVariant),
            ),
            IconButton(
              tooltip: message.bookmark != null ? '修改书签' : '书签',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: widget.onBookmark,
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
              onPressed: widget.onReply,
              icon: Icon(Icons.reply_rounded, color: scheme.onSurfaceVariant),
            ),
            IconButton(
              tooltip: '更多',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: onOpenMenu,
              icon: Icon(Icons.more_vert_rounded, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 消息附带的上传文件:图片直接展示(限宽等比),其它文件画成附件卡片,
/// 点击用系统方式打开源链接。
class _ChatUploadView extends StatelessWidget {
  const _ChatUploadView({required this.upload});

  final ChatUpload upload;

  String get _resolvedUrl {
    final url = upload.url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) return '${AppConstants.baseUrl}$url';
    return url;
  }

  @override
  Widget build(BuildContext context) {
    if (upload.isImage) {
      final width = upload.width;
      final height = upload.height;
      final aspect = (width != null && height != null && height > 0)
          ? width / height
          : null;
      return GestureDetector(
        onTap: () => ImageViewerPage.open(
          context,
          _resolvedUrl,
          heroTag: 'chat_upload_${upload.id ?? upload.url}',
          filenames: [upload.originalFilename],
          // 对齐话题里点图的完整体验(分享/保存等操作)
          enableShare: true,
        ),
        child: Hero(
          tag: 'chat_upload_${upload.id ?? upload.url}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
              child: aspect != null
                  ? AspectRatio(
                      aspectRatio: aspect,
                      child: CachedImage(url: _resolvedUrl, fit: BoxFit.cover),
                    )
                  : CachedImage(url: _resolvedUrl, fit: BoxFit.contain),
            ),
          ),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => launchUrl(Uri.parse(_resolvedUrl),
          mode: LaunchMode.externalApplication),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.attach_file_rounded, size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                upload.originalFilename ?? '附件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposeMenuRow extends StatelessWidget {
  const _ComposeMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// AI 频道总结弹窗:时间范围下拉 + 只读摘要区,对齐官方
/// chat-modal-channel-summary 组件(纯展示,不写回输入框)。
class _ChatSummaryDialog extends ConsumerStatefulWidget {
  const _ChatSummaryDialog({required this.channelId});

  final int channelId;

  @override
  ConsumerState<_ChatSummaryDialog> createState() => _ChatSummaryDialogState();
}

class _ChatSummaryDialogState extends ConsumerState<_ChatSummaryDialog> {
  static const _sinceOptions = [1, 3, 6, 12, 24, 72, 168];
  int? _sinceHours;
  bool _loading = false;
  String? _error;
  final Map<int, String> _cache = {};

  Future<void> _summarize(int since) async {
    setState(() {
      _sinceHours = since;
      _error = null;
    });
    if (_cache.containsKey(since)) return;
    setState(() => _loading = true);
    try {
      final summary = await ref
          .read(discourseServiceProvider)
          .summarizeChatChannel(widget.channelId, since);
      if (!mounted) return;
      setState(() => _cache[since] = summary);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '总结失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _label(int hours) {
    if (hours < 24) return '过去 $hours 小时';
    return '过去 ${hours ~/ 24} 天';
  }

  @override
  Widget build(BuildContext context) {
    final summary = _sinceHours == null ? null : _cache[_sinceHours];
    return AlertDialog(
      title: const Text('总结消息'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择要总结的时间范围', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: _sinceHours,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final h in _sinceOptions)
                  DropdownMenuItem(value: h, child: Text(_label(h))),
              ],
              onChanged: (v) {
                if (v != null) _summarize(v);
              },
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 80, maxHeight: 320),
              child: SingleChildScrollView(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: LoadingSpinner()),
                      )
                    : _error != null
                        ? Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                        : Text(summary ?? '选择时间范围以生成总结'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
