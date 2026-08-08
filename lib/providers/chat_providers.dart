import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat/chat_models.dart';
import '../services/message_bus_service.dart';
import '../services/preloaded_data_service.dart';
import '../utils/paged_async_notifier.dart';
import 'core_providers.dart';
import 'message_bus/message_bus_service_provider.dart';
import 'message_bus/topic_tracking_providers.dart';
import 'theme_provider.dart';

/// ============================================================================
/// 0. 论坛 Chat 总开关（仅启动预加载快照）
/// ============================================================================

/// 论坛是否开启 Discourse Chat。
///
/// 对齐 `SiteSetting.chat_enabled`：只读 [PreloadedDataService] 启动时缓存的
/// siteSettings，不在运行期反复请求。首次 watch 时会等待 preload 完成一次。
final forumChatEnabledProvider = FutureProvider<bool>((ref) async {
  return PreloadedDataService().isChatEnabled();
});

/// ============================================================================
/// 1. Chat 频道列表
/// ============================================================================

/// Chat 频道列表 Notifier
class ChatChannelsNotifier extends AsyncNotifier<ChatChannelsState> {
  @override
  Future<ChatChannelsState> build() async {
    final service = ref.read(discourseServiceProvider);
    final raw = await service.getChatChannels();
    final state = ChatChannelsState.fromJson(raw);

    // 获取聊天全局在线状态
    Set<int> onlineUserIds = {};
    try {
      final presenceState = await service.getChatPresenceState();
      final chatOnline = presenceState['/chat/online'];
      if (chatOnline is Map) {
        final users = chatOnline['users'];
        if (users is List) {
          for (final u in users) {
            if (u is Map) {
              final userId = (u['id'] as num?)?.toInt();
              if (userId != null) onlineUserIds.add(userId);
            }
          }
        }
      }
    } catch (_) {
      // 在线状态获取失败不影响主流程
    }

    return state.copyWith(onlineUserIds: onlineUserIds);
  }

  /// 刷新频道列表
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      return _fetchChannelsState();
    });
  }

  /// 静默刷新：保留当前值，不进入 loading（用于开关同步等）
  Future<void> refreshSilently() async {
    try {
      final next = await _fetchChannelsState();
      state = AsyncData(next);
    } catch (_) {
      // 静默失败，保留现有状态
    }
  }

  Future<ChatChannelsState> _fetchChannelsState() async {
    final service = ref.read(discourseServiceProvider);
    final raw = await service.getChatChannels();
    final channelsState = ChatChannelsState.fromJson(raw);

    Set<int> onlineUserIds = {};
    try {
      final presenceState = await service.getChatPresenceState();
      final chatOnline = presenceState['/chat/online'];
      if (chatOnline is Map) {
        final users = chatOnline['users'];
        if (users is List) {
          for (final u in users) {
            if (u is Map) {
              final userId = (u['id'] as num?)?.toInt();
              if (userId != null) onlineUserIds.add(userId);
            }
          }
        }
      }
    } catch (_) {}

    return channelsState.copyWith(onlineUserIds: onlineUserIds);
  }

  /// 将用户 ID 标记为在线（乐观更新，无需等待服务器响应）
  void markUserOnline(int userId) {
    final current = state.value;
    if (current == null) return;
    if (current.onlineUserIds.contains(userId)) return;
    state = AsyncData(
      current.copyWith(onlineUserIds: {...current.onlineUserIds, userId}),
    );
  }

  /// 乐观更新频道消息串开关，避免 invalidate 前 UI 不同步
  void setThreadingEnabledLocally(int channelId, bool enabled) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.mapChannel(
        channelId,
        (c) => c.copyWith(threadingEnabled: enabled),
      ),
    );
  }
}

final chatChannelsProvider =
    AsyncNotifierProvider.autoDispose<ChatChannelsNotifier, ChatChannelsState>(
      ChatChannelsNotifier.new,
    );

/// ============================================================================
/// 2. Chat 消息列表（按频道分页）
/// ============================================================================

/// Chat 消息列表 Notifier（按 channelId 分页）
class ChatMessagesNotifier extends AsyncNotifier<List<ChatMessage>>
    with PagedAsyncNotifierMixin<ChatMessage> {
  final int channelId;

  ChatMessagesNotifier(this.channelId);

  /// 是否可向前加载更多（旧消息）
  bool get canLoadMorePast => hasMore;

  /// 是否可向后加载更多（新消息，通常为 false）
  bool canLoadMoreFuture = false;

  /// 定位到指定消息 ID 时传入
  int? targetMessageId;

  /// 已标记已读的最大 message id，避免 build 反复打 read API
  int? _lastMarkedReadId;

  @override
  Future<List<ChatMessage>> build() async {
    resetPagingState();
    _lastMarkedReadId = null;
    _subscribeMessageBus();
    final loaded = await _loadInitialMessages();
    return completePagedRefresh(
      PagedPage(items: loaded.messages, hasMore: loaded.hasMorePast),
    );
  }

  /// 初始加载策略（对齐 Discourse + 移动端「看最新」）：
  /// 1) 优先 fetch_from_last_read
  /// 2) 空/失败/仍有 future（未读窗口在历史中段）→ 回退最新一页
  ///    否则 reverse 列表会把中段历史当成底部，看起来像「没有新消息/空白」
  /// 3) 两次都失败时向上抛错，避免 UI 误显示「无消息」空态
  Future<
    ({
      List<ChatMessage> messages,
      bool hasMorePast,
      bool hasMoreFuture,
      int? targetId,
    })
  >
  _loadInitialMessages() async {
    final service = ref.read(discourseServiceProvider);

    Future<({List<ChatMessage> messages, Map<String, dynamic> raw})> tryFetch({
      bool? fetchFromLastRead,
    }) async {
      final raw = await service.getChannelMessages(
        channelId,
        pageSize: 50,
        fetchFromLastRead: fetchFromLastRead,
      );
      return (messages: _parseMessages(raw), raw: raw);
    }

    bool readCanLoadMoreFuture(Map<String, dynamic> raw) {
      final meta = raw['meta'] is Map
          ? Map<String, dynamic>.from(raw['meta'] as Map)
          : const <String, dynamic>{};
      return (meta['can_load_more_future'] as bool?) ??
          (raw['can_load_more_future'] as bool?) ??
          false;
    }

    Map<String, dynamic> raw = const {};
    var messages = <ChatMessage>[];
    Object? lastError;

    try {
      final first = await tryFetch(fetchFromLastRead: true);
      raw = first.raw;
      messages = first.messages;
      // last_read 窗口若还没贴到 live edge，移动端直接改拉最新，
      // 避免 reverse 列表底部停在历史中段。
      if (messages.isNotEmpty && readCanLoadMoreFuture(raw)) {
        try {
          final live = await tryFetch();
          raw = live.raw;
          messages = live.messages;
        } catch (e) {
          // 保留 last_read 结果，总比空白好
          lastError = e;
        }
      }
    } catch (e) {
      // last_read 目标消息不存在等会 404，回退最新消息
      lastError = e;
    }

    if (messages.isEmpty) {
      try {
        final fallback = await tryFetch();
        raw = fallback.raw;
        messages = fallback.messages;
        lastError = null;
      } catch (e) {
        lastError = e;
      }
    }

    // 两次都失败：抛出错误，让 UI 走 ErrorView 而不是空白/空态
    if (messages.isEmpty && lastError != null && raw.isEmpty) {
      throw lastError;
    }

    final meta = raw['meta'] is Map
        ? Map<String, dynamic>.from(raw['meta'] as Map)
        : const <String, dynamic>{};
    final hasMorePast =
        (meta['can_load_more_past'] as bool?) ??
        (raw['can_load_more_past'] as bool?) ??
        (messages.length >= 10);
    canLoadMoreFuture =
        (meta['can_load_more_future'] as bool?) ??
        (raw['can_load_more_future'] as bool?) ??
        false;
    targetMessageId =
        (meta['target_message_id'] as num?)?.toInt() ??
        (raw['target_message_id'] as num?)?.toInt();

    return (
      messages: messages,
      hasMorePast: hasMorePast,
      hasMoreFuture: canLoadMoreFuture,
      targetId: targetMessageId,
    );
  }

  void _subscribeMessageBus() {
    try {
      // 用 read 而非 watch：messageBusInit 重建时不应整表 reload 造成闪空白。
      // 长轮询域名配置由 main.dart 的 messageBusInitProvider 统一完成。
      ref.read(messageBusInitProvider);
      final messageBus = ref.read(messageBusServiceProvider);
      // 对齐 Discourse ChatChannelSubscriptionManager：`/chat/${channel.id}`
      final channel = '/chat/$channelId';

      void onMessage(MessageBusMessage msg) {
        final data = msg.data;
        if (data is! Map) return;
        final map = Map<String, dynamic>.from(data);
        final type = map['type'] as String?;

        // 严格按 type 分发（对齐 chat-channel-subscription-manager.js）。
        // 禁止对任意含 chat_message 的事件做全量 reload（reaction/processed 等会刷空白）。
        switch (type) {
          case 'sent':
          case 'created':
          case 'edit':
          case 'edited':
          case 'restore':
            final rawMsg = map['chat_message'] ?? map['message'];
            if (rawMsg is Map) {
              try {
                final incoming = ChatMessage.fromJson(
                  Map<String, dynamic>.from(rawMsg),
                );
                if (incoming.id > 0) {
                  _upsertMessage(incoming);
                }
              } catch (_) {}
            }
            return;
          case 'delete':
          case 'deleted':
            final rawMsg = map['chat_message'] ?? map['message'];
            final deletedId =
                (rawMsg is Map ? (rawMsg['id'] as num?)?.toInt() : null) ??
                (map['deleted_id'] as num?)?.toInt() ??
                (map['message_id'] as num?)?.toInt();
            if (deletedId != null) {
              _markMessageDeleted(deletedId);
            }
            return;
          case 'bulk_delete':
            final ids = map['deleted_ids'];
            if (ids is List) {
              for (final id in ids) {
                final mid = (id as num?)?.toInt();
                if (mid != null) _markMessageDeleted(mid);
              }
            }
            return;
          case 'processed':
            // cooked/uploads 更新：尽量增量，失败则忽略（勿全量 reload）
            final rawMsg = map['chat_message'];
            if (rawMsg is Map) {
              try {
                final incoming = ChatMessage.fromJson(
                  Map<String, dynamic>.from(rawMsg),
                );
                if (incoming.id > 0) _upsertMessage(incoming);
              } catch (_) {}
            }
            return;
          default:
            // reaction / notice / pin / thread_* 等：暂不处理，避免误 reload
            return;
        }
      }

      messageBus.subscribe(channel, onMessage);
      ref.onDispose(() {
        messageBus.unsubscribe(channel, onMessage);
      });
    } catch (_) {
      // MessageBus 可选监听，失败不影响主流程
    }
  }

  void _upsertMessage(ChatMessage incoming) {
    final current = List<ChatMessage>.from(state.value ?? const []);
    final idx = current.indexWhere((m) => m.id == incoming.id);
    if (idx >= 0) {
      current[idx] = incoming;
    } else {
      current.add(incoming);
    }
    current.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
    state = AsyncData(current);
  }

  void _markMessageDeleted(int messageId) {
    final current = state.value;
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final updated = List<ChatMessage>.from(current);
    updated[idx] = updated[idx].copyWith(deleted: true);
    state = AsyncData(updated);
  }

  /// 重新加载消息列表
  ///
  /// [preferLatest] 为 true 时直接拉最新一页（发送后/跳到最新），
  /// 避免再走 last_read 中窗把刚发出的消息冲掉。
  Future<void> loadMessages({bool preferLatest = false}) async {
    await runPagedRefresh(() async {
      final loaded = preferLatest
          ? await _loadLatestMessages()
          : await _loadInitialMessages();
      return PagedPage(items: loaded.messages, hasMore: loaded.hasMorePast);
    });
  }

  /// 仅拉最新一页（无 target / 无 last_read）
  Future<
    ({
      List<ChatMessage> messages,
      bool hasMorePast,
      bool hasMoreFuture,
      int? targetId,
    })
  >
  _loadLatestMessages() async {
    final service = ref.read(discourseServiceProvider);
    final raw = await service.getChannelMessages(channelId, pageSize: 50);
    final messages = _parseMessages(raw);
    final meta = raw['meta'] is Map
        ? Map<String, dynamic>.from(raw['meta'] as Map)
        : const <String, dynamic>{};
    final hasMorePast =
        (meta['can_load_more_past'] as bool?) ??
        (raw['can_load_more_past'] as bool?) ??
        (messages.length >= 10);
    canLoadMoreFuture =
        (meta['can_load_more_future'] as bool?) ??
        (raw['can_load_more_future'] as bool?) ??
        false;
    targetMessageId = null;
    return (
      messages: messages,
      hasMorePast: hasMorePast,
      hasMoreFuture: canLoadMoreFuture,
      targetId: null,
    );
  }

  /// 跳到真正的 live edge：若仍有 future 则重拉最新，否则仅依赖 UI 滚底
  Future<void> scrollToLatest() async {
    if (canLoadMoreFuture || targetMessageId != null) {
      await loadMessages(preferLatest: true);
    }
  }

  /// 跳转到指定消息附近（用于搜索结果定位）
  Future<void> jumpToMessage(int messageId) async {
    await runPagedRefresh(() async {
      final service = ref.read(discourseServiceProvider);
      final raw = await service.getChannelMessages(
        channelId,
        pageSize: 50,
        targetMessageId: messageId,
      );
      final messages = _parseMessages(raw);
      final meta = raw['meta'] is Map
          ? Map<String, dynamic>.from(raw['meta'] as Map)
          : const <String, dynamic>{};
      final hasMorePast =
          (meta['can_load_more_past'] as bool?) ??
          (raw['can_load_more_past'] as bool?) ??
          (messages.length >= 10);
      canLoadMoreFuture =
          (meta['can_load_more_future'] as bool?) ??
          (raw['can_load_more_future'] as bool?) ??
          false;
      targetMessageId = messageId;
      return PagedPage(items: messages, hasMore: hasMorePast);
    });
  }

  /// 加载更多历史消息（向上翻页）
  Future<void> loadMore() async {
    await runPagedLoadMore((currentItems, nextPage) async {
      // 取当前最早消息的 id (即最小值) 作为 targetMessageId 来获取更早的历史消息
      final minTargetId = currentItems.isNotEmpty
          ? currentItems.map((m) => m.id).reduce((a, b) => a < b ? a : b)
          : null;
      final service = ref.read(discourseServiceProvider);
      final raw = await service.getChannelMessages(
        channelId,
        pageSize: 50,
        direction: 'past',
        targetMessageId: minTargetId,
      );
      final messages = _parseMessages(raw);

      final existingIds = currentItems.map((m) => m.id).toSet();
      final newMessages = messages
          .where((m) => !existingIds.contains(m.id))
          .toList();
      newMessages.sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });

      final combined = [...newMessages, ...currentItems];
      combined.sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });

      final meta = raw['meta'] is Map
          ? Map<String, dynamic>.from(raw['meta'] as Map)
          : const <String, dynamic>{};
      final hasMorePast =
          (meta['can_load_more_past'] as bool?) ??
          (raw['can_load_more_past'] as bool?) ??
          (messages.isNotEmpty && messages.length >= 10);
      // past 分页不改变 future 标志（除非服务端显式返回）
      final futureFlag =
          meta['can_load_more_future'] as bool? ??
          raw['can_load_more_future'] as bool?;
      if (futureFlag != null) canLoadMoreFuture = futureFlag;
      return PagedPage(
        items: combined,
        hasMore: hasMorePast,
        advancePage: newMessages.isNotEmpty,
      );
    });
  }

  /// 向更新方向加载（搜索跳转后贴回 live edge 时用）
  Future<void> loadMoreFuture() async {
    if (!canLoadMoreFuture || state.isLoading) return;
    final currentItems = state.value;
    if (currentItems == null || currentItems.isEmpty) return;

    final maxTargetId = currentItems
        .map((m) => m.id)
        .reduce((a, b) => a > b ? a : b);
    // ignore: invalid_use_of_internal_member
    state = AsyncLoading<List<ChatMessage>>().copyWithPrevious(state);
    try {
      final service = ref.read(discourseServiceProvider);
      final raw = await service.getChannelMessages(
        channelId,
        pageSize: 50,
        direction: 'future',
        targetMessageId: maxTargetId,
      );
      final messages = _parseMessages(raw);
      final existingIds = currentItems.map((m) => m.id).toSet();
      final newMessages = messages
          .where((m) => !existingIds.contains(m.id))
          .toList();
      final combined = [...currentItems, ...newMessages];
      combined.sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
      final meta = raw['meta'] is Map
          ? Map<String, dynamic>.from(raw['meta'] as Map)
          : const <String, dynamic>{};
      canLoadMoreFuture =
          (meta['can_load_more_future'] as bool?) ??
          (raw['can_load_more_future'] as bool?) ??
          (newMessages.length >= 10);
      // past 的 hasMore 保持不变；future 仅更新 canLoadMoreFuture
      state = AsyncData(combined);
    } catch (_) {
      state = AsyncData(currentItems);
    }
  }

  /// 发送消息（支持回复和附件）
  Future<int> sendMessage(
    String text, {
    int? threadId,
    int? inReplyToId,
    List<int>? uploadIds,
  }) async {
    final service = ref.read(discourseServiceProvider);
    final messageId = await service.sendChatMessage(
      channelId,
      text,
      threadId: threadId,
      inReplyToId: inReplyToId,
      uploadIds: uploadIds,
    );
    // 发送后拉最新，避免 last_read 中窗覆盖刚发出的消息
    unawaited(loadMessages(preferLatest: true));
    return messageId;
  }

  /// 确保消息有 thread：已有则返回，否则 createThread
  ///
  /// 对齐 Discourse chat-channel-composer.replyTo：
  /// threadingEnabled 时回复会先创建/进入消息串。
  Future<ChatThread> ensureThreadForMessage(ChatMessage message) async {
    if (message.thread != null && message.thread!.id > 0) {
      return message.thread!;
    }
    if (message.threadId != null && message.threadId! > 0) {
      return ChatThread(
        id: message.threadId!,
        channelId: channelId,
        title: message.threadTitle,
      );
    }

    final service = ref.read(discourseServiceProvider);
    final raw = await service.createChatThread(channelId, message.id);
    // create 接口 root:false，本身就是 thread 对象；兼容 {thread: {...}}
    final threadJson = raw['thread'] is Map
        ? Map<String, dynamic>.from(raw['thread'] as Map)
        : raw;
    final thread = ChatThread.fromJson(threadJson);

    // 回写本地消息的 thread 字段，便于指示器立刻出现
    final current = List<ChatMessage>.from(state.value ?? const []);
    final idx = current.indexWhere((m) => m.id == message.id);
    if (idx >= 0) {
      current[idx] = current[idx].copyWith(
        threadId: thread.id,
        thread: thread,
        threadTitle: thread.title,
      );
      state = AsyncData(current);
    }
    return thread;
  }

  /// 在消息串内发送
  Future<int> sendThreadMessage(
    int threadId,
    String text, {
    int? inReplyToId,
    List<int>? uploadIds,
  }) async {
    final service = ref.read(discourseServiceProvider);
    return service.sendChatMessage(
      channelId,
      text,
      threadId: threadId,
      inReplyToId: inReplyToId,
      uploadIds: uploadIds,
    );
  }

  /// 编辑消息
  Future<void> editMessage(int messageId, String newText) async {
    final service = ref.read(discourseServiceProvider);
    await service.updateChatMessage(channelId, messageId, newText);
    unawaited(loadMessages(preferLatest: true));
  }

  /// 删除消息
  Future<void> deleteMessage(int messageId) async {
    // 先乐观标记，避免全量 reload 闪空白
    _markMessageDeleted(messageId);
    final service = ref.read(discourseServiceProvider);
    try {
      await service.deleteChatMessage(channelId, messageId);
    } catch (_) {
      unawaited(loadMessages(preferLatest: true));
      rethrow;
    }
  }

  /// 恢复已删除消息
  Future<void> restoreMessage(int messageId) async {
    final service = ref.read(discourseServiceProvider);
    await service.restoreChatMessage(channelId, messageId);
    unawaited(loadMessages(preferLatest: true));
  }

  /// 举报消息
  Future<void> flagMessage(
    int messageId,
    int flagTypeId, {
    String? message,
  }) async {
    final service = ref.read(discourseServiceProvider);
    await service.flagChatMessage(
      channelId,
      messageId,
      flagTypeId,
      message: message,
    );
  }

  /// 生成消息引用 Markdown
  Future<String> quoteMessages(List<int> messageIds) async {
    final service = ref.read(discourseServiceProvider);
    return service.quoteChatMessages(channelId, messageIds);
  }

  /// 置顶/取消置顶
  Future<void> togglePin(int messageId, {required bool pin}) async {
    final currentList = state.value ?? [];
    final msgIndex = currentList.indexWhere((m) => m.id == messageId);
    if (msgIndex == -1) return;

    final msg = currentList[msgIndex];
    final updatedList = List<ChatMessage>.from(currentList);
    updatedList[msgIndex] = msg.copyWith(pinned: pin);
    state = AsyncValue.data(updatedList);

    try {
      final service = ref.read(discourseServiceProvider);
      if (pin) {
        await service.pinChatMessage(channelId, messageId);
      } else {
        await service.unpinChatMessage(channelId, messageId);
      }
    } catch (_) {
      state = AsyncValue.data(currentList);
      rethrow;
    }
  }

  /// 标记已读（同 id / 更旧 id 跳过，避免 build 反复请求）
  Future<void> markAsRead(int messageId) async {
    if (_lastMarkedReadId != null && messageId <= _lastMarkedReadId!) {
      return;
    }
    _lastMarkedReadId = messageId;
    try {
      final service = ref.read(discourseServiceProvider);
      await service.markChannelRead(channelId, messageId);
    } catch (_) {
      // 已读失败不阻塞 UI；允许下次重试
      if (_lastMarkedReadId == messageId) {
        _lastMarkedReadId = null;
      }
    }
  }

  /// 切换消息 Emoji 回应 (Reaction)
  ///
  /// [knownReacted]：消息不在当前频道窗口（如消息串内）时，由调用方
  /// 传入已知 reacted 状态；缺省时若本地无该消息则按「添加」处理。
  Future<void> toggleReaction(
    int messageId,
    String emoji, {
    bool? knownReacted,
  }) async {
    final currentList = state.value ?? [];
    final msgIndex = currentList.indexWhere((m) => m.id == messageId);

    // 本地有消息：乐观更新；否则只打 API（消息串场景）
    if (msgIndex != -1) {
      final msg = currentList[msgIndex];
      final reactions = List<ChatMessageReaction>.from(msg.reactions ?? []);
      final rIndex = reactions.indexWhere((r) => r.emoji == emoji);

      final isAlreadyReacted = rIndex != -1 && reactions[rIndex].reacted;
      final action = isAlreadyReacted ? 'remove' : 'add';

      // 乐观更新 UI（保留 users，避免长按查看反应用户时列表被清空）
      final newReactions = List<ChatMessageReaction>.from(reactions);
      if (isAlreadyReacted) {
        final old = newReactions[rIndex];
        if (old.count <= 1) {
          newReactions.removeAt(rIndex);
        } else {
          newReactions[rIndex] = ChatMessageReaction(
            emoji: old.emoji,
            count: old.count - 1,
            reacted: false,
            users: old.users,
          );
        }
      } else {
        if (rIndex != -1) {
          final old = newReactions[rIndex];
          newReactions[rIndex] = ChatMessageReaction(
            emoji: old.emoji,
            count: old.count + 1,
            reacted: true,
            users: old.users,
          );
        } else {
          newReactions.add(
            ChatMessageReaction(emoji: emoji, count: 1, reacted: true),
          );
        }
      }

      final updatedMsg = msg.copyWith(reactions: newReactions);
      final updatedList = List<ChatMessage>.from(currentList);
      updatedList[msgIndex] = updatedMsg;
      state = AsyncValue.data(updatedList);

      try {
        final service = ref.read(discourseServiceProvider);
        await service.reactToChatMessage(
          channelId,
          messageId,
          emoji,
          action: action,
        );
      } catch (_) {
        state = AsyncValue.data(currentList);
        rethrow;
      }
      return;
    }

    // 消息不在频道窗口：直接 API（消息串内回复等）
    final action = (knownReacted == true) ? 'remove' : 'add';
    final service = ref.read(discourseServiceProvider);
    await service.reactToChatMessage(
      channelId,
      messageId,
      emoji,
      action: action,
    );
  }

  /// 切换消息书签状态 (Bookmark)
  ///
  /// [knownBookmarked] / [knownBookmarkId]：消息不在当前窗口时由调用方提供。
  Future<void> toggleBookmark(
    int messageId, {
    bool? knownBookmarked,
    int? knownBookmarkId,
  }) async {
    final currentList = state.value ?? [];
    final msgIndex = currentList.indexWhere((m) => m.id == messageId);

    if (msgIndex != -1) {
      final msg = currentList[msgIndex];
      final nextBookmarked = !msg.bookmarked;

      if (!nextBookmarked && (msg.bookmarkId == null || msg.bookmarkId! <= 0)) {
        return;
      }

      final updatedList = List<ChatMessage>.from(currentList);
      updatedList[msgIndex] = nextBookmarked
          ? msg.copyWith(bookmarked: true)
          : msg.copyWith(bookmarked: false, clearBookmarkId: true);
      state = AsyncValue.data(updatedList);

      try {
        final service = ref.read(discourseServiceProvider);
        final newBookmarkId = await service.toggleChatMessageBookmark(
          channelId,
          messageId,
          bookmarked: nextBookmarked,
          bookmarkId: msg.bookmarkId,
        );
        if (nextBookmarked) {
          final latest = List<ChatMessage>.from(state.value ?? updatedList);
          final idx = latest.indexWhere((m) => m.id == messageId);
          if (idx != -1) {
            latest[idx] = latest[idx].copyWith(
              bookmarked: true,
              bookmarkId: newBookmarkId,
            );
            state = AsyncValue.data(latest);
          }
        }
      } catch (_) {
        state = AsyncValue.data(currentList);
        rethrow;
      }
      return;
    }

    // 消息不在频道窗口
    final currentlyBookmarked = knownBookmarked ?? false;
    final nextBookmarked = !currentlyBookmarked;
    if (!nextBookmarked && (knownBookmarkId == null || knownBookmarkId <= 0)) {
      return;
    }
    final service = ref.read(discourseServiceProvider);
    await service.toggleChatMessageBookmark(
      channelId,
      messageId,
      bookmarked: nextBookmarked,
      bookmarkId: knownBookmarkId,
    );
  }

  /// 加载更多失败时重试
  Future<void> retryLoadMore() {
    return retryPagedLoadMore(loadMore);
  }

  /// 解析消息列表（支持时间升序排序）
  ///
  /// Discourse MessagesSerializer 根键为 `messages`（不是 chat_messages），
  /// 分页元数据在 `meta` 中。
  List<ChatMessage> _parseMessages(Map<String, dynamic> raw) {
    final list = raw['messages'] ?? raw['chat_messages'];
    if (list is! List) return [];

    // 解析顶层 users 映射，供消息缺失 user 字段时按 user_id 匹配补全
    final usersMap = <int, ChatUser>{};
    if (raw['users'] is List) {
      for (final u in raw['users'] as List) {
        if (u is Map) {
          final user = ChatUser.fromJson(Map<String, dynamic>.from(u));
          usersMap[user.id] = user;
        }
      }
    }

    final parsed = <ChatMessage>[];
    for (final e in list) {
      if (e is! Map) continue;
      try {
        final json = Map<String, dynamic>.from(e);
        if (json['user'] == null && json['user_id'] != null) {
          final userId = (json['user_id'] as num?)?.toInt();
          if (userId != null && usersMap.containsKey(userId)) {
            json['user'] = usersMap[userId]!.toJson();
          }
        }
        // 过滤无效消息（无 id）
        final msg = ChatMessage.fromJson(json);
        if (msg.id > 0) {
          parsed.add(msg);
        }
      } catch (_) {
        // 单条解析失败不拖垮整页
      }
    }

    parsed.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
    return parsed;
  }
}

final chatMessagesProvider =
    AsyncNotifierProvider.family<ChatMessagesNotifier, List<ChatMessage>, int>(
      ChatMessagesNotifier.new,
    );

/// 消息串消息列表参数
typedef ChatThreadMessagesParams = ({int channelId, int threadId});

/// 消息串消息列表
final chatThreadMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, ChatThreadMessagesParams>((ref, params) async {
      final service = ref.read(discourseServiceProvider);
      final raw = await service.getChatThreadMessages(
        params.channelId,
        params.threadId,
        pageSize: 50,
      );
      return _parseChatMessageList(raw);
    });

/// 频道消息串列表
final chatChannelThreadsProvider = FutureProvider.autoDispose
    .family<List<ChatThread>, int>((ref, channelId) async {
      final service = ref.read(discourseServiceProvider);
      final raw = await service.getChatChannelThreads(channelId);
      final list = raw['threads'];
      if (list is! List) return const [];
      final threads = <ChatThread>[];
      for (final e in list) {
        if (e is! Map) continue;
        try {
          final thread = ChatThread.fromJson(Map<String, dynamic>.from(e));
          if (thread.id > 0) threads.add(thread);
        } catch (_) {}
      }
      return threads;
    });

/// 解析消息列表公共逻辑（频道消息 / 消息串消息）
List<ChatMessage> _parseChatMessageList(Map<String, dynamic> raw) {
  final list = raw['messages'] ?? raw['chat_messages'];
  if (list is! List) return const [];

  final usersMap = <int, ChatUser>{};
  if (raw['users'] is List) {
    for (final u in raw['users'] as List) {
      if (u is Map) {
        final user = ChatUser.fromJson(Map<String, dynamic>.from(u));
        usersMap[user.id] = user;
      }
    }
  }

  final parsed = <ChatMessage>[];
  for (final e in list) {
    if (e is! Map) continue;
    try {
      final json = Map<String, dynamic>.from(e);
      if (json['user'] == null && json['user_id'] != null) {
        final userId = (json['user_id'] as num?)?.toInt();
        if (userId != null && usersMap.containsKey(userId)) {
          json['user'] = usersMap[userId]!.toJson();
        }
      }
      final msg = ChatMessage.fromJson(json);
      if (msg.id > 0) parsed.add(msg);
    } catch (_) {}
  }
  parsed.sort((a, b) {
    final byTime = a.createdAt.compareTo(b.createdAt);
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id);
  });
  return parsed;
}

/// 所有频道消息串列表（全局消息串 Tab 使用）
///
/// 遍历所有启用了消息串的频道（兜底取前 15 个活跃频道），
/// 获取每个频道的消息串列表，按最后回复时间排序。
final chatAllThreadsProvider =
    FutureProvider.autoDispose<List<(ChatThread, ChatChannel)>>((ref) async {
      final channelsState = ref.watch(chatChannelsProvider).value;
      if (channelsState == null) return const [];

      final all = [
        ...channelsState.publicChannels,
        ...channelsState.directMessageChannels,
      ];

      // 优先取启用了消息串的频道；若没有则取前 15 个活跃频道
      final candidates = all.where((c) => c.threadingEnabled).toList();
      if (candidates.isEmpty) {
        candidates.addAll(all.take(15));
      }

      final service = ref.read(discourseServiceProvider);
      final result = <(ChatThread, ChatChannel)>[];

      for (final channel in candidates) {
        try {
          final raw = await service.getChatChannelThreads(channel.id);
          final list = raw['threads'];
          if (list is! List) continue;
          for (final e in list) {
            if (e is! Map) continue;
            try {
              final thread = ChatThread.fromJson(Map<String, dynamic>.from(e));
              if (thread.id > 0) {
                result.add((thread, channel));
              }
            } catch (_) {}
          }
        } catch (_) {
          // 单个频道加载失败不影响其他频道
        }
      }

      // 按最后回复时间排序（最新的在前）
      result.sort((a, b) {
        final aTime =
            a.$1.preview?.lastReplyCreatedAt ??
            a.$1.originalMessage?.createdAt ??
            DateTime(2000);
        final bTime =
            b.$1.preview?.lastReplyCreatedAt ??
            b.$1.originalMessage?.createdAt ??
            DateTime(2000);
        return bTime.compareTo(aTime);
      });

      return result;
    });

/// ============================================================================
/// 3. 未读统计 Provider
/// ============================================================================

/// 所有 Chat 频道的未读消息总数
///
/// 从 [chatChannelsProvider] 的 tracking 数据中提取并汇总。
final chatUnreadProvider = Provider<int>((ref) {
  final channelsState = ref.watch(chatChannelsProvider).value;
  if (channelsState == null) return 0;

  // 优先用已合并到频道上的未读；tracking 作为兜底
  var total = 0;
  final all = [
    ...channelsState.publicChannels,
    ...channelsState.directMessageChannels,
  ];
  if (all.isNotEmpty) {
    for (final ch in all) {
      // 对齐官方：公开频道偏 mention，DM 偏 unread_count；这里汇总两者避免漏计
      total += ch.unreadCount + ch.unreadMentions;
    }
    if (total > 0) return total;
  }

  for (final entry in channelsState.tracking.entries) {
    total += (entry.value['unread_count'] as num?)?.toInt() ?? 0;
    total +=
        (entry.value['mention_count'] as num?)?.toInt() ??
        (entry.value['unread_mentions'] as num?)?.toInt() ??
        0;
  }
  return total;
});

/// ============================================================================
/// 4. 创建直接消息 / 公开频道
/// ============================================================================

/// 创建直接消息 / 群组聊天参数
///
/// [usernames]：对方用户名列表（不含自己；服务端会并入当前用户）。
/// [name]：群聊可选名称（多人时建议填写）。
typedef CreateDirectMessageParams = ({List<String> usernames, String? name});

final createDirectMessageProvider =
    FutureProvider.family<int, CreateDirectMessageParams>((ref, params) async {
      final service = ref.read(discourseServiceProvider);
      final channelId = await service.createDirectMessageChannel(
        params.usernames,
        name: params.name,
      );
      // 创建后刷新频道列表
      ref.invalidate(chatChannelsProvider);
      return channelId;
    });

/// 创建公开（分类）频道参数
typedef CreateChatChannelParams = ({
  String name,
  int chatableId,
  String? slug,
  String? description,
  String? emoji,
  bool autoJoinUsers,
  bool threadingEnabled,
});

/// 创建公开频道（需 staff）
final createChatChannelProvider =
    FutureProvider.family<ChatChannel, CreateChatChannelParams>((
      ref,
      params,
    ) async {
      final service = ref.read(discourseServiceProvider);
      final raw = await service.createChannel(
        name: params.name,
        chatableId: params.chatableId,
        slug: params.slug,
        description: params.description,
        emoji: params.emoji,
        autoJoinUsers: params.autoJoinUsers,
        threadingEnabled: params.threadingEnabled,
      );
      ref.invalidate(chatChannelsProvider);
      return ChatChannel.fromJson(raw);
    });

/// 单个频道详情（含 status，浏览未 following 的关闭频道时用于只读判断）
final chatChannelDetailProvider = FutureProvider.autoDispose
    .family<ChatChannel?, int>((ref, channelId) async {
      // 先从已加载的 me/channels 取
      final channelsState = ref.watch(chatChannelsProvider).value;
      if (channelsState != null) {
        for (final c in [
          ...channelsState.publicChannels,
          ...channelsState.directMessageChannels,
        ]) {
          if (c.id == channelId) return c;
        }
      }
      final service = ref.read(discourseServiceProvider);
      final raw = await service.getChatChannel(channelId);
      final channelJson = raw['channel'] is Map
          ? Map<String, dynamic>.from(raw['channel'] as Map)
          : raw;
      return ChatChannel.fromJson(channelJson);
    });

/// ============================================================================
/// 5. 搜索 Chat 可提及用户
/// ============================================================================

final chatSearchProvider = FutureProvider.family<List<Chatable>, String>((
  ref,
  filter,
) async {
  final service = ref.read(discourseServiceProvider);
  final raw = await service.searchChatables(filter);
  final users = raw['users'] as List<dynamic>? ?? [];
  final result = <Chatable>[];
  for (final e in users) {
    if (e is! Map) continue;
    final map = Map<String, dynamic>.from(e);
    // Discourse ChatablesSerializer: { identifier, model: {...}, type, match_quality }
    final model = map['model'] is Map
        ? Map<String, dynamic>.from(map['model'] as Map)
        : map;
    final chatable = Chatable.fromJson(model);
    if (chatable.username.isNotEmpty) {
      result.add(chatable);
    }
  }
  return result;
});

/// 频道内 / 全局消息搜索结果
class ChatMessageSearchResult {
  final List<ChatMessage> messages;
  final bool hasMore;
  final int limit;
  final int offset;

  const ChatMessageSearchResult({
    required this.messages,
    this.hasMore = false,
    this.limit = 20,
    this.offset = 0,
  });
}

/// 搜索消息参数（频道内或全局）
///
/// [sort] 对齐 Discourse：`relevance` | `latest`
typedef ChatMessageSearchParams = ({
  String query,
  int? channelId,
  String sort,
  int offset,
  int limit,
});

/// 在指定频道内搜索消息（默认 latest）
final chatChannelSearchProvider =
    FutureProvider.family<
      ChatMessageSearchResult,
      ({int channelId, String query})
    >((ref, params) async {
      return ref.watch(
        chatMessageSearchProvider((
          query: params.query,
          channelId: params.channelId,
          sort: 'latest',
          offset: 0,
          limit: 20,
        )).future,
      );
    });

/// 全局 / 频道消息搜索（支持 relevance / latest）
final chatMessageSearchProvider = FutureProvider.autoDispose
    .family<ChatMessageSearchResult, ChatMessageSearchParams>((
      ref,
      params,
    ) async {
      final query = params.query.trim();
      if (query.isEmpty) {
        return const ChatMessageSearchResult(messages: []);
      }
      final service = ref.read(discourseServiceProvider);
      final raw = await service.searchChannelMessages(
        query: query,
        channelId: params.channelId,
        sort: params.sort,
        offset: params.offset,
        limit: params.limit,
      );
      final list = raw['messages'] as List? ?? [];
      final messages = <ChatMessage>[];
      for (final e in list) {
        if (e is! Map) continue;
        try {
          final map = Map<String, dynamic>.from(e);
          // 搜索 API 可能把 channel 嵌在 message 上；尽量补全 chat_channel_id
          if (map['chat_channel_id'] == null && map['channel'] is Map) {
            final ch = Map<String, dynamic>.from(map['channel'] as Map);
            map['chat_channel_id'] = ch['id'];
          }
          // 保留 channel 标题供全局搜索展示（塞进 threadTitle 不合适，用 uploads 也不行）
          // 用 message 字段旁路：后续 UI 从 raw 取 channel；这里解析 message 本体即可
          messages.add(ChatMessage.fromJson(map));
        } catch (_) {}
      }
      final meta = raw['meta'] is Map
          ? Map<String, dynamic>.from(raw['meta'] as Map)
          : const <String, dynamic>{};
      return ChatMessageSearchResult(
        messages: messages,
        hasMore: meta['has_more'] as bool? ?? false,
        limit: (meta['limit'] as num?)?.toInt() ?? params.limit,
        offset: (meta['offset'] as num?)?.toInt() ?? params.offset,
      );
    });

/// 全局搜索单条结果（含频道标题，便于列表展示）
class ChatGlobalSearchHit {
  final ChatMessage message;
  final int channelId;
  final String channelTitle;
  final String? channelEmoji;
  final String? threadTitle;

  const ChatGlobalSearchHit({
    required this.message,
    required this.channelId,
    required this.channelTitle,
    this.channelEmoji,
    this.threadTitle,
  });
}

class ChatGlobalSearchResult {
  final List<ChatGlobalSearchHit> hits;
  final bool hasMore;
  final int offset;
  final int limit;

  const ChatGlobalSearchResult({
    required this.hits,
    this.hasMore = false,
    this.offset = 0,
    this.limit = 20,
  });
}

/// 全局聊天搜索（解析嵌套 channel）
final chatGlobalSearchProvider = FutureProvider.autoDispose
    .family<ChatGlobalSearchResult, ({String query, String sort, int offset})>((
      ref,
      params,
    ) async {
      final query = params.query.trim();
      if (query.isEmpty) {
        return const ChatGlobalSearchResult(hits: []);
      }
      final service = ref.read(discourseServiceProvider);
      final raw = await service.searchChannelMessages(
        query: query,
        sort: params.sort,
        offset: params.offset,
        limit: 20,
      );
      final list = raw['messages'] as List? ?? [];
      final hits = <ChatGlobalSearchHit>[];
      for (final e in list) {
        if (e is! Map) continue;
        try {
          final map = Map<String, dynamic>.from(e);
          final channelMap = map['channel'] is Map
              ? Map<String, dynamic>.from(map['channel'] as Map)
              : null;
          final channelId =
              (map['chat_channel_id'] as num?)?.toInt() ??
              (channelMap?['id'] as num?)?.toInt() ??
              0;
          if (channelId == 0) continue;
          if (map['chat_channel_id'] == null) {
            map['chat_channel_id'] = channelId;
          }
          final message = ChatMessage.fromJson(map);
          final title =
              channelMap?['title']?.toString() ??
              channelMap?['name']?.toString() ??
              '频道 $channelId';
          hits.add(
            ChatGlobalSearchHit(
              message: message,
              channelId: channelId,
              channelTitle: title,
              channelEmoji: channelMap?['emoji']?.toString(),
              threadTitle:
                  map['thread_title']?.toString() ?? message.threadTitle,
            ),
          );
        } catch (_) {}
      }
      final meta = raw['meta'] is Map
          ? Map<String, dynamic>.from(raw['meta'] as Map)
          : const <String, dynamic>{};
      return ChatGlobalSearchResult(
        hits: hits,
        hasMore: meta['has_more'] as bool? ?? false,
        offset: (meta['offset'] as num?)?.toInt() ?? params.offset,
        limit: (meta['limit'] as num?)?.toInt() ?? 20,
      );
    });

/// ============================================================================
/// 6. 频道成员列表与添加成员 Provider（支持分页流式加载）
/// ============================================================================

/// 成员列表分页状态
class ChatChannelMembersState {
  final List<ChatUser> members;
  final int? totalRows;
  final int offset;
  final bool hasMore;
  final bool isLoadingMore;
  final Object? loadMoreError;

  const ChatChannelMembersState({
    this.members = const [],
    this.totalRows,
    this.offset = 0,
    this.hasMore = true,
    this.isLoadingMore = false,
    this.loadMoreError,
  });

  /// 展示用人数：优先服务端 total_rows，否则用已加载数量
  int get displayCount => totalRows ?? members.length;

  ChatChannelMembersState copyWith({
    List<ChatUser>? members,
    int? totalRows,
    int? offset,
    bool? hasMore,
    bool? isLoadingMore,
    Object? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return ChatChannelMembersState(
      members: members ?? this.members,
      totalRows: totalRows ?? this.totalRows,
      offset: offset ?? this.offset,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

ChatUser? _userFromMembershipMap(Map<String, dynamic> e) {
  Map<String, dynamic>? userMap;
  if (e['user'] is Map) {
    userMap = Map<String, dynamic>.from(e['user'] as Map);
  } else if (e['user_chat_channel_membership'] is Map &&
      e['user_chat_channel_membership']['user'] is Map) {
    userMap = Map<String, dynamic>.from(
      e['user_chat_channel_membership']['user'] as Map,
    );
  } else {
    userMap = Map<String, dynamic>.from(e);
  }
  final u = ChatUser.fromJson(userMap);
  if (u.username.isEmpty) return null;
  return u;
}

class ChatChannelMembersNotifier
    extends AsyncNotifier<ChatChannelMembersState> {
  ChatChannelMembersNotifier(this.channelId);

  final int channelId;
  static const _pageSize = 50;

  @override
  Future<ChatChannelMembersState> build() async {
    return _fetchPage(offset: 0, existing: const []);
  }

  Future<ChatChannelMembersState> _fetchPage({
    required int offset,
    required List<ChatUser> existing,
  }) async {
    final service = ref.read(discourseServiceProvider);
    final seen = <String>{for (final u in existing) u.username.toLowerCase()};
    final list = List<ChatUser>.from(existing);
    final previousTotal = state.asData?.value.totalRows;

    try {
      final page = await service.getChannelMembersPage(
        channelId,
        limit: _pageSize,
        offset: offset,
      );
      for (final e in page.members) {
        final u = _userFromMembershipMap(e);
        if (u != null && seen.add(u.username.toLowerCase())) {
          list.add(u);
        }
      }

      // 首页补充 DM 固定成员，并用频道 memberships_count 兜底总人数
      int? channelCount;
      if (offset == 0) {
        final channelsState = ref.read(chatChannelsProvider).value;
        if (channelsState != null) {
          final all = [
            ...channelsState.publicChannels,
            ...channelsState.directMessageChannels,
          ];
          for (final c in all) {
            if (c.id != channelId) continue;
            channelCount = c.membersCount;
            for (final u in c.dmUsers ?? const <ChatUser>[]) {
              if (u.username.isNotEmpty && seen.add(u.username.toLowerCase())) {
                list.add(u);
              }
            }
            break;
          }
        }
      }

      final total = page.totalRows ?? channelCount ?? previousTotal;
      // offset 必须按「服务端返回条数」推进，而不是去重后的本地条数，
      // 否则下一页会重复请求同一 offset，表现为无法继续流式加载。
      final nextOffset = offset + page.members.length;
      final bool hasMore;
      if (page.members.isEmpty) {
        hasMore = false;
      } else if (total != null) {
        hasMore = nextOffset < total;
      } else {
        hasMore = page.members.length >= _pageSize;
      }

      return ChatChannelMembersState(
        members: list,
        totalRows: total,
        offset: nextOffset,
        hasMore: hasMore,
      );
    } catch (e) {
      if (existing.isNotEmpty) {
        return ChatChannelMembersState(
          members: existing,
          totalRows: previousTotal,
          offset: offset,
          hasMore: true,
          loadMoreError: e,
        );
      }
      rethrow;
    }
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || !current.hasMore || current.isLoadingMore) {
      return;
    }

    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );
    try {
      final next = await _fetchPage(
        offset: current.offset,
        existing: current.members,
      );
      // 若服务端本页为空，结束分页，避免死循环
      final reachedEnd =
          next.offset <= current.offset ||
          (next.members.length <= current.members.length &&
              next.totalRows != null &&
              next.offset >= (next.totalRows ?? 0));
      state = AsyncData(
        next.copyWith(
          isLoadingMore: false,
          hasMore: reachedEnd ? false : next.hasMore,
        ),
      );
    } catch (e) {
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: e),
      );
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => _fetchPage(offset: 0, existing: const []),
    );
  }
}

final chatChannelMembersProvider =
    AsyncNotifierProvider.family<
      ChatChannelMembersNotifier,
      ChatChannelMembersState,
      int
    >(ChatChannelMembersNotifier.new);

final addChannelMemberProvider =
    FutureProvider.family<void, ({int channelId, String username})>((
      ref,
      params,
    ) async {
      final service = ref.read(discourseServiceProvider);
      await service.addChannelMember(params.channelId, params.username);
      // 刷新分页成员列表
      ref.invalidate(chatChannelMembersProvider(params.channelId));
    });

/// ============================================================================
/// 7. Chat 收藏频道 Provider
/// ============================================================================

class ChatFavoritesNotifier extends Notifier<Set<int>> {
  static const _key = 'favorite_chat_channel_ids';

  @override
  Set<int> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final localList = prefs.getStringList(_key) ?? [];
    final set = localList.map((e) => int.tryParse(e)).whereType<int>().toSet();

    // 优先以后端 Discourse 权威数据 starred 为准（following ≠ 收藏）
    final channelsAsync = ref.watch(chatChannelsProvider);
    final channelsState = channelsAsync.value;
    if (channelsState != null) {
      final allChannels = [
        ...channelsState.publicChannels,
        ...channelsState.directMessageChannels,
      ];
      for (final channel in allChannels) {
        final isServerFav =
            channel.starred ||
            (channel.userChatChannelMembership?['starred'] == true);

        if (isServerFav) {
          set.add(channel.id);
        }
      }
    }

    return set;
  }

  Future<void> toggleFavorite(int channelId) async {
    final next = Set<int>.from(state);
    final isFav = next.contains(channelId);
    if (isFav) {
      next.remove(channelId);
    } else {
      next.add(channelId);
    }
    state = next;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList(_key, next.map((e) => e.toString()).toList());

    // 同步 starred 到 Discourse 服务端（与 follow/unfollow 不同）
    try {
      final service = ref.read(discourseServiceProvider);
      await service.setChannelStarred(channelId, starred: !isFav);
      // 刷新频道列表保持云端与本地状态强一致
      ref.invalidate(chatChannelsProvider);
    } catch (_) {}
  }

  bool isFavorite(int channelId) => state.contains(channelId);
}

final chatFavoritesProvider = NotifierProvider<ChatFavoritesNotifier, Set<int>>(
  ChatFavoritesNotifier.new,
);

/// ============================================================================
/// 8. 频道浏览 Provider（论坛所有公开频道）
/// ============================================================================

/// 浏览频道请求参数
class BrowseChannelsParams {
  final String? status;
  final String? filter;

  const BrowseChannelsParams({this.status, this.filter});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BrowseChannelsParams &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          filter == other.filter;

  @override
  int get hashCode => Object.hash(status, filter);
}

/// 浏览频道列表 Provider
///
/// 获取论坛中所有公开频道（支持 status 过滤和搜索）
final browseChannelsProvider =
    FutureProvider.family<List<ChatChannel>, BrowseChannelsParams>((
      ref,
      params,
    ) async {
      final service = ref.read(discourseServiceProvider);
      final raw = await service.browseChannels(
        status: params.status,
        filter: params.filter,
      );
      final channels = raw['channels'] as List? ?? [];
      return channels
          .map((e) => ChatChannel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    });

/// 加入频道 Provider
final joinChannelProvider = FutureProvider.family<void, int>((
  ref,
  channelId,
) async {
  final service = ref.read(discourseServiceProvider);
  await service.joinChannel(channelId);
  // 刷新我的频道 + 浏览列表
  ref.invalidate(chatChannelsProvider);
  ref.invalidate(browseChannelsProvider);
});

/// 离开频道 Provider（破坏性 leave，移除 membership）
final leaveChannelProvider = FutureProvider.family<void, int>((
  ref,
  channelId,
) async {
  final service = ref.read(discourseServiceProvider);
  await service.leaveChannel(channelId);
  ref.invalidate(chatChannelsProvider);
  ref.invalidate(browseChannelsProvider);
});

/// 取消关注频道 Provider（非破坏性 unfollow，浏览页「退出」用）
final unfollowChannelProvider = FutureProvider.family<void, int>((
  ref,
  channelId,
) async {
  final service = ref.read(discourseServiceProvider);
  await service.unfollowChannel(channelId);
  ref.invalidate(chatChannelsProvider);
  ref.invalidate(browseChannelsProvider);
});

/// 标记所有聊天频道已读
final markAllChatChannelsReadProvider = FutureProvider<void>((ref) async {
  final service = ref.read(discourseServiceProvider);
  await service.markAllChannelsRead();
  ref.invalidate(chatChannelsProvider);
});
