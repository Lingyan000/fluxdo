import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_channel.dart';
import '../../models/chat/chat_message.dart';
import '../../models/mention_user.dart';
import '../../models/template.dart';
import '../../providers/chat/chat_channels_provider.dart';
import '../../providers/chat/chat_messages_provider.dart';
import '../../providers/chat/chat_typing_provider.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/message_bus/models.dart' show TypingUser;
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';
import '../../services/toast_service.dart';
import '../../utils/adaptive_menu.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/platform_utils.dart';
import '../../utils/emoji_shortcodes.dart';
import '../../utils/time_utils.dart';
import '../../utils/url_helper.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/relative_time_text.dart';
import '../../widgets/common/radial_long_press_menu.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/user/avatar_action_menu.dart';
import '../../widgets/user/user_card.dart';
import '../../widgets/markdown_editor/emoji_popover.dart';
import '../../widgets/markdown_editor/emoji_sticker_panel.dart';
import '../../widgets/markdown_editor/markdown_renderer.dart';
import '../image_viewer_page.dart';
import 'chat_list_page.dart' show ChatChannelAvatar, chatPreviewText;
import 'chat_channel_info_page.dart';
import 'chat_flag_sheet.dart';
import 'chat_composer_controller.dart';
import 'chat_search_page.dart';
import 'package:common_ui/common_ui.dart';
import 'chat_message_menu.dart';

/// 聊天窗:气泡流 + 底部常驻输入条
///
/// 视觉对齐 AiChatMessageItem(气泡)与 AiChatInput(输入条)。
/// [threadId] 非空时为 thread 面板形态:同一套气泡流,数据/订阅/发送
/// 全走 thread 维度,标题显示"消息串"。
class ChatChannelPage extends ConsumerStatefulWidget {
  final int channelId;
  final int? threadId;

  /// 非空:首屏锚点定位到这条消息并高亮(通知/链接直达)
  final int? initialMessageId;

  /// 桌面双栏嵌入形态:返回键走 [onEmbeddedBack] 而非 Navigator pop
  final bool embeddedMode;
  final VoidCallback? onEmbeddedBack;

  const ChatChannelPage({
    super.key,
    required this.channelId,
    this.threadId,
    this.initialMessageId,
    this.embeddedMode = false,
    this.onEmbeddedBack,
  });

  @override
  ConsumerState<ChatChannelPage> createState() => _ChatChannelPageState();
}

class _ChatChannelPageState extends ConsumerState<ChatChannelPage> {
  final AutoScrollController _scrollController = AutoScrollController();
  final ChatComposerController _inputController = ChatComposerController();
  final FocusNode _inputFocus = FocusNode();
  bool _canSend = false;

  /// 编辑态:非空表示输入条在编辑这条消息
  ChatMessage? _editing;

  /// 回复态:非空表示发送时带 in_reply_to_id
  ChatMessage? _replyingTo;

  /// 正在输入上报器(击键 enter presence,5s 静默/发送时 leave;
  /// hide_presence 用户完全静默)
  late final ChatTypingReporter _typingReporter = ChatTypingReporter(
    () => ref.read(discourseServiceProvider),
    widget.channelId,
    isEnabled: () => ref.read(currentUserProvider).value?.hidePresence != true,
  );

  /// 高亮的消息 id(定位跳转落点,3s 后淡出)
  int? _highlightedMessageId;

  /// 活动锚点(进入时=widget.initialMessageId;"回到最新"时清空并原地
  /// 换 provider key 重载,不再整页路由替换)
  int? _anchorMessageId;

  /// 频道置顶消息(站点开 chat_pinned_messages 才有;进频道拉一次,
  /// pin/unpin 广播增量维护);多条时横幅点击轮换
  List<ChatMessage> _pins = const [];
  int _pinCursor = 0;

  /// 已展开的删除消息 id(官方口径:连续删除段折叠成一行,点击整段展开)
  final Set<int> _expandedDeletedIds = {};
  Timer? _highlightTimer;

  /// 多选模式:非空集合语义由 _selecting 承担(空集合=选择模式刚开启)
  bool _selecting = false;
  final Set<int> _selectedIds = {};

  /// 离开底部(reverse 列表 pixels>阈值)时显示"回到底部"浮钮
  /// 离底跟踪之外,滚动进行中标志:桌面 hover 工具条在滚动时抑制,
  /// 否则光标不动、气泡从下面划过,onEnter/onExit 连环触发 → 工具条
  /// 在不同消息上反复闪现(用户点名)。滚动停止 160ms 后复位。
  bool _awayFromBottom = false;
  final ValueNotifier<bool> _scrolling = ValueNotifier<bool>(false);
  Timer? _scrollIdleTimer;

  /// 草稿:击键节流上报(对齐网页版 drafts 自动保存);进场回填
  Timer? _draftDebounce;
  String _lastSavedDraft = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _inputController.addListener(() {
      final canSend = _inputController.text.trim().isNotEmpty;
      if (canSend != _canSend) setState(() => _canSend = canSend);
      if (_inputController.text.isNotEmpty) _typingReporter.onTyping();
      _scheduleDraftSave();
    });
    // 定位模式:进场即高亮目标消息
    _anchorMessageId = widget.initialMessageId;
    if (widget.threadId == null) _loadPins();
    if (_anchorMessageId != null) {
      _flashHighlight(_anchorMessageId!);
    }
    _restoreDraft();
  }

  @override
  void dispose() {
    _typingReporter.dispose();
    _highlightTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _scrolling.dispose();
    _draftDebounce?.cancel();
    // 退出即存(不等节流窗口;编辑态不算草稿)
    if (_editing == null && _inputController.text != _lastSavedDraft) {
      _persistDraft(_inputController.text);
    }
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 进场回填草稿:current_user.chat_drafts 只在登录时下发一次,
  /// 本会话内新存的草稿以服务端为准——这里只做冷启动回填,够用
  void _restoreDraft() {
    final drafts = ref.read(currentUserProvider).value?.chatDrafts;
    if (drafts == null) return;
    final match = drafts.where((d) {
      final sameChannel = d['channel_id'] == widget.channelId;
      final draftThreadId = d['thread_id'] as int?;
      return sameChannel && draftThreadId == widget.threadId;
    }).firstOrNull;
    final dataRaw = match?['data'];
    if (dataRaw is! String || dataRaw.isEmpty) return;
    try {
      final data = jsonDecode(dataRaw) as Map<String, dynamic>;
      final message = data['message'] as String?;
      if (message != null &&
          message.isNotEmpty &&
          _inputController.text.isEmpty) {
        _inputController.text = message;
        _lastSavedDraft = message;
      }
    } catch (_) {
      // 草稿损坏静默忽略
    }
  }

  void _scheduleDraftSave() {
    if (_editing != null) return; // 编辑态不覆盖草稿
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(seconds: 2), () {
      final text = _inputController.text;
      if (text == _lastSavedDraft) return;
      _persistDraft(text);
    });
  }

  void _persistDraft(String text) {
    _lastSavedDraft = text;
    unawaited(
      ref
          .read(discourseServiceProvider)
          .saveChatDraft(
            widget.channelId,
            threadId: widget.threadId,
            data: text.trim().isEmpty ? null : {'message': text},
          ),
    );
  }

  void _flashHighlight(int messageId) {
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  /// 跳到某条消息:已在窗口内→滚动+高亮;窗口外→整页按锚点重进
  Future<void> _loadPins() async {
    try {
      final pins = await ref
          .read(discourseServiceProvider)
          .getChannelPins(widget.channelId);
      if (!mounted) return;
      setState(() {
        _pins = pins;
        _pinCursor = 0;
      });
      // 打开频道即视为看过置顶(顶栏徽记语义,静默失败无害)
      if (pins.isNotEmpty) {
        unawaited(
          ref
              .read(discourseServiceProvider)
              .markChannelPinsRead(widget.channelId)
              .catchError((_) {}),
        );
      }
    } catch (_) {
      // 站点未开 chat_pinned_messages 时 404,静默
    }
  }

  /// pin/unpin 广播落到消息流后,横幅列表跟着增删
  void _syncPinsFromMessages(List<ChatMessage> messages) {
    var changed = false;
    final pins = [..._pins];
    for (final m in messages) {
      final index = pins.indexWhere((p) => p.id == m.id);
      if (m.pinned && index < 0) {
        pins.add(m);
        changed = true;
      } else if (!m.pinned && index >= 0) {
        pins.removeAt(index);
        changed = true;
      } else if (index >= 0) {
        pins[index] = m;
      }
    }
    if (changed && mounted) {
      setState(() {
        _pins = pins;
        if (_pinCursor >= pins.length) _pinCursor = 0;
      });
    }
  }

  void _jumpToMessage(int messageId) {
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    final inWindow = state?.messages.any((m) => m.id == messageId) ?? false;
    if (inWindow && state != null) {
      // AutoScrollTag 的 index 用消息 id(稳定,不随窗口翻页漂移)
      unawaited(
        _scrollController.scrollToIndex(
          messageId,
          preferPosition: AutoScrollPosition.middle,
          duration: const Duration(milliseconds: 250),
        ),
      );
      _flashHighlight(messageId);
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatChannelPage(
          channelId: widget.channelId,
          threadId: widget.threadId,
          initialMessageId: messageId,
        ),
      ),
    );
  }

  /// 会话内搜索(channel_id 限定,点结果锚点跳转)
  void _openInChannelSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatSearchPage(channelId: widget.channelId),
      ),
    );
  }

  /// AI 总结近期消息:选时间档 → 请求 → 弹层渲染 markdown
  Future<void> _summarize() async {
    const options = [1, 3, 6, 12, 24, 72, 168];
    final since = await AppBottomSheet.show<int>(
      context: context,
      title: S.current.chat_summarize,
      showCloseButton: false,
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final h in options)
            ListTile(
              title: Text(
                h < 24
                    ? sheetContext.l10n.chat_summarizeHours(h)
                    : sheetContext.l10n.chat_summarizeDays(h ~/ 24),
              ),
              onTap: () => Navigator.pop(sheetContext, h),
            ),
        ],
      ),
    );
    if (since == null || !mounted) return;
    // 慢请求:骨架弹层等待,完成后原地换渲染。
    // future 必须在 bodyBuilder 外创建一次——DraggableScrollableSheet
    // 拖动会反复 rebuild,内联创建等于拖一下请求一次
    final future = ref
        .read(discourseServiceProvider)
        .summarizeChatChannel(widget.channelId, sinceHours: since);
    unawaited(
      AppBottomSheet.showDraggable<void>(
        context: context,
        title: S.current.chat_summarize,
        initialSize: 0.6,
        bodyBuilder: (sheetContext, scrollController) => FutureBuilder<String>(
          future: future,
          builder: (futureContext, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: LoadingSpinner());
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(snapshot.error.toString()),
              );
            }
            final summary = snapshot.data ?? '';
            return SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              // 总结是 AI 生成的 markdown(含 /t/-/... 消息链接),
              // cook 后走新引擎渲染,链接可点
              child: MarkdownBody(data: summary),
            );
          },
        ),
      ),
    );
  }

  /// 当前频道(DM 与公共频道双列表查找——只查 DM 会让公共频道
  /// 处处拿到 null:标题不可点/能力位全关/回复分流失效)
  ChatChannel? _findChannel() {
    final state = ref.read(chatChannelsProvider).value;
    if (state == null) return null;
    return [
      ...state.directMessageChannels,
      ...state.publicChannels,
    ].where((c) => c.id == widget.channelId).firstOrNull;
  }

  ChatStreamKey get _streamKey => (
    channelId: widget.channelId,
    threadId: widget.threadId,
    targetMessageId: _anchorMessageId,
  );

  ChatMessagesNotifier get _notifier =>
      ref.read(chatMessagesProvider(_streamKey).notifier);

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 列表 reverse:true —— pixels 越大越接近历史顶部
    if (position.pixels > position.maxScrollExtent - 400) {
      _notifier.loadPast();
    }
    if (position.pixels < 200) {
      _notifier.loadFuture();
    }
    final away = position.pixels > 600;
    if (away != _awayFromBottom) {
      setState(() => _awayFromBottom = away);
    }
    // 滚动进行中:抑制 hover 工具条;停止 160ms 后复位
    if (!_scrolling.value) _scrolling.value = true;
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(milliseconds: 160), () {
      _scrolling.value = false;
    });
  }

  /// 回到最新:窗口含最新页直接滚底;不含最新页(锚点定位/往新翻页
  /// 未到底)时清锚点原地重载——provider key 变化自动拉最新窗口,
  /// 页面路由不动(旧版整页 pushReplacement 有转场闪断)
  void _jumpToLatest() {
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    if (state != null && !state.canLoadMoreFuture) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }
    if (_anchorMessageId != null) {
      // key 变化 → 新 provider 按 fetchFromLastRead 拉最新窗口
      setState(() => _anchorMessageId = null);
    } else {
      // 无锚点但窗口不含最新页:同 key 强制重载
      ref.invalidate(chatMessagesProvider(_streamKey));
    }
  }

  Future<void> _send({List<int> uploadIds = const []}) async {
    final text = _inputController.text;
    if (text.trim().isEmpty && uploadIds.isEmpty) return;
    _typingReporter.stop();
    // 发送即清草稿意图:服务端发送成功会自动清 draft 记录,本地只需
    // 取消待发的节流保存并同步基线
    _draftDebounce?.cancel();
    _lastSavedDraft = '';

    // 编辑态:提交编辑而不是发新消息
    final editing = _editing;
    if (editing != null) {
      _inputController.clear();
      setState(() => _editing = null);
      try {
        await _notifier.edit(editing.id, text);
      } catch (e) {
        if (mounted) {
          // 编辑失败:恢复编辑态让用户重试,不丢草稿
          _inputController.text = text;
          setState(() => _editing = editing);
        }
      }
      return;
    }

    final replyTo = _replyingTo;
    _inputController.clear();
    if (replyTo != null) setState(() => _replyingTo = null);
    // 发送后滚回底部(reverse 列表底部是 0)
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    await _notifier.send(text, inReplyToId: replyTo?.id, uploadIds: uploadIds);
  }

  /// 表情包直发(TG 式):不经输入框,选中即独立成一条消息发出;
  /// 带回复上下文时作为回复发出并清除回复条
  Future<void> _sendSticker(String markdown) async {
    final replyTo = _replyingTo;
    if (replyTo != null) setState(() => _replyingTo = null);
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    await _notifier.send(markdown, inReplyToId: replyTo?.id);
  }

  /// 长按头像菜单的 @提及:光标处插入 @username ,聚焦输入框
  void _mentionUser(String username) {
    final controller = _inputController;
    final value = controller.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    // 前一字符非空白时补个空格,避免粘连成无效提及
    final needLeadingSpace =
        start > 0 && !value.text.substring(start - 1, start).trim().isEmpty;
    final insert = '${needLeadingSpace ? ' ' : ''}@$username ';
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _inputFocus.requestFocus();
  }

  /// 触发消息菜单:移动=TG 式长按 overlay;桌面=锚点菜单(右键位置或
  /// hover 工具条按钮位置)。
  Future<void> _onMessageMenu(
    ChatMessage message,
    bool isSelf, {
    Rect? bubbleRect,
    Widget Function(BuildContext)? bubbleBuilder,
    Offset? anchorPosition,
  }) async {
    if (message.isStaged) return;
    final channel = _findChannel();
    final caps = ChatMessageCaps.compute(
      message: message,
      isSelf: isSelf,
      channel: channel,
    );
    final quickReactions = await loadQuickReactions();
    if (!mounted) return;

    final ChatMessageMenuResult? result;
    if (PlatformUtils.isDesktop && anchorPosition != null) {
      result = await showChatMessageContextMenu(
        context: context,
        globalPosition: anchorPosition,
        message: message,
        isSelf: isSelf,
        caps: caps,
        quickReactions: quickReactions,
      );
    } else if (bubbleRect != null && bubbleBuilder != null) {
      result = await showChatMessageActionsOverlay(
        context: context,
        bubbleRect: bubbleRect,
        bubbleBuilder: bubbleBuilder,
        message: message,
        isSelf: isSelf,
        caps: caps,
        quickReactions: quickReactions,
      );
    } else {
      return;
    }
    if (result == null || !mounted) return;
    final (action, emoji) = result;

    if (emoji != null) {
      unawaited(bumpRecentReaction(emoji));
      await _notifier.toggleReaction(message.id, emoji);
      return;
    }
    switch (action) {
      case ChatMessageAction.reply:
        await _startReply(message);
      case ChatMessageAction.copyLink:
        copyChatMessageLink(message);
      case ChatMessageAction.copyText:
        copyChatMessageText(message);
      case ChatMessageAction.edit:
        setState(() {
          _replyingTo = null;
          _editing = message;
          _inputController.text = message.message;
        });
        _inputFocus.requestFocus();
      case ChatMessageAction.delete:
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(dialogContext.l10n.chat_deleteConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(dialogContext.l10n.common_cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(
                  dialogContext.l10n.chat_menuDelete,
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _notifier.delete(message.id);
        }
      case ChatMessageAction.flag:
        await showChatFlagSheet(context: context, message: message);
      case ChatMessageAction.select:
        setState(() {
          _selecting = true;
          _selectedIds
            ..clear()
            ..add(message.id);
        });
      case ChatMessageAction.restore:
        await _notifier.restore(message.id);
      case ChatMessageAction.bookmark:
        try {
          await _notifier.toggleBookmark(message.id);
        } catch (e) {
          ToastService.showError(e.toString());
        }
      case ChatMessageAction.pin:
      case ChatMessageAction.unpin:
        try {
          await _notifier.togglePin(
            message.id,
            pin: action == ChatMessageAction.pin,
          );
        } catch (e) {
          ToastService.showError(e.toString());
        }
      case null:
        break;
    }
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(int messageId) {
    setState(() {
      if (!_selectedIds.add(messageId)) _selectedIds.remove(messageId);
    });
  }

  /// 引用所选:服务端生成 transcript markdown,复制到剪贴板
  Future<void> _quoteSelected() async {
    if (_selectedIds.isEmpty) return;
    try {
      final markdown = await ref
          .read(discourseServiceProvider)
          .quoteChatMessages(widget.channelId, _selectedIds.toList()..sort());
      if (markdown.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: markdown));
        ToastService.showSuccess(S.current.chat_quoteCopied);
      }
      _exitSelection();
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  /// 复制所选原文(按 id 顺序拼接)
  void _copySelected() {
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    if (state == null || _selectedIds.isEmpty) return;
    final texts = [
      for (final m in state.messages)
        if (_selectedIds.contains(m.id) && !m.isDeleted) m.message,
    ];
    Clipboard.setData(ClipboardData(text: texts.join('\n\n')));
    ToastService.showSuccess(S.current.common_copiedToClipboard);
    _exitSelection();
  }

  /// 批量删除所选(仅自己的可删;工具栏按钮已按此禁用)
  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          dialogContext.l10n.chat_deleteSelectedConfirm(_selectedIds.length),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              dialogContext.l10n.chat_menuDelete,
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(discourseServiceProvider)
          .deleteChatMessages(widget.channelId, _selectedIds.toList());
      _exitSelection();
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  /// 所选是否全部可删(全是自己的,或频道允许删他人)
  bool _canDeleteSelected() {
    final state = ref.read(chatMessagesProvider(_streamKey)).value;
    final channel = _findChannel();
    final currentUserId = ref.read(currentUserProvider).value?.id;
    if (state == null || currentUserId == null) return false;
    for (final m in state.messages) {
      if (!_selectedIds.contains(m.id)) continue;
      final isSelf = m.user?.id == currentUserId;
      final can = isSelf
          ? (channel?.canDeleteSelf ?? true)
          : (channel?.canDeleteOthers ?? false);
      if (!can) return false;
    }
    return true;
  }

  /// 打开 thread 面板(窄屏 push,宽屏也 push——thread 是临时查看面)
  void _openThread(int threadId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatChannelPage(channelId: widget.channelId, threadId: threadId),
      ),
    );
  }

  /// 回复语义分流(对齐网页版):
  /// - threading 频道 + 主流:回复 = 进消息串(已有串直接进,没有则建),
  ///   平面 in_reply_to 的 sent 广播只发 thread 子通道,主流对账不到
  /// - 非 threading 频道 / thread 面板内:平面 in_reply_to 回复态
  Future<void> _startReply(ChatMessage message) async {
    final channel = _findChannel();
    final threading = channel?.threadingEnabled ?? false;

    if (threading && widget.threadId == null && !message.isStaged) {
      try {
        final existingThreadId = message.thread?.id ?? message.threadId;
        final threadId =
            existingThreadId ??
            await ref
                .read(discourseServiceProvider)
                .createChatThread(
                  widget.channelId,
                  originalMessageId: message.id,
                );
        if (!mounted) return;
        _openThread(threadId);
      } catch (e) {
        ToastService.showError(e.toString());
      }
      return;
    }

    setState(() {
      _editing = null;
      _replyingTo = message;
    });
    _inputFocus.requestFocus();
  }

  Future<void> _onQuickReact(ChatMessage message, String emoji) async {
    unawaited(bumpRecentReaction(emoji));
    await _notifier.toggleReaction(message.id, emoji);
  }

  /// 在窗口底部即把已读位推进到窗口内最新一条(渐进上报,服务端单调)。
  /// 不再要求窗口含全站最新页:锚点进入大量未读时那个条件永不满足,
  /// 已读永不上报,列表徽章永不清(网页版进一下频道才好=它替我们报了)。
  void _maybeMarkRead(ChatMessagesState state) {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels > 100) return;
    final lastReal = state.messages.where((m) => !m.isStaged).lastOrNull;
    if (lastReal != null) {
      _notifier.markReadUpTo(lastReal.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messagesAsync = ref.watch(chatMessagesProvider(_streamKey));
    final channelsState = ref.watch(chatChannelsProvider).value;
    final channel = channelsState == null
        ? null
        : [
            ...channelsState.directMessageChannels,
            ...channelsState.publicChannels,
          ].where((c) => c.id == widget.channelId).firstOrNull;

    ref.listen(chatMessagesProvider(_streamKey), (prev, next) {
      final state = next.value;
      if (state == null) return;
      // 锚点模式首屏就绪:滚到目标消息(仅一次,prev 无数据时)
      final target = _anchorMessageId;
      if (target != null && prev?.value == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollController.scrollToIndex(
            target,
            preferPosition: AutoScrollPosition.middle,
            duration: const Duration(milliseconds: 250),
          );
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeMarkRead(state);
      });
      if (widget.threadId == null) _syncPinsFromMessages(state.messages);
    });

    return Scaffold(
      // 键盘让位由 ChatBottomPanelContainer 的占位承担(编辑器同款),
      // Scaffold 再 resize 会双重抬升
      resizeToAvoidBottomInset: false,
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Symbols.close_rounded),
                onPressed: _exitSelection,
              ),
              title: Text(context.l10n.chat_selectedCount(_selectedIds.length)),
            )
          : AppBar(
              automaticallyImplyLeading: !widget.embeddedMode,
              leading: widget.embeddedMode && widget.onEmbeddedBack != null
                  ? BackButton(onPressed: widget.onEmbeddedBack)
                  : null,
              titleSpacing: 0,
              title: _buildTitle(channel),
              actions: [
                SwipeDismissiblePopupMenuButton<String>(
                  icon: const Icon(Symbols.more_vert_rounded),
                  onSelected: (value) {
                    switch (value) {
                      case 'search':
                        _openInChannelSearch();
                      case 'summarize':
                        _summarize();
                      case 'refresh':
                        // 整流重载:重拉频道详情+消息窗口+重订阅 bus
                        // (断连漏消息/漏事件时的手动兜底)
                        ref.invalidate(chatMessagesProvider(_streamKey));
                    }
                  },
                  itemBuilder: (menuContext) => [
                    PopupMenuItem(
                      value: 'search',
                      child: Row(
                        children: [
                          const Icon(Symbols.search_rounded, size: 20),
                          const SizedBox(width: 12),
                          Text(menuContext.l10n.chat_searchInChannel),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'summarize',
                      child: Row(
                        children: [
                          const Icon(Symbols.summarize_rounded, size: 20),
                          const SizedBox(width: 12),
                          Text(menuContext.l10n.chat_summarize),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'refresh',
                      child: Row(
                        children: [
                          const Icon(Symbols.refresh_rounded, size: 20),
                          const SizedBox(width: 12),
                          Text(menuContext.l10n.chat_refresh),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: messagesAsync.when(
                    data: (state) => _buildMessageList(theme, state),
                    loading: () => const Center(child: LoadingSpinner()),
                    error: (error, stack) => ErrorView(
                      error: error,
                      stackTrace: stack,
                      onRetry: () =>
                          ref.invalidate(chatMessagesProvider(_streamKey)),
                    ),
                  ),
                ),
                // 置顶横幅(TG 式:顶栏下,点击跳转,多条轮换)
                if (_pins.isNotEmpty)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _PinnedBanner(
                      pins: _pins,
                      cursor: _pinCursor % _pins.length,
                      onTap: () {
                        final pin = _pins[_pinCursor % _pins.length];
                        setState(
                          () => _pinCursor =
                              (_pinCursor + 1) % _pins.length,
                        );
                        _jumpToMessage(pin.id);
                      },
                    ),
                  ),
                // 回到底部浮钮(离底/锚点模式时出现)
                Positioned(
                  right: 16,
                  bottom: 12,
                  child: AnimatedScale(
                    scale:
                        _awayFromBottom ||
                            (messagesAsync.value?.canLoadMoreFuture ?? false)
                        ? 1
                        : 0,
                    duration: const Duration(milliseconds: 150),
                    child: FloatingActionButton.small(
                      heroTag: 'chatJumpBottom_${widget.channelId}',
                      elevation: 2,
                      onPressed: _jumpToLatest,
                      child: const Icon(
                        Symbols.keyboard_double_arrow_down_rounded,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_selecting) ...[
            _SelectionToolbar(
              count: _selectedIds.length,
              canDelete: _selectedIds.isNotEmpty && _canDeleteSelected(),
              onQuote: _quoteSelected,
              onCopy: _copySelected,
              onDelete: _deleteSelected,
            ),
          ] else ...[
            _ChatComposer(
              controller: _inputController,
              focusNode: _inputFocus,
              canSend: _canSend,
              editing: _editing,
              replyingTo: _replyingTo,
              onSend: (uploadIds) => _send(uploadIds: uploadIds),
              onSendSticker: _sendSticker,
              onCancelContext: () => setState(() {
                if (_editing != null) _inputController.clear();
                _editing = null;
                _replyingTo = null;
              }),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTitle(ChatChannel? channel) {
    final theme = Theme.of(context);
    // thread 面板:标题固定"消息串",副标题带频道名
    if (widget.threadId != null) {
      final channelTitle = channel?.title?.isNotEmpty == true
          ? channel!.title!
          : channel?.dmUsers.map((u) => u.username).join(', ') ?? '';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.chat_threadTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (channelTitle.isNotEmpty)
              Text(
                channelTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      );
    }
    if (channel == null) return const SizedBox.shrink();
    final title = channel.title?.isNotEmpty == true
        ? channel.title!
        : channel.dmUsers.map((u) => u.username).join(', ');
    return InkWell(
      // 标题统一进会话详情页(成员管理/退出;1:1 里再跳资料)
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatChannelInfoPage(channelId: widget.channelId),
        ),
      ),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatChannelAvatar(channel: channel, radius: 17),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _buildSubtitle(theme, channel),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏副标题(TG 口径):有人输入时显示"xxx 正在输入…"(主色+动画点),
  /// 空闲回落成员数;1:1 DM 空闲无副标题
  Widget _buildSubtitle(ThemeData theme, ChatChannel channel) {
    final typingUsers = widget.threadId == null
        ? ref.watch(chatTypingProvider(widget.channelId))
        : const <TypingUser>[];
    if (typingUsers.isNotEmpty) {
      return _TypingSubtitle(
        text: typingUsers.length == 1
            ? context.l10n.chat_typingOne(typingUsers.first.username)
            : context.l10n.chat_typingMany(typingUsers.length),
        style: theme.textTheme.labelSmall!.copyWith(
          color: theme.colorScheme.primary,
        ),
      );
    }
    if ((channel.isGroupDm || channel.isPublicChannel) &&
        (channel.membershipsCount ?? 0) > 0) {
      return Text(
        context.l10n.chat_memberCount(channel.membershipsCount!),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildMessageList(ThemeData theme, ChatMessagesState state) {
    if (state.messages.isEmpty) {
      return Center(
        child: Text(
          context.l10n.chat_noMessages,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final currentUserId = ref.watch(currentUserProvider).value?.id;
    // reverse 列表:index 0 = 最新消息,渲染时倒着取
    final messages = state.messages;

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messages.length + (state.loadingPast ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= messages.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: SizedBox(width: 22, height: 22, child: LoadingSpinner()),
            ),
          );
        }
        final i = messages.length - 1 - index;
        final message = messages[i];
        final prev = i > 0 ? messages[i - 1] : null;

        // 删除折叠(官方 shouldRender 口径):连续删除段里,只有最新一条
        // 渲染折叠入口,更早的同段消息不渲染;展开后逐条正常渲染
        bool collapsedDeleted(ChatMessage m) =>
            m.isDeleted && !_expandedDeletedIds.contains(m.id);
        final next = i + 1 < messages.length ? messages[i + 1] : null;
        if (collapsedDeleted(message) &&
            next != null &&
            collapsedDeleted(next)) {
          return const SizedBox.shrink();
        }
        var deletedRunCount = 0;
        if (collapsedDeleted(message)) {
          for (var j = i; j >= 0 && collapsedDeleted(messages[j]); j--) {
            deletedRunCount++;
          }
        }
        final isSelf =
            currentUserId != null && message.user?.id == currentUserId;
        // 同人 5 分钟内连续消息聚簇:只有簇首显示头像和名字
        final clustered =
            prev != null &&
            prev.user?.id == message.user?.id &&
            !prev.isDeleted &&
            message.createdAt != null &&
            prev.createdAt != null &&
            message.createdAt!.difference(prev.createdAt!).inMinutes < 5;
        final showDayDivider =
            prev == null ||
            (message.createdAt != null &&
                prev.createdAt != null &&
                !_sameDay(message.createdAt!, prev.createdAt!));
        final showUnreadDivider =
            state.initialLastReadId != null &&
            prev != null &&
            prev.id == state.initialLastReadId &&
            message.id > state.initialLastReadId! &&
            !isSelf;

        return AutoScrollTag(
          key: ValueKey('chat_msg_${message.id}'),
          controller: _scrollController,
          index: message.id,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDayDivider && message.createdAt != null)
                _DayDivider(date: message.createdAt!),
              if (showUnreadDivider) const _UnreadDivider(),
              _wrapSelectable(
                message,
                _MessageBubble(
                  message: message,
                  isSelf: isSelf,
                  clustered: clustered && !showDayDivider && !showUnreadDivider,
                  scrolling: _scrolling,
                  highlighted: _highlightedMessageId == message.id,
                  onMenuRequested:
                      (bubbleRect, bubbleBuilder, anchorPosition) =>
                          _onMessageMenu(
                            message,
                            isSelf,
                            bubbleRect: bubbleRect,
                            bubbleBuilder: bubbleBuilder,
                            anchorPosition: anchorPosition,
                          ),
                  onQuickReply: () => _startReply(message),
                  onQuickReact: (emoji) => _onQuickReact(message, emoji),
                  onReactionTap: (emoji) => _onQuickReact(message, emoji),
                  onReplyRefTap: message.inReplyTo != null
                      ? () => _jumpToMessage(message.inReplyTo!.id)
                      : null,
                  // thread 面板里不再嵌套入口
                  onOpenThread:
                      widget.threadId == null &&
                          message.thread != null &&
                          message.thread!.replyCount > 0
                      ? () => _openThread(message.thread!.id)
                      : null,
                  onRetry: message.sendState == ChatMessageSendState.failed
                      ? () => _notifier.resend(message.stagedId!)
                      : null,
                  onDiscard: message.sendState == ChatMessageSendState.failed
                      ? () => _notifier.removeStaged(message.stagedId!)
                      : null,
                  onMentionUser: _mentionUser,
                  onToggleBookmark: () async {
                    try {
                      await _notifier.toggleBookmark(message.id);
                    } catch (e) {
                      ToastService.showError(e.toString());
                    }
                  },
                  deletedRunCount: deletedRunCount,
                  deletedExpanded: message.isDeleted
                      ? _expandedDeletedIds.contains(message.id)
                      : false,
                  onExpandDeleted: deletedRunCount > 0
                      ? () => setState(() {
                          for (
                            var j = i;
                            j >= 0 && messages[j].isDeleted;
                            j--
                          ) {
                            _expandedDeletedIds.add(messages[j].id);
                          }
                        })
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 选择模式:气泡左侧勾选圈,整行点击 toggle 并吞掉气泡内交互
  Widget _wrapSelectable(ChatMessage message, Widget bubble) {
    if (!_selecting) return bubble;
    final selectable = !message.isStaged && !message.isDeleted;
    final selected = _selectedIds.contains(message.id);
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: selectable ? () => _toggleSelected(message.id) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              selected ? Symbols.check_circle_rounded : Symbols.circle_rounded,
              fill: selected ? 1 : 0,
              size: 22,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          Expanded(child: IgnorePointer(child: bubble)),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

/// 移动端输入条底部面板类型(键盘位互换,编辑器同款机制)
enum _ComposerPanel { none, keyboard, emoji }

/// 待发附件:本地文件 + 上传状态(上传成功持有 upload id)
class _PendingAttachment {
  final String filePath;
  final String fileName;
  final bool isImage;
  int? uploadId;
  bool failed = false;

  _PendingAttachment({
    required this.filePath,
    required this.fileName,
    required this.isImage,
  });

  bool get uploading => uploadId == null && !failed;
}

/// 输入条:视觉规格对齐 AiChatInput
/// (外壳 surfaceContainerLow + 顶部圆角 16;输入框 filled surface 圆角 20;
///  发送键 IconButton.filled 36×36)
/// 能力:附件(拍照/相册/文件,选即传,带 upload_ids 发送)、@提及自动补全。
class _ChatComposer extends ConsumerStatefulWidget {
  final ChatComposerController controller;
  final FocusNode focusNode;
  final bool canSend;
  final ChatMessage? editing;
  final ChatMessage? replyingTo;

  /// 发送回调,附带已上传完成的 upload id 列表
  final void Function(List<int> uploadIds) onSend;

  /// 表情包直发:不进输入框,选中即作为独立消息发出(TG 式)
  final void Function(String markdown) onSendSticker;
  final VoidCallback onCancelContext;

  const _ChatComposer({
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.editing,
    required this.replyingTo,
    required this.onSend,
    required this.onSendSticker,
    required this.onCancelContext,
  });

  @override
  ConsumerState<_ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends ConsumerState<_ChatComposer> {
  final ImagePicker _imagePicker = ImagePicker();

  /// 桌面表情弹层:锚定输入条表情按钮
  final EmojiPopoverController? _emojiPopover = PlatformUtils.isDesktop
      ? EmojiPopoverController()
      : null;
  Widget? _emojiPanelChild;

  /// 移动端键盘位面板(chat_bottom_container,编辑器同款):
  /// 表情面板与键盘等高互换,不再用底部抽屉(与输入框脱节)
  final _panelController =
      ChatBottomPanelContainerController<_ComposerPanel>();
  _ComposerPanel _currentPanel = _ComposerPanel.none;
  final List<_PendingAttachment> _attachments = [];

  // ---- @提及自动补全 ----
  Timer? _mentionDebounce;
  List<MentionUser> _mentionCandidates = [];

  /// 当前触发中的 @词头在文本里的范围(替换用);null=未触发
  (int, int)? _mentionRange;

  /// 候选条走 Overlay 悬浮在输入条上方(锚定 composer),不占布局
  /// ——放 Column 里会顶起输入区,消息流跟着跳
  final LayerLink _composerLink = LayerLink();
  OverlayEntry? _mentionOverlay;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    // 弹层开合同步表情按钮高亮:关闭路径不止按钮(外点/ESC/resize
    // 都走 controller 内部),必须监听而非在点击处手动 setState
    _emojiPopover?.addListener(_onEmojiPopoverChanged);
  }

  void _onEmojiPopoverChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _mentionDebounce?.cancel();
    _removeMentionOverlay();
    _emojiPopover?.removeListener(_onEmojiPopoverChanged);
    _emojiPopover?.dispose();
    super.dispose();
  }

  /// 桌面弹层面板(只建一次;移动端不用):表情+表情包双 Tab。
  /// 表情插入输入框;表情包 TG 式直发,不进输入框
  Widget _ensureEmojiPanel() {
    _emojiPanelChild ??= EmojiStickerPanel(
      inlineSearch: true,
      compact: true,
      onDismissRequested: () => _emojiPopover?.hide(),
      onEmojiSelected: (emoji) {
        _insertAtCursor(':${emoji.name}:');
        _emojiPopover?.hide();
      },
      onStickerSelected: (markdown) {
        _emojiPopover?.hide();
        widget.onSendSticker(markdown);
      },
    );
    return _emojiPanelChild!;
  }

  void _removeMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
  }

  void _syncMentionOverlay() {
    final show = _mentionCandidates.isNotEmpty && _mentionRange != null;
    if (!show) {
      _removeMentionOverlay();
      return;
    }
    if (_mentionOverlay != null) {
      _mentionOverlay!.markNeedsBuild();
      return;
    }
    _mentionOverlay = OverlayEntry(
      builder: (overlayContext) => Positioned(
        width: MediaQuery.sizeOf(overlayContext).width,
        child: CompositedTransformFollower(
          link: _composerLink,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(0, -4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _MentionCandidateBar(
              candidates: _mentionCandidates,
              onSelect: _applyMention,
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_mentionOverlay!);
  }

  bool get _hasReadyAttachment => _attachments.any((a) => a.uploadId != null);
  bool get _hasUploading => _attachments.any((a) => a.uploading);

  bool get _canSendNow =>
      // 编辑态不允许带新附件(网页版同语义:编辑只改文本)
      widget.editing != null
      ? widget.canSend
      : (widget.canSend || _hasReadyAttachment) && !_hasUploading;

  // ========== 附件 ==========

  Future<void> _pickFromCamera() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 4096,
      maxHeight: 4096,
    );
    if (picked != null) _addAndUpload(picked.path, isImage: true);
  }

  Future<void> _pickFromGallery() async {
    final picked = await _imagePicker.pickMultiImage(
      maxWidth: 4096,
      maxHeight: 4096,
    );
    for (final file in picked) {
      _addAndUpload(file.path, isImage: true);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    for (final file in result.files) {
      final path = file.path;
      if (path == null) continue;
      final ext = file.extension?.toLowerCase() ?? '';
      _addAndUpload(
        path,
        isImage: const {
          'jpg',
          'jpeg',
          'png',
          'gif',
          'webp',
          'avif',
        }.contains(ext),
      );
    }
  }

  void _addAndUpload(String path, {required bool isImage}) {
    final attachment = _PendingAttachment(
      filePath: path,
      fileName: path.split(Platform.pathSeparator).last,
      isImage: isImage,
    );
    setState(() => _attachments.add(attachment));
    _upload(attachment);
  }

  Future<void> _upload(_PendingAttachment attachment) async {
    try {
      final service = ref.read(discourseServiceProvider);
      final result = await service.uploadFile(attachment.filePath);
      if (!mounted) return;
      setState(() {
        attachment.uploadId = result.id;
        attachment.failed = result.id == null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => attachment.failed = true);
      ToastService.showError(e.toString());
    }
  }

  void _handleSend() {
    if (!_canSendNow) return;
    final uploadIds = [
      for (final a in _attachments)
        if (a.uploadId != null) a.uploadId!,
    ];
    widget.onSend(uploadIds);
    setState(_attachments.clear);
  }

  // ========== @提及 ==========

  void _onTextChanged() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _dismissMention();
      return;
    }
    // 光标前找 @词头:@ 前必须是行首或空白,词身为 [\w.-]*
    final beforeCursor = text.substring(0, selection.baseOffset);
    final match = RegExp(r'(^|\s)@([\w.\-]*)$').firstMatch(beforeCursor);
    if (match == null) {
      _dismissMention();
      return;
    }
    final term = match.group(2)!;
    final atStart = match.start + match.group(1)!.length;
    _mentionRange = (atStart, selection.baseOffset);
    _mentionDebounce?.cancel();
    _mentionDebounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final service = ref.read(discourseServiceProvider);
        final result = await service.searchUsers(
          term: term,
          includeGroups: false,
          limit: 6,
        );
        if (!mounted || _mentionRange == null) return;
        setState(() => _mentionCandidates = result.users);
        _syncMentionOverlay();
      } catch (_) {
        // 静默:候选条缺席不影响输入
      }
    });
  }

  void _dismissMention() {
    _mentionDebounce?.cancel();
    if (_mentionRange != null || _mentionCandidates.isNotEmpty) {
      setState(() {
        _mentionRange = null;
        _mentionCandidates = [];
      });
    }
    _removeMentionOverlay();
  }

  void _applyMention(MentionUser user) {
    final range = _mentionRange;
    if (range == null) return;
    final text = widget.controller.text;
    final replaced =
        '${text.substring(0, range.$1)}@${user.username} '
        '${text.substring(range.$2)}';
    final cursor = range.$1 + user.username.length + 2;
    widget.controller.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _dismissMention();
  }

  // ========== UI ==========

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final editing = widget.editing;
    final replyingTo = widget.replyingTo;
    final contextMessage = editing ?? replyingTo;

    // 悬浮卡:四周圆角 + 外边距 + 描边投影;移动端底部安全区/键盘
    // 占位交给下方 ChatBottomPanelContainer,卡本身只留 8 间距
    final composerCard = CompositedTransformTarget(
      link: _composerLink,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          8,
          0,
          8,
          PlatformUtils.isDesktop ? 8 + bottomPadding : 8,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 待发附件预览行
                if (_attachments.isNotEmpty) ...[
                  SizedBox(
                    height: 64,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _attachments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (context, index) => _PendingAttachmentTile(
                        attachment: _attachments[index],
                        onRemove: () =>
                            setState(() => _attachments.removeAt(index)),
                        onRetry: () {
                          setState(() => _attachments[index].failed = false);
                          _upload(_attachments[index]);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                // 编辑/回复上下文条
                if (contextMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            editing != null
                                ? Symbols.edit_rounded
                                : Symbols.reply_rounded,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  editing != null
                                      ? context.l10n.chat_editingBanner
                                      : context.l10n.chat_replyingTo(
                                          replyingTo!.user?.username ?? '',
                                        ),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                EmojiText(
                                  chatPreviewText(
                                    context,
                                    contextMessage.excerpt?.isNotEmpty == true
                                        ? contextMessage.excerpt!
                                        : contextMessage.message,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Symbols.close_rounded, size: 18),
                            visualDensity: VisualDensity.compact,
                            onPressed: widget.onCancelContext,
                          ),
                        ],
                      ),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 附件/工具菜单(编辑态隐藏)
                    if (editing == null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 1, right: 2),
                        child: Builder(
                          builder: (buttonContext) => IconButton(
                            onPressed: () =>
                                _showAttachmentMenu(buttonContext),
                            icon: const Icon(Symbols.add_rounded, size: 22),
                            style: IconButton.styleFrom(
                              minimumSize: const Size(36, 36),
                              padding: EdgeInsets.zero,
                            ),
                            color: theme.colorScheme.onSurfaceVariant,
                            tooltip: context.l10n.chat_attach,
                          ),
                        ),
                      ),
                    // 表情按钮(桌面锚定弹层,移动底部面板)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1, right: 4),
                      child: _wrapEmojiAnchor(
                        IconButton(
                          onPressed: _pickEmoji,
                          icon: Icon(
                            Symbols.sentiment_satisfied_rounded,
                            size: 22,
                            fill: _emojiPopover?.isOpen == true ? 1 : 0,
                          ),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(36, 36),
                            padding: EdgeInsets.zero,
                          ),
                          color: _emojiPopover?.isOpen == true
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          tooltip: context.l10n.chat_emoji,
                        ),
                      ),
                    ),
                    Expanded(child: _buildField(context, theme)),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: IconButton.filled(
                        onPressed: _canSendNow ? _handleSend : null,
                        icon: _hasUploading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: LoadingSpinner(),
                              )
                            : Icon(
                                editing != null
                                    ? Symbols.check_rounded
                                    : Symbols.send_rounded,
                                size: 20,
                              ),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(36, 36),
                          padding: EdgeInsets.zero,
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          disabledBackgroundColor: theme.colorScheme.onSurface
                              .withValues(alpha: 0.1),
                        ),
                        tooltip: context.l10n.chat_send,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (PlatformUtils.isDesktop) return composerCard;
    // 移动端:悬浮卡下挂键盘位面板容器(键盘占位/表情面板等高互换,
    // 编辑器同款机制;Scaffold 已关 resizeToAvoidBottomInset)
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        composerCard,
        ChatBottomPanelContainer<_ComposerPanel>(
          controller: _panelController,
          inputFocusNode: widget.focusNode,
          otherPanelWidget: (type) => type == _ComposerPanel.emoji
              ? _buildDockedEmojiPanel()
              : const SizedBox.shrink(),
          onPanelTypeChange: (panelType, data) {
            setState(() {
              _currentPanel = switch (panelType) {
                ChatBottomPanelType.none => _ComposerPanel.none,
                ChatBottomPanelType.keyboard => _ComposerPanel.keyboard,
                ChatBottomPanelType.other => data ?? _ComposerPanel.none,
              };
            });
          },
        ),
      ],
    );
  }

  /// 附件/工具菜单:双模式(桌面=+按钮锚点弹出,移动=底部弹层),
  /// 动作声明一份,showAdaptiveMenu 按端分流
  Future<void> _showAttachmentMenu(BuildContext buttonContext) async {
    final l10n = context.l10n;
    final action = await showAdaptiveMenu<String>(
      context: context,
      anchorContext: buttonContext,
      items: [
        if (!PlatformUtils.isDesktop)
          AdaptiveMenuItem(
            value: 'camera',
            icon: Symbols.photo_camera_rounded,
            label: l10n.chat_attachCamera,
          ),
        AdaptiveMenuItem(
          value: 'gallery',
          icon: Symbols.photo_library_rounded,
          label: l10n.chat_attachGallery,
        ),
        AdaptiveMenuItem(
          value: 'file',
          icon: Symbols.attach_file_rounded,
          label: l10n.chat_attachFile,
        ),
        const AdaptiveMenuDivider(),
        AdaptiveMenuItem(
          value: 'template',
          icon: Symbols.description_rounded,
          label: l10n.chat_insertTemplate,
        ),
        AdaptiveMenuItem(
          value: 'datetime',
          icon: Symbols.calendar_clock_rounded,
          label: l10n.chat_insertDateTime,
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'camera':
        await _pickFromCamera();
      case 'gallery':
        await _pickFromGallery();
      case 'file':
        await _pickFile();
      case 'template':
        await _insertTemplate();
      case 'datetime':
        await _insertDateTime();
    }
  }

  /// 光标处插入文本(选区替换,光标落在插入尾)
  void _insertAtCursor(String text) {
    final controller = widget.controller;
    final value = controller.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    final newText = value.text.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    widget.focusNode.requestFocus();
  }

  Widget _wrapEmojiAnchor(Widget button) {
    final popover = _emojiPopover;
    if (popover == null) return button;
    return EmojiPopoverAnchor(controller: popover, child: button);
  }

  /// 表情选择:插入 :shortcode:(输入框内联渲染成图,发送后服务端 cook)
  /// 桌面=按钮上方锚定弹层;移动=键盘位面板互换(编辑器同款)
  Future<void> _pickEmoji() async {
    final popover = _emojiPopover;
    if (popover != null) {
      popover.toggle(context, panel: _ensureEmojiPanel());
      return;
    }
    if (_currentPanel == _ComposerPanel.emoji) {
      // 再点=切回键盘
      _panelController.updatePanelType(ChatBottomPanelType.keyboard);
      widget.focusNode.requestFocus();
    } else {
      _panelController.updatePanelType(
        ChatBottomPanelType.other,
        data: _ComposerPanel.emoji,
        forceHandleFocus: ChatBottomHandleFocus.requestFocus,
      );
    }
  }

  /// 键盘位表情面板高度:键盘高已知用键盘高,否则 300 兜底
  double get _dockedPanelHeight {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final keyboardHeight = _panelController.keyboardHeight;
    return keyboardHeight > 0
        ? math.max(keyboardHeight, safeBottom)
        : math.max(300.0, safeBottom);
  }

  Widget _buildDockedEmojiPanel() {
    return TextFieldTapRegion(
      child: SizedBox(
        height: _dockedPanelHeight,
        child: EmojiStickerPanel(
          onEmojiSelected: (emoji) => _insertAtCursor(':${emoji.name}:'),
          // 表情包 TG 式直发:不进输入框,面板保持打开可连发
          onStickerSelected: widget.onSendSticker,
          onBackspace: () =>
              deleteBackwardWithEmojiShortcodes(widget.controller),
        ),
      ),
    );
  }

  /// 插入模板(复用站点 templates/我的模板)
  Future<void> _insertTemplate() async {
    List<Template> templates;
    try {
      templates = await ref.read(discourseServiceProvider).getTemplates();
    } catch (e) {
      ToastService.showError(e.toString());
      return;
    }
    if (!mounted) return;
    if (templates.isEmpty) {
      ToastService.showInfo(context.l10n.chat_noTemplates);
      return;
    }
    final picked = await AppBottomSheet.showDraggable<Template>(
      context: context,
      title: context.l10n.chat_insertTemplate,
      initialSize: 0.5,
      bodyBuilder: (sheetContext, scrollController) => ListView.builder(
        controller: scrollController,
        itemCount: templates.length,
        itemBuilder: (itemContext, index) {
          final template = templates[index];
          return ListTile(
            title: Text(template.title),
            subtitle: Text(
              template.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.pop(itemContext, template),
          );
        },
      ),
    );
    if (picked != null && mounted) _insertAtCursor(picked.content);
  }

  /// 插入日期/时间:选日期(可选时间),生成 Discourse [date] 语法,
  /// 渲染端(含气泡)会按读者时区本地化显示
  Future<void> _insertDateTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (!mounted) return;
    final dateStr =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final buffer = StringBuffer('[date=')..write(dateStr);
    if (time != null) {
      buffer.write(
        ' time=${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:00',
      );
    }
    buffer.write(' timezone="${TimeUtils.localTimezone}"]');
    _insertAtCursor(buffer.toString());
  }

  static String? _mentionAvatarUrl(MentionUser user) {
    final template = user.avatarTemplate;
    if (template == null || template.isEmpty) return null;
    return UrlHelper.resolveUrlWithCdn(template.replaceAll('{size}', '96'));
  }

  InputDecoration _fieldDecoration(BuildContext context, ThemeData theme) {
    return InputDecoration(
      hintText: context.l10n.chat_inputHint,
      hintStyle: TextStyle(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      isDense: true,
      filled: true,
      fillColor: theme.colorScheme.surface,
      hoverColor: Colors.transparent,
    );
  }

  Widget _buildField(BuildContext context, ThemeData theme) {
    final field = TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: PlatformUtils.isDesktop,
      minLines: 1,
      maxLines: 5,
      textInputAction: TextInputAction.newline,
      // 退格命中 :shortcode: 局部时扩删整个表情(boost 输入条同款),
      // 否则删一下只掉个冒号,表情"炸回"文本
      inputFormatters: const [EmojiShortcodeDeleteFormatter()],
      decoration: _fieldDecoration(context, theme),
    );
    if (!PlatformUtils.isDesktop) return field;
    // 桌面:Enter 发送 / Shift+Enter 换行;候选条打开时 Enter 选第一个
    return Shortcuts(
      shortcuts: {LogicalKeySet(LogicalKeyboardKey.enter): const _SendIntent()},
      child: Actions(
        actions: {
          _SendIntent: CallbackAction<_SendIntent>(
            onInvoke: (_) {
              if (_mentionCandidates.isNotEmpty && _mentionRange != null) {
                _applyMention(_mentionCandidates.first);
              } else {
                _handleSend();
              }
              return null;
            },
          ),
        },
        child: field,
      ),
    );
  }
}

/// 待发附件缩略卡:图片显示缩略图,文件显示图标;上传中蒙层转圈,
/// 失败蒙层可点重试;右上角删除
class _PendingAttachmentTile extends StatelessWidget {
  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  const _PendingAttachmentTile({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Container(
          width: 64,
          height: 64,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: attachment.isImage
              ? Image.file(
                  File(attachment.filePath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Icon(Symbols.broken_image_rounded),
                )
              : Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Symbols.description_rounded, size: 22),
                      const SizedBox(height: 2),
                      Text(
                        attachment.fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 8,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        // 上传中/失败蒙层
        if (attachment.uploading || attachment.failed)
          Positioned.fill(
            child: Material(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
              child: attachment.failed
                  ? InkWell(
                      onTap: onRetry,
                      borderRadius: BorderRadius.circular(12),
                      child: const Icon(
                        Symbols.refresh_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    )
                  : const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: LoadingSpinner(),
                      ),
                    ),
            ),
          ),
        // 删除按钮
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Symbols.close_rounded,
                size: 12,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

/// 纯 emoji 消息判定:cooked 仅由 emoji 图(+ p 标签/空白)组成且 ≤6 个,
/// 返回解析后的 emoji 图 URL 列表用于 jumbo 大图渲染;否则 null。
List<String>? jumboEmojiUrls(String cooked) {
  final imgRe = RegExp(r'<img\b[^>]*>', caseSensitive: false);
  final imgs = imgRe.allMatches(cooked).map((m) => m.group(0)!).toList();
  if (imgs.isEmpty || imgs.length > 6) return null;
  // 去掉所有 img + p 标签 + 空白/&nbsp; 后若还有内容,则非纯 emoji
  var rest = cooked.replaceAll(imgRe, '');
  rest = rest.replaceAll(RegExp(r'</?p>', caseSensitive: false), '');
  rest = rest.replaceAll(RegExp(r'(\s|&nbsp;)+'), '');
  if (rest.isNotEmpty) return null;
  final srcRe = RegExp('src="([^"]+)"', caseSensitive: false);
  final urls = <String>[];
  for (final img in imgs) {
    if (!img.toLowerCase().contains('emoji')) return null; // 含非 emoji 图
    final src = srcRe.firstMatch(img)?.group(1);
    if (src == null) return null;
    urls.add(UrlHelper.resolveUrlWithCdn(src));
  }
  return urls;
}

/// 多选工具栏(对齐官方 selection-manager:引用/复制/删除/由 AppBar 取消)
class _SelectionToolbar extends StatelessWidget {
  final int count;
  final bool canDelete;
  final VoidCallback onQuote;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  const _SelectionToolbar({
    required this.count,
    required this.canDelete,
    required this.onQuote,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final enabled = count > 0;
    return Container(
      padding: EdgeInsets.only(top: 6, bottom: 6 + bottomPadding),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _SelectionAction(
            icon: Symbols.format_quote_rounded,
            label: context.l10n.chat_selectionQuote,
            enabled: enabled,
            onTap: onQuote,
          ),
          _SelectionAction(
            icon: Symbols.content_copy_rounded,
            label: context.l10n.chat_menuCopy,
            enabled: enabled,
            onTap: onCopy,
          ),
          _SelectionAction(
            icon: Symbols.delete_rounded,
            label: context.l10n.chat_menuDelete,
            enabled: enabled && canDelete,
            destructive: true,
            onTap: onDelete,
          ),
        ],
      ),
    );
  }
}

class _SelectionAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool destructive;
  final VoidCallback onTap;

  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.enabled,
    this.destructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = !enabled
        ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
        : destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏"正在输入"副标题(TG 式):状态文字 + 三点循环动画
class _TypingSubtitle extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _TypingSubtitle({required this.text, required this.style});

  @override
  State<_TypingSubtitle> createState() => _TypingSubtitleState();
}

class _TypingSubtitleState extends State<_TypingSubtitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 文案自带尾部省略号(l10n),动画点另画,先剥掉静态省略号
    final base = widget.text.replaceFirst(RegExp(r'[….]+\s*$'), '');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            base,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          ),
        ),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final phase = (_controller.value * 3).floor();
            return SizedBox(
              // 定宽防止点数变化时文字横跳
              width: (widget.style.fontSize ?? 11) * 1.4,
              child: Text('.' * (phase + 1), style: widget.style),
            );
          },
        ),
      ],
    );
  }
}

/// 置顶横幅(TG 口径):列表顶部悬浮一条,竖线记号+置顶人/摘要,
/// 点击跳到消息(多条时轮换);pin/unpin 广播实时增删
class _PinnedBanner extends StatelessWidget {
  final List<ChatMessage> pins;
  final int cursor;
  final VoidCallback onTap;

  const _PinnedBanner({
    required this.pins,
    required this.cursor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pin = pins[cursor];
    return Material(
      color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.97),
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              // 竖线记号:多条时分段(TG 同款小节拍)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < pins.length && i < 4; i++)
                    Container(
                      width: 2.5,
                      height: pins.length > 1 ? 10.0 : 26.0,
                      margin: EdgeInsets.only(top: i == 0 ? 0 : 2),
                      decoration: BoxDecoration(
                        color: i == cursor
                            ? theme.colorScheme.primary
                            : theme.colorScheme.primary.withValues(
                                alpha: 0.35,
                              ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pins.length > 1
                          ? context.l10n.chat_pinnedCount(pins.length)
                          : context.l10n.chat_pinnedBanner,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    EmojiText(
                      chatPreviewText(
                        context,
                        pin.excerpt?.isNotEmpty == true
                            ? pin.excerpt!
                            : pin.message,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Symbols.keep_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// @提及候选条:悬浮卡(Overlay 挂载,不占输入区布局)
class _MentionCandidateBar extends StatelessWidget {
  final List<MentionUser> candidates;
  final void Function(MentionUser user) onSelect;

  const _MentionCandidateBar({
    required this.candidates,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 24,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final user in candidates)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: InkWell(
                    onTap: () => onSelect(user),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SmartAvatar(
                            imageUrl: _ChatComposerState._mentionAvatarUrl(
                              user,
                            ),
                            radius: 11,
                            fallbackText: user.username,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            user.username,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 消息附件区:图片=圆角缩略图(点开 viewer,同消息多图组画廊);
/// 其他文件=图标+文件名卡
class _MessageUploads extends StatelessWidget {
  final List<ChatUpload> uploads;
  final bool interactive;
  final String heroNamespace;

  const _MessageUploads({
    required this.uploads,
    required this.interactive,
    required this.heroNamespace,
  });

  static const _imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif'};

  bool _isImage(ChatUpload u) =>
      _imageExts.contains((u.extension ?? '').toLowerCase());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = uploads.where(_isImage).toList();
    final files = uploads.where((u) => !_isImage(u)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (images.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < images.length; i++)
                _buildImage(context, images, i),
            ],
          ),
        for (final file in files)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.description_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      file.originalFilename ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildImage(BuildContext context, List<ChatUpload> images, int i) {
    final upload = images[i];
    final url = upload.resolvedUrl;
    if (url == null) return const SizedBox.shrink();
    // 多图缩小档;单图按上限约束,保持宽高比
    final many = images.length > 1;
    final maxW = many ? 132.0 : 240.0;
    final ratio = (upload.width ?? 0) > 0 && (upload.height ?? 0) > 0
        ? upload.width! / upload.height!
        : 1.0;
    final w = maxW;
    final h = (w / ratio).clamp(72.0, 320.0);
    final heroTag = '${heroNamespace}_$i';

    final image = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image(
        image: discourseImageProvider(url),
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: w,
          height: 72,
          alignment: Alignment.center,
          color: Theme.of(context).colorScheme.surface,
          child: const Icon(Symbols.broken_image_rounded),
        ),
      ),
    );
    if (!interactive) return image;
    return GestureDetector(
      onTap: () => ImageViewerPage.open(
        context,
        url,
        heroTag: heroTag,
        galleryImages: [for (final u in images) u.resolvedUrl ?? ''],
        heroTags: [
          for (var j = 0; j < images.length; j++) '${heroNamespace}_$j',
        ],
        initialIndex: i,
        filenames: [for (final u in images) u.originalFilename],
      ),
      child: Hero(tag: heroTag, child: image),
    );
  }
}

/// 单条消息:规格对齐 AiChatMessageItem
/// (自己 primaryContainer 右对齐,对方 surfaceContainerLow 左对齐带头像;
///  非对称圆角 16/4;maxWidth 78%)
///
/// 交互:移动长按 = TG 式 overlay(气泡副本+反应条+菜单卡);
/// 桌面 = hover 工具条(回复/表情/更多)+ 右键锚点菜单。
class _MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isSelf;
  final bool clustered;

  /// 列表滚动中标志:滚动时抑制 hover 工具条(防划过反复闪现)
  final ValueListenable<bool> scrolling;

  /// 定位跳转落点的短时高亮
  final bool highlighted;

  /// 请求打开菜单:移动传 (bubbleRect, bubbleBuilder),桌面传 anchorPosition
  final void Function(
    Rect? bubbleRect,
    Widget Function(BuildContext)? bubbleBuilder,
    Offset? anchorPosition,
  )
  onMenuRequested;
  final VoidCallback onQuickReply;
  final void Function(String emoji) onQuickReact;
  final void Function(String emoji)? onReactionTap;

  /// 非空时气泡下显示"N 条回复"入口(仅主流的串首消息)
  final VoidCallback? onOpenThread;

  /// 引用条点击(跳到被回复的原消息)
  final VoidCallback? onReplyRefTap;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  /// 收藏切换(hover 工具条书签钮)
  final VoidCallback? onToggleBookmark;

  /// 长按头像菜单"@用户"(插入输入框)
  final void Function(String username)? onMentionUser;

  /// 删除折叠(官方口径):连续删除段只有段尾渲染,显示"N 条已删除·查看"
  /// 入口;count=段长,onExpand 展开整段原文
  final int deletedRunCount;
  final bool deletedExpanded;
  final VoidCallback? onExpandDeleted;

  const _MessageBubble({
    required this.message,
    required this.isSelf,
    required this.clustered,
    required this.scrolling,
    this.highlighted = false,
    required this.onMenuRequested,
    required this.onQuickReply,
    required this.onQuickReact,
    this.onReactionTap,
    this.onOpenThread,
    this.onReplyRefTap,
    this.onRetry,
    this.onDiscard,
    this.onToggleBookmark,
    this.onMentionUser,
    this.deletedRunCount = 1,
    this.deletedExpanded = false,
    this.onExpandDeleted,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  final GlobalKey _bubbleKey = GlobalKey();

  /// 整行的 key:hover 工具条钉在行右上角(Discord 口径,与内容宽度
  /// 无关;量 _bubbleKey 会随 shrinkWrap 内容宽漂移)
  final GlobalKey _rowKey = GlobalKey();

  /// 头像锚(用户卡片定位:锚整行会让浮层飘到行中间压消息流)
  final GlobalKey _avatarKey = GlobalKey();
  final LayerLink _avatarLink = LayerLink();

  /// 桌面 hover 工具条走 Overlay(全局最顶层):列表项内 Stack 溢出
  /// 绘制会被相邻项盖住(reverse 列表上邻项后绘制,z 序在列表内无解)。
  ///
  /// **全局单例**:entry/owner 是类级静态——每行各持一条时,快速划过
  /// 多行会在旧行 120ms 宽限内插入新行的条,屏上并存一堆(用户截图)。
  /// 任何行要显示前先无条件撤掉现存那条,全局同时最多一条。
  static OverlayEntry? _sharedBarEntry;
  static _MessageBubbleState? _sharedBarOwner;
  Timer? _hoverBarHideTimer;
  bool _pointerInBar = false;
  bool _pointerInRow = false;

  ChatMessage get message => widget.message;
  bool get isSelf => widget.isSelf;
  bool get clustered => widget.clustered;

  /// 工具条外置快捷表情(Discord 式:最近使用前几个一击回应)
  List<String> _quickEmojis = const ['heart', '+1', 'laughing'];

  @override
  void initState() {
    super.initState();
    if (PlatformUtils.isDesktop) {
      widget.scrolling.addListener(_onScrollingChanged);
      unawaited(
        loadQuickReactions(limit: 3).then((list) {
          if (mounted && list.isNotEmpty) _quickEmojis = list;
        }),
      );
    }
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      widget.scrolling.removeListener(_onScrollingChanged);
    }
    _hoverBarHideTimer?.cancel();
    _removeHoverBar();
    super.dispose();
  }

  @override
  void didUpdateWidget(_MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工具条是 OverlayEntry,不随行 rebuild;本行持有时数据变了手动重建
    // (收藏图标翻转/删除态切换等)。
    // 必须推迟到帧末:didUpdateWidget 处于 build 阶段,此刻 markNeedsBuild
    // (= 对 Overlay setState)非法,会炸整棵树(书签一点就崩的事故)
    if (_sharedBarOwner == this && widget.message != oldWidget.message) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sharedBarOwner == this) {
          _sharedBarEntry?.markNeedsBuild();
        }
      });
    }
  }

  void _onScrollingChanged() {
    // 滚动中撤条(消息划过光标时 enter/exit 连环触发的闪现由此根治)
    if (widget.scrolling.value) {
      _removeHoverBar();
    } else if (_pointerInRow && mounted) {
      // 滚动停止且指针仍停在本行:补显(滚动中 enter 被拦掉后不会再
      // 触发,不补的话要移出去再移回来才出条)
      _showHoverBar();
    }
  }

  void _removeHoverBar() {
    // 只有 owner 才能撤(避免误撤别行刚插入的条)
    if (_sharedBarOwner == this) {
      _sharedBarEntry?.remove();
      _sharedBarEntry = null;
      _sharedBarOwner = null;
    }
    _pointerInBar = false;
  }

  /// 无条件撤当前屏上的条(不管归谁)——新行显示前调用
  static void _removeSharedBar() {
    _sharedBarEntry?.remove();
    _sharedBarEntry = null;
    _sharedBarOwner?._pointerInBar = false;
    _sharedBarOwner = null;
  }

  void _scheduleHideBar() {
    // 行 → 工具条之间有间隙,给 120ms 宽限迁移,双双离开才撤
    _hoverBarHideTimer?.cancel();
    _hoverBarHideTimer = Timer(const Duration(milliseconds: 120), () {
      if (!_pointerInRow && !_pointerInBar) _removeHoverBar();
    });
  }

  void _showHoverBar() {
    if (widget.scrolling.value) return;
    // 删除消息:折叠态不出条;展开态出受限条(官方=收藏+更多,无快捷表情/回复)
    if (message.isStaged) return;
    if (message.isDeleted && !widget.deletedExpanded) return;
    if (_sharedBarOwner == this && _sharedBarEntry != null) return;
    // 接管:先撤别行(或残留)的条,保证全局唯一
    _removeSharedBar();
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final overlay = Overlay.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;

    final entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        // Discord 口径:钉整行右上角,半高悬出行顶;Overlay 层永远压不住
        top: rect.top - 14,
        right: screenWidth - rect.right + 12,
        child: MouseRegion(
          onEnter: (_) => _pointerInBar = true,
          onExit: (_) {
            _pointerInBar = false;
            _scheduleHideBar();
          },
          child: _HoverActionBar(
            // 删除消息(展开态):受限条——无快捷表情/回应/回复,
            // 保留收藏+更多(官方 canInteractWithMessage=!deletedAt)
            interactive: !message.isDeleted,
            quickEmojis: _quickEmojis,
            bookmarked: message.bookmark != null,
            onQuickEmoji: (emoji) {
              _removeHoverBar();
              widget.onQuickReact(emoji);
            },
            onReply: () {
              _removeHoverBar();
              widget.onQuickReply();
            },
            onPickReaction: () async {
              _removeHoverBar();
              final emoji = await showChatEmojiPicker(context, desktop: true);
              if (emoji != null) widget.onQuickReact(emoji);
            },
            // 收藏后不撤条:图标原地翻转(didUpdateWidget markNeedsBuild)
            onBookmark: () => widget.onToggleBookmark?.call(),
            onMore: (buttonContext) {
              final buttonBox =
                  buttonContext.findRenderObject() as RenderBox?;
              final anchor = buttonBox
                  ?.localToGlobal(buttonBox.size.bottomLeft(Offset.zero));
              _removeHoverBar();
              if (anchor != null) _openDesktopMenuAt(anchor);
            },
          ),
        ),
      ),
    );
    _sharedBarEntry = entry;
    _sharedBarOwner = this;
    overlay.insert(entry);
  }

  /// 点头像/名字:用户卡片(锚定头像,桌面浮层贴头像旁+跟随滚动,
  /// 移动停靠卡;话题页同款口径)
  void _openUserCard() {
    final user = message.user;
    if (user == null) return;
    final box =
        (_avatarKey.currentContext ?? _rowKey.currentContext)
                ?.findRenderObject()
            as RenderBox?;
    if (box == null || !box.hasSize) return;
    final anchorRect = box.localToGlobal(Offset.zero) & box.size;
    showUserCard(
      context: context,
      anchorRect: anchorRect,
      layerLink: _avatarKey.currentContext != null ? _avatarLink : null,
      username: user.username,
      avatarFallbackUrl: user.getAvatarUrl(size: 144),
      nameFallback: user.name,
    );
  }

  /// 移动端长按 reaction chip:弹名单(桌面走 chip Tooltip)
  void _showReactionUsers(ChatMessageReaction reaction) {
    if (PlatformUtils.isDesktop) return;
    HapticFeedback.selectionClick();
    final url = EmojiHandler().getEmojiUrl(reaction.emoji);
    unawaited(
      AppBottomSheet.show<void>(
        context: context,
        showCloseButton: false,
        contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        titleWidget: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (url.isNotEmpty)
              Image(image: emojiImageProvider(url), width: 22, height: 22)
            else
              Text(reaction.emoji),
            const SizedBox(width: 8),
            Text(':${reaction.emoji}: · ${reaction.count}'),
          ],
        ),
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final user in reaction.users)
              ListTile(
                dense: true,
                leading: SmartAvatar(
                  imageUrl: user.getAvatarUrl(size: 64),
                  radius: 14,
                  fallbackText: user.username,
                ),
                title: Text(user.username),
              ),
          ],
        ),
      ),
    );
  }

  void _openMobileMenu() {
    final renderBox =
        _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final rect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
    widget.onMenuRequested(
      rect,
      (ctx) => _buildBubbleCore(ctx, interactive: false),
      null,
    );
  }

  void _openDesktopMenuAt(Offset globalPosition) {
    widget.onMenuRequested(null, null, globalPosition);
  }

  /// 行内 hover(移动无效):簇内行左沟槽时间的显隐
  bool _rowHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Discord 式扁平行:不分左右,自己/别人同为左对齐,靠名字配色区分。
    // 结构 = [64 左沟槽(簇首头像/簇内 hover 时间)][内容列(簇首头行+正文)]
    // 整行 hover 染色;高亮/hover 底色画在全宽行上。
    var rowColor = widget.highlighted
        ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35)
        : _rowHovered && PlatformUtils.isDesktop
        ? theme.colorScheme.onSurface.withValues(alpha: 0.04)
        : Colors.transparent;

    if (message.isDeleted && !widget.deletedExpanded) {
      // 折叠态(官方 deletedAndCollapsed):整段一行入口,点击展开原文
      final count = widget.deletedRunCount;
      return _wrapRow(
        theme,
        rowColor,
        gutter: const SizedBox.shrink(),
        body: Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            onTap: widget.onExpandDeleted,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                count > 1
                    ? context.l10n.chat_deletedMany(count)
                    : context.l10n.chat_deletedOne,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error.withValues(alpha: 0.85),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        ),
      );
    }
    // 展开的删除消息:正常渲染原文,危险色淡底标识(官方 -deleted 底色)
    if (message.isDeleted) {
      rowColor = Color.alphaBlend(
        theme.colorScheme.error.withValues(alpha: 0.06),
        rowColor,
      );
    }

    // 左沟槽:簇首=头像;簇内=hover 时淡入的小时间(Discord 同款)
    final Widget gutter;
    if (!clustered) {
      final avatar = CompositedTransformTarget(
        link: _avatarLink,
        child: KeyedSubtree(
          key: _avatarKey,
          child: SmartAvatar(
            imageUrl: message.user?.getAvatarUrl(size: 80),
            radius: 18,
            fallbackText: message.user?.username,
          ),
        ),
      );
      // 点头像=用户卡片(话题页口径,资料页从卡片进);长按=径向菜单
      gutter = message.user == null
          ? avatar
          : RadialLongPressMenu(
              onTap: _openUserCard,
              itemsBuilder: () => buildAvatarMenuItems(
                context,
                username: message.user!.username,
                onMentionUser: widget.onMentionUser,
              ),
              pressAreaIndicatorBuilder: (ctx, rect, opacity) => Opacity(
                opacity: opacity,
                child: SmartAvatar(
                  imageUrl: message.user?.getAvatarUrl(size: 80),
                  radius: rect.shortestSide / 2,
                  fallbackText: message.user?.username,
                  border: Border.all(
                    color: Theme.of(ctx).colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
              child: avatar,
            );
    } else {
      gutter = AnimatedOpacity(
        opacity: _rowHovered ? 1 : 0,
        duration: const Duration(milliseconds: 100),
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            TimeUtils.formatClockTime(message.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      );
    }

    // 簇首头行:名字(自己主色/他人 secondary 染色) + 小时间
    final Widget? header = clustered
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: GestureDetector(
                    onTap: message.user == null ? null : _openUserCard,
                    child: Text(
                      message.user?.name?.isNotEmpty == true
                          ? message.user!.name!
                          : (message.user?.username ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isSelf
                            ? theme.colorScheme.primary
                            : theme.colorScheme.secondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  TimeUtils.formatClockTime(message.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                if (message.edited) ...[
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.chat_edited,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
                if (message.isDeleted) ...[
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.chat_deletedTag,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error.withValues(alpha: 0.8),
                    ),
                  ),
                ],
                if (message.isStaged) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          );

    // 回复引用:Discord 式引用行(头行上方,细字 + 竖线记号)
    final Widget? replyRef = message.inReplyTo == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: InkWell(
              onTap: widget.onReplyRefTap,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.reply_rounded,
                    size: 13,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    message.inReplyTo!.user?.username ?? '',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: EmojiText(
                      chatPreviewText(
                        context,
                        message.inReplyTo!.excerpt ?? '',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );

    // 内容主体(正文全宽,无底色;右键/长按手势在整行 _wrapRow 上)
    final body = KeyedSubtree(
      key: _bubbleKey,
      child: Opacity(
        opacity: message.isStaged ? 0.6 : 1.0,
        child: _buildBubbleCore(context, interactive: true),
      ),
    );

    // reactions / thread / failed 行
    // hover 行(桌面)时尾部追加"加表情"胶囊(官方同款)
    final Widget? reactionsRow = message.reactions.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final r in message.reactions)
                  _ReactionChip(
                    reaction: r,
                    onTap: widget.onReactionTap == null
                        ? null
                        : () => widget.onReactionTap!(r.emoji),
                    onLongPress: () => _showReactionUsers(r),
                  ),
                if (PlatformUtils.isDesktop && _rowHovered)
                  _AddReactionChip(
                    onTap: () async {
                      final emoji = await showChatEmojiPicker(
                        context,
                        desktop: true,
                      );
                      if (emoji != null) widget.onQuickReact(emoji);
                    },
                  ),
              ],
            ),
          );

    final Widget? threadRow =
        widget.onOpenThread != null && message.thread != null
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _ThreadEntryCard(
              thread: message.thread!,
              onTap: widget.onOpenThread!,
            ),
          )
        : null;

    final Widget? failedRow = message.sendState == ChatMessageSendState.failed
        ? _buildFailedRow(theme)
        : null;

    return _wrapRow(
      theme,
      rowColor,
      gutter: gutter,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?replyRef,
          ?header,
          body,
          ?reactionsRow,
          ?threadRow,
          ?failedRow,
        ],
      ),
    );
  }

  /// 行外壳:全宽底色 + [56 沟槽][内容] 两列;桌面挂 hover
  Widget _wrapRow(
    ThemeData theme,
    Color rowColor, {
    required Widget gutter,
    required Widget body,
  }) {
    final row = GestureDetector(
      // 热区=整行(含空白区),Discord 口径;behavior 透明让内层链接/
      // 图片等交互照常命中
      onLongPress: PlatformUtils.isDesktop ? null : _openMobileMenu,
      onSecondaryTapDown: PlatformUtils.isDesktop
          ? (d) => _openDesktopMenuAt(d.globalPosition)
          : null,
      behavior: HitTestBehavior.translucent,
      child: AnimatedContainer(
        key: _rowKey,
        duration: const Duration(milliseconds: 300),
        color: rowColor,
        padding: EdgeInsets.only(
          left: 12,
          right: 16,
          top: clustered ? 2 : 10,
          bottom: 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 44, child: Center(child: gutter)),
            const SizedBox(width: 10),
            Expanded(child: body),
          ],
        ),
      ),
    );

    if (!PlatformUtils.isDesktop) return row;
    return MouseRegion(
      onEnter: (_) {
        _pointerInRow = true;
        if (!_rowHovered) setState(() => _rowHovered = true);
        _showHoverBar();
      },
      onExit: (_) {
        _pointerInRow = false;
        if (_rowHovered) setState(() => _rowHovered = false);
        _scheduleHideBar();
      },
      child: row,
    );
  }

  /// 消息正文(jumbo emoji / 富文本 + 附件);无底色无内边距(扁平行)。
  /// [interactive]=false 用于长按 overlay 副本(heroTag 换命名空间防撞)
  Widget _buildBubbleCore(BuildContext context, {required bool interactive}) {
    final theme = Theme.of(context);

    // 纯 emoji 消息:jumbo 大图(Discord/网页同款)
    final jumbo = (message.uploads.isEmpty && message.inReplyTo == null)
        ? jumboEmojiUrls(message.cooked)
        : null;
    if (jumbo != null) {
      final size = jumbo.length == 1
          ? 42.0
          : jumbo.length <= 3
          ? 34.0
          : 28.0;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (final url in jumbo)
              Image(image: emojiImageProvider(url), width: size, height: size),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FluxdoRenderCallbacks.generic(
          heroTagNamespace: interactive
              ? 'chat_${message.channelId}_${message.id}'
              : 'chat_overlay_${message.channelId}_${message.id}',
        ).render(
          cookedHtml: message.cooked,
          baseTextStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          // 桌面可划词(鼠标拖选);移动端长按已被 TG 菜单占用,
          // 划词走长按菜单里的"复制"
          selectionEnabled: interactive && PlatformUtils.isDesktop,
          shrinkWrapWidth: true,
          // 裁掉首末块自带外边距(<p> 有、jumbo/附件无 → 行内底部留白
          // 忽有忽无);行距统一由行 padding 控制
          trimTopMargin: true,
          trimBottomMargin: true,
        ),
        // 附件(chat 的 uploads 不进 cooked,单独渲染)
        if (message.uploads.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(
              top: message.cooked.trim().isEmpty ? 0 : 6,
            ),
            child: _MessageUploads(
              uploads: message.uploads,
              interactive: interactive,
              heroNamespace: 'chat_up_${message.channelId}_${message.id}',
            ),
          ),
      ],
    );
  }


  Widget _buildFailedRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.error_rounded, size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 4),
          TextButton(
            onPressed: widget.onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            child: Text(context.l10n.chat_resend),
          ),
          TextButton(
            onPressed: widget.onDiscard,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            child: Text(context.l10n.chat_discard),
          ),
        ],
      ),
    );
  }
}

/// 桌面 hover 工具条(Discord 形态):
/// [快捷表情×3 一击回应][加表情][回复][更多]
class _HoverActionBar extends StatelessWidget {
  /// false=删除消息的受限条:只保留收藏+更多(官方口径)
  final bool interactive;
  final List<String> quickEmojis;
  final bool bookmarked;
  final void Function(String emoji) onQuickEmoji;
  final VoidCallback onReply;
  final VoidCallback onPickReaction;
  final VoidCallback onBookmark;
  final void Function(BuildContext buttonContext) onMore;

  const _HoverActionBar({
    this.interactive = true,
    required this.quickEmojis,
    this.bookmarked = false,
    required this.onQuickEmoji,
    required this.onReply,
    required this.onPickReaction,
    required this.onBookmark,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handler = EmojiHandler();
    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 外置快捷表情:最近使用前 3,一击回应(Discord 同款)
            if (interactive)
            for (final emoji in quickEmojis)
              Tooltip(
                message: ':$emoji:',
                waitDuration: const Duration(milliseconds: 400),
                child: InkWell(
                  onTap: () => onQuickEmoji(emoji),
                  borderRadius: BorderRadius.circular(8),
                  hoverColor: theme.colorScheme.onSurface.withValues(
                    alpha: 0.08,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Builder(
                      builder: (context) {
                        final url = handler.getEmojiUrl(emoji);
                        return url.isEmpty
                            ? Text(
                                emoji,
                                style: const TextStyle(fontSize: 16),
                              )
                            : Image(
                                image: emojiImageProvider(url),
                                width: 20,
                                height: 20,
                              );
                      },
                    ),
                  ),
                ),
              ),
            if (interactive) ...[
              SizedBox(
                height: 20,
                child: VerticalDivider(
                  width: 8,
                  thickness: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              ),
              _HoverBarButton(
                icon: Symbols.add_reaction_rounded,
                tooltip: context.l10n.chat_moreReactions,
                onTap: onPickReaction,
              ),
            ],
            _HoverBarButton(
              icon: bookmarked
                  ? Symbols.bookmark_remove_rounded
                  : Symbols.bookmark_rounded,
              tooltip: bookmarked
                  ? context.l10n.chat_menuRemoveBookmark
                  : context.l10n.chat_menuBookmark,
              onTap: onBookmark,
            ),
            if (interactive)
              _HoverBarButton(
                icon: Symbols.reply_rounded,
                tooltip: context.l10n.chat_menuReply,
                onTap: onReply,
              ),
            Builder(
              builder: (buttonContext) => _HoverBarButton(
                icon: Symbols.more_horiz_rounded,
                tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                onTap: () => onMore(buttonContext),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoverBarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _HoverBarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 消息串入口卡(官方样式:参与者头像 + 最后回复者/摘要 + N 条回复)
class _ThreadEntryCard extends StatelessWidget {
  final ChatThreadRef thread;
  final VoidCallback onTap;

  const _ThreadEntryCard({required this.thread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastUser = thread.lastReplyUser;
    final participants = thread.participants.take(3).toList();
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            child: Row(
              children: [
                // 参与者头像叠排(缺 preview 时退化最后回复者/占位图标)
                if (participants.isNotEmpty)
                  SizedBox(
                    width: 18.0 * participants.length + 8,
                    height: 26,
                    child: Stack(
                      children: [
                        for (var i = 0; i < participants.length; i++)
                          Positioned(
                            left: i * 18.0,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.surface,
                                  width: 1.5,
                                ),
                              ),
                              child: SmartAvatar(
                                imageUrl: participants[i].getAvatarUrl(
                                  size: 48,
                                ),
                                radius: 11,
                                fallbackText: participants[i].username,
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                else if (lastUser != null)
                  SmartAvatar(
                    imageUrl: lastUser.getAvatarUrl(size: 48),
                    radius: 12,
                    fallbackText: lastUser.username,
                  )
                else
                  Icon(
                    Symbols.forum_rounded,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        S.current.chat_threadReplies(thread.replyCount),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (thread.lastReplyExcerpt?.isNotEmpty == true)
                        Row(
                          children: [
                            if (lastUser != null) ...[
                              Text(
                                lastUser.username,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 5),
                            ],
                            Expanded(
                              child: EmojiText(
                                chatPreviewText(
                                  context,
                                  thread.lastReplyExcerpt!,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (thread.lastReplyCreatedAt != null)
                  RelativeTimeText(
                    dateTime: thread.lastReplyCreatedAt!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                Icon(
                  Symbols.chevron_right_rounded,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// reaction 聚合 chip(官方样式:圆角方胶囊,选中=primary 淡底+描边);
/// 桌面 hover Tooltip 显示谁点的,移动长按弹名单
class _ReactionChip extends StatelessWidget {
  final ChatMessageReaction reaction;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _ReactionChip({required this.reaction, this.onTap, this.onLongPress});

  String _usersLabel(BuildContext context) {
    if (reaction.users.isEmpty) return ':${reaction.emoji}:';
    final names = reaction.users.take(6).map((u) => u.username).join('、');
    final more = reaction.count - reaction.users.take(6).length;
    return more > 0
        ? context.l10n.chat_reactionUsersMore(names, more)
        : names;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = EmojiHandler().getEmojiUrl(reaction.emoji);
    final chip = Material(
      color: reaction.reacted
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: reaction.reacted
              ? theme.colorScheme.primary.withValues(alpha: 0.7)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (url.isEmpty)
                Text(reaction.emoji, style: const TextStyle(fontSize: 15))
              else
                Image(image: emojiImageProvider(url), width: 17, height: 17),
              const SizedBox(width: 5),
              Text(
                '${reaction.count}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: reaction.reacted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!PlatformUtils.isDesktop) return chip;
    // 桌面:hover 显示谁点的(官方同款)
    return Tooltip(
      message: _usersLabel(context),
      waitDuration: const Duration(milliseconds: 350),
      child: chip,
    );
  }
}

/// reactions 行尾的"加表情"胶囊(hover 行时出现,官方同款)
class _AddReactionChip extends StatelessWidget {
  final VoidCallback onTap;

  const _AddReactionChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Icon(
            Symbols.add_reaction_rounded,
            size: 17,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _DayDivider extends StatelessWidget {
  final DateTime date;

  const _DayDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = theme.colorScheme.outlineVariant.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              TimeUtils.formatShortDate(date),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: line)),
        ],
      ),
    );
  }
}

class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              context.l10n.chat_unreadDivider,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}
