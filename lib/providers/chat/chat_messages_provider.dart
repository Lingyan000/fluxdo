import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../models/chat/chat_channel.dart';
import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_user.dart';
import '../../services/discourse_cook_service.dart';
import '../../services/message_bus_service.dart';
import '../discourse_providers.dart';
import '../message_bus/message_bus_service_provider.dart';
import '../message_bus/topic_tracking_providers.dart';
import '../bookmark_sync_controller.dart';
import 'chat_channels_provider.dart';

/// 单频道消息窗口状态
class ChatMessagesState {
  /// 升序(旧→新);staged 消息追加在尾部
  final List<ChatMessage> messages;
  final bool canLoadMorePast;
  final bool canLoadMoreFuture;
  final bool loadingPast;
  final bool loadingFuture;

  /// 进入会话时的已读位,气泡流据此画"以下为新消息"分隔线
  final int? initialLastReadId;

  const ChatMessagesState({
    this.messages = const [],
    this.canLoadMorePast = false,
    this.canLoadMoreFuture = false,
    this.loadingPast = false,
    this.loadingFuture = false,
    this.initialLastReadId,
  });

  ChatMessagesState copyWith({
    List<ChatMessage>? messages,
    bool? canLoadMorePast,
    bool? canLoadMoreFuture,
    bool? loadingPast,
    bool? loadingFuture,
    int? initialLastReadId,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      canLoadMorePast: canLoadMorePast ?? this.canLoadMorePast,
      canLoadMoreFuture: canLoadMoreFuture ?? this.canLoadMoreFuture,
      loadingPast: loadingPast ?? this.loadingPast,
      loadingFuture: loadingFuture ?? this.loadingFuture,
      initialLastReadId: initialLastReadId ?? this.initialLastReadId,
    );
  }
}

/// 消息流定位:频道主流(threadId=null)或 thread 子流;
/// [targetMessageId] 非空时首屏围绕锚点加载(通知/链接直达)
typedef ChatStreamKey = ({int channelId, int? threadId, int? targetMessageId});

/// 单频道/单 thread 消息流:首屏定位未读 + 双向分页 + MessageBus 实时 + 乐观发送
class ChatMessagesNotifier extends AsyncNotifier<ChatMessagesState> {
  ChatMessagesNotifier(this.streamKey);

  static const _uuid = Uuid();

  final ChatStreamKey streamKey;

  int get channelId => streamKey.channelId;
  int? get threadId => streamKey.threadId;
  bool get isThread => threadId != null;

  MessageBusService? _bus;
  MessageBusCallback? _onChannelMessage;
  String? _channelBusName;

  /// 频道详情快照(删除事件按 can_moderate 判占位/移除)
  ChatChannel? _channel;

  /// 已上报的最高已读位(去抖:可视上报只增不减,避免重复请求)
  int _reportedReadId = 0;

  @override
  Future<ChatMessagesState> build() async {
    ref.watch(messageBusInitProvider);
    final service = ref.read(discourseServiceProvider);

    _teardown();
    ref.onDispose(_teardown);

    // 频道详情与消息并行:详情给 bus 起始位点 + membership 已读位
    final targetId = streamKey.targetMessageId;
    final results = await Future.wait([
      service.getChatChannel(channelId),
      isThread
          ? service.getChatThreadMessages(
              channelId,
              threadId!,
              targetMessageId: targetId,
              fetchFromLastRead: targetId == null,
            )
          : service.getChatMessages(
              channelId,
              targetMessageId: targetId,
              fetchFromLastRead: targetId == null,
            ),
    ]);
    final channel = results[0] as ChatChannel;
    _channel = channel;
    final page = results[1] as ChatMessagesResponse;

    final messages = [...page.messages]
      ..sort((a, b) => a.id.compareTo(b.id));

    _subscribe(channel);

    _reportedReadId = channel.currentUserMembership?.lastReadMessageId ?? 0;

    return ChatMessagesState(
      messages: messages,
      canLoadMorePast: page.canLoadMorePast,
      canLoadMoreFuture: page.canLoadMoreFuture,
      initialLastReadId:
          isThread ? null : channel.currentUserMembership?.lastReadMessageId,
    );
  }

  void _subscribe(ChatChannel channel) {
    final bus = ref.read(messageBusServiceProvider);
    _bus = bus;
    // thread 子流走 /chat/:id/thread/:tid 通道,与主流隔离
    _channelBusName = isThread
        ? '/chat/$channelId/thread/$threadId'
        : '/chat/$channelId';

    void onMessage(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final type = data['type'] as String?;
      switch (type) {
        case 'sent':
          _handleSent(data);
        case 'edit':
        case 'processed':
        case 'refresh':
        case 'restore':
          _handleUpsert(data);
        case 'delete':
          _handleDelete(data);
        case 'bulk_delete':
          _handleBulkDelete(data);
        case 'reaction':
          _handleReaction(data);
        case 'pin':
          _handlePin(data, pinned: true);
        case 'unpin':
          _handlePin(data, pinned: false);
        case 'thread_created':
        case 'update_thread_original_message':
          _handleThreadUpdate(data);
        default:
          debugPrint('[ChatMessages#$channelId] 未处理类型: $type');
      }
    }

    _onChannelMessage = onMessage;
    // thread 通道的起始位点服务端在 thread meta 里;这里用 -1(只收新)
    // ——thread 面板打开时首屏已拉全量,漏旧消息无害
    bus.subscribeWithMessageId(
      _channelBusName!,
      onMessage,
      isThread ? -1 : (channel.busLastIds.channelMessageBusLastId ?? -1),
    );
  }

  /// thread_created / 原消息 preview 更新:刷新主流里串首消息的回复数
  void _handleThreadUpdate(Map<String, dynamic> data) {
    if (isThread) return;
    final message = _parseMessage(data);
    if (message == null) return;
    _handleUpsertMessage(message);
  }

  void _teardown() {
    if (_bus != null && _onChannelMessage != null && _channelBusName != null) {
      _bus!.unsubscribe(_channelBusName!, _onChannelMessage);
    }
    _bus = null;
    _onChannelMessage = null;
    _channelBusName = null;
  }

  ChatMessage? _parseMessage(Map<String, dynamic> data) {
    final raw = data['chat_message'] as Map<String, dynamic>?;
    if (raw == null) return null;
    try {
      return ChatMessage.fromJson(raw, fallbackChannelId: channelId);
    } catch (e) {
      debugPrint('[ChatMessages#$channelId] 消息解析失败: $e');
      return null;
    }
  }

  void _handleSent(Map<String, dynamic> data) {
    final message = _parseMessage(data);
    if (message == null) return;
    // 主流上收到 thread 回复(threading 关闭时官方也发主通道):丢弃,
    // 回复只在 thread 面板里显示;thread_created 会另行刷新串首
    if (!isThread && message.threadId != null && data['type'] == 'sent') {
      // 例外:串首消息自身带 thread_id,但它已在主流(id 已存在),去重兜住
    }
    final stagedId = data['staged_id']?.toString();
    final current = state.value;
    if (current == null) return;

    final list = [...current.messages];
    // 乐观对账:自己发的消息广播回来带 staged_id,原地替换临时消息
    if (stagedId != null) {
      final index = list.indexWhere((m) => m.stagedId == stagedId);
      if (index >= 0) {
        list[index] = message;
        state = AsyncData(current.copyWith(messages: list));
        if (!isThread) _bumpChannelList(message);
        return;
      }
    }
    // 去重(积压回放可能与首屏拉取重叠)
    if (list.any((m) => m.id == message.id)) return;
    // 窗口不在最新页(往上翻历史后来了新消息)时丢弃,回底部会重新拉
    if (current.canLoadMoreFuture) return;
    list.add(message);
    state = AsyncData(current.copyWith(messages: list));
    if (!isThread) _bumpChannelList(message);
  }

  void _handleUpsert(Map<String, dynamic> data) {
    final message = _parseMessage(data);
    if (message == null) return;
    _handleUpsertMessage(message);
  }

  void _handleUpsertMessage(ChatMessage message) {
    final current = state.value;
    if (current == null) return;
    final list = [...current.messages];
    final index = list.indexWhere((m) => m.id == message.id);
    if (index < 0) return;
    final wasDeleted = list[index].isDeleted;
    list[index] = message;
    state = AsyncData(current.copyWith(messages: list));
    // 恢复消息(restore 广播)可能重新成为"最后一条"
    if (wasDeleted && !message.isDeleted) {
      _syncChannelListAfterDelete(list);
    }
  }

  /// 删除消息对本人可见性(官方 handleDeleteMessage 口径):
  /// staff / 可管理频道 / 消息作者 → 保留软删占位(可展开/恢复);
  /// 其余人直接移除(服务端拉取时也不会给他们返回已删消息)
  bool _canSeeDeleted(ChatMessage message) {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return false;
    if (user.admin || user.moderator) return true;
    if (_channel?.canModerate ?? false) return true;
    return message.user?.id == user.id;
  }

  void _handleDelete(Map<String, dynamic> data) {
    final deletedId = data['deleted_id'] as int?;
    if (deletedId == null) return;
    final current = state.value;
    if (current == null) return;
    final list = [...current.messages];
    final index = list.indexWhere((m) => m.id == deletedId);
    if (index < 0) return;
    if (_canSeeDeleted(list[index])) {
      list[index] = list[index].copyWith(deletedAt: DateTime.now());
    } else {
      list.removeAt(index);
    }
    state = AsyncData(current.copyWith(messages: list));
    _syncChannelListAfterDelete(list);
  }

  /// 删除/恢复后会话列表的"最后一条"预览可能指向已删消息,
  /// 用窗口内最新未删消息回填(官方列表不显示已删消息摘要)
  void _syncChannelListAfterDelete(List<ChatMessage> list) {
    if (isThread) return;
    final latestVisible = list.lastWhere(
      (m) => !m.isDeleted && !m.isStaged,
      orElse: () => list.isEmpty ? _placeholderMessage : list.last,
    );
    if (latestVisible.isDeleted || latestVisible.id == 0) return;
    _bumpChannelList(latestVisible);
  }

  static const _placeholderMessage = ChatMessage(
    id: 0,
    channelId: 0,
    message: '',
    cooked: '',
  );

  void _handleBulkDelete(Map<String, dynamic> data) {
    final ids = (data['deleted_ids'] as List<dynamic>? ?? [])
        .whereType<int>()
        .toSet();
    if (ids.isEmpty) return;
    final current = state.value;
    if (current == null) return;
    final now = DateTime.now();
    state = AsyncData(
      current.copyWith(
        messages: [
          for (final m in current.messages)
            if (!ids.contains(m.id))
              m
            else if (_canSeeDeleted(m))
              m.copyWith(deletedAt: now),
        ],
      ),
    );
    _syncChannelListAfterDelete(state.value?.messages ?? const []);
  }

  void _handleReaction(Map<String, dynamic> data) {
    final messageId = data['chat_message_id'] as int?;
    final emoji = data['emoji'] as String?;
    final action = data['action'] as String?;
    final userRaw = data['user'] as Map<String, dynamic>?;
    if (messageId == null || emoji == null || action == null) return;
    final current = state.value;
    if (current == null) return;
    final index = current.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;

    final currentUserId = ref.read(currentUserProvider).value?.id;
    final actingUserId = userRaw?['id'] as int?;
    final isSelf = actingUserId != null && actingUserId == currentUserId;

    final message = current.messages[index];
    final reactions = [...message.reactions];
    final rIndex = reactions.indexWhere((r) => r.emoji == emoji);
    if (action == 'add') {
      if (rIndex >= 0) {
        final r = reactions[rIndex];
        // 自己的 add 广播:本地乐观更新已落地(reacted=true),幂等跳过
        if (isSelf && r.reacted) return;
        reactions[rIndex] = ChatMessageReaction(
          emoji: emoji,
          count: r.count + 1,
          reacted: r.reacted || isSelf,
          users: r.users,
        );
      } else {
        reactions.add(
          ChatMessageReaction(emoji: emoji, count: 1, reacted: isSelf),
        );
      }
    } else if (rIndex >= 0) {
      final r = reactions[rIndex];
      // 自己的 remove 广播:本地已翻转(reacted=false),幂等跳过
      if (isSelf && !r.reacted) return;
      final newCount = r.count - 1;
      if (newCount <= 0) {
        reactions.removeAt(rIndex);
      } else {
        reactions[rIndex] = ChatMessageReaction(
          emoji: emoji,
          count: newCount,
          reacted: isSelf ? false : r.reacted,
          users: r.users,
        );
      }
    }
    final list = [...current.messages];
    list[index] = message.copyWith(reactions: reactions);
    state = AsyncData(current.copyWith(messages: list));
  }

  /// 新消息同步到会话列表(最后一条 + 重排)
  void _bumpChannelList(ChatMessage message) {
    ref.read(chatChannelsProvider.notifier).bumpChannel(
      message.channelId,
      update: (ch) => ch.copyWith(lastMessage: message),
    );
  }

  // ========== 分页 ==========

  /// 分页拉取:按流身份分发到频道/thread 端点
  /// [direction] 为 null 时是"锚点窗口"用法:服务端取 [targetMessageId]
  /// 前后各半页(见 _chat.dart 的三种用法说明)
  Future<ChatMessagesResponse> _fetchPage({
    String? direction,
    required int targetMessageId,
  }) {
    final service = ref.read(discourseServiceProvider);
    return isThread
        ? service.getChatThreadMessages(
            channelId,
            threadId!,
            direction: direction,
            targetMessageId: targetMessageId,
          )
        : service.getChatMessages(
            channelId,
            direction: direction,
            targetMessageId: targetMessageId,
          );
  }

  Future<void> loadPast() async {
    final current = state.value;
    if (current == null || current.loadingPast || !current.canLoadMorePast) {
      return;
    }
    // 游标取最老的非 staged 消息(staged 消息 id 是本地占位,不能作游标)
    final anchor = current.messages
        .where((m) => !m.isStaged)
        .firstOrNull;
    if (anchor == null) return;
    state = AsyncData(current.copyWith(loadingPast: true));
    try {
      final page = await _fetchPage(
        direction: 'past',
        targetMessageId: anchor.id,
      );
      final fresh = state.value;
      if (fresh == null) return;
      final existing = fresh.messages.map((m) => m.id).toSet();
      final older = page.messages.where((m) => !existing.contains(m.id)).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      state = AsyncData(
        fresh.copyWith(
          messages: [...older, ...fresh.messages],
          canLoadMorePast: page.canLoadMorePast,
          loadingPast: false,
        ),
      );
    } catch (e) {
      debugPrint('[ChatMessages#$channelId] loadPast 失败: $e');
      final fresh = state.value;
      if (fresh != null) {
        state = AsyncData(fresh.copyWith(loadingPast: false));
      }
    }
  }

  Future<void> loadFuture() async {
    final current = state.value;
    if (current == null ||
        current.loadingFuture ||
        !current.canLoadMoreFuture) {
      return;
    }
    final anchor = current.messages
        .where((m) => !m.isStaged)
        .lastOrNull;
    if (anchor == null) return;
    state = AsyncData(current.copyWith(loadingFuture: true));
    try {
      final page = await _fetchPage(
        direction: 'future',
        targetMessageId: anchor.id,
      );
      final fresh = state.value;
      if (fresh == null) return;
      final existing = fresh.messages.map((m) => m.id).toSet();
      final newer = page.messages.where((m) => !existing.contains(m.id)).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      state = AsyncData(
        fresh.copyWith(
          messages: [...fresh.messages, ...newer],
          canLoadMoreFuture: page.canLoadMoreFuture,
          loadingFuture: false,
        ),
      );
    } catch (e) {
      debugPrint('[ChatMessages#$channelId] loadFuture 失败: $e');
      final fresh = state.value;
      if (fresh != null) {
        state = AsyncData(fresh.copyWith(loadingFuture: false));
      }
    }
  }

  /// 原地把消息窗口换成以 [messageId] 为中心的一页(跳转定位用)
  ///
  /// 不换 provider key:key 里带锚点会造出全新 notifier 实例,连带
  /// 重订阅 MessageBus、重拉频道详情、重置已读位、丢弃未发出的 staged
  /// 消息 —— 跳转不该付这些代价。目标已在窗口内时零成本返回。
  ///
  /// 返回 true = 目标在新窗口内(调用方可以去测几何了)。
  /// 失败时抛给调用方,旧窗口保持不动。
  Future<bool> loadWindowAround(int messageId) async {
    final current = state.value;
    if (current == null) return false;
    if (current.messages.any((m) => m.id == messageId)) return true;

    final page = await _fetchPage(targetMessageId: messageId);
    final fresh = state.value;
    if (fresh == null) return false;
    // 整体替换而非并集:锚点窗口与旧窗口之间可能隔着大段未加载消息,
    // 拼起来会得到一条中间有空洞的假连续消息流
    final messages = [...page.messages]..sort((a, b) => a.id.compareTo(b.id));
    // 未发出的乐观消息不属于任何服务端窗口,跟到新窗口尾部免得丢草稿
    final staged = fresh.messages.where((m) => m.isStaged);
    state = AsyncData(
      fresh.copyWith(
        messages: [...messages, ...staged],
        canLoadMorePast: page.canLoadMorePast,
        canLoadMoreFuture: page.canLoadMoreFuture,
        // 窗口整体换掉,原窗口的分页在途标志不再适用
        loadingPast: false,
        loadingFuture: false,
      ),
    );
    return messages.any((m) => m.id == messageId);
  }

  // ========== 发送(乐观) ==========

  /// 发送消息:本地 cook 立即上屏(staged),服务端 sent 广播对账替换
  Future<void> send(
    String raw, {
    int? inReplyToId,
    List<int> uploadIds = const [],
  }) async {
    final text = raw.trim();
    if (text.isEmpty && uploadIds.isEmpty) return;
    final current = state.value;
    if (current == null) return;

    final user = ref.read(currentUserProvider).value;
    final stagedId = _uuid.v4();

    String cooked;
    try {
      final result = await DiscourseCookService()
          .cook(text)
          .timeout(const Duration(seconds: 2));
      cooked = result ?? '<p>${const HtmlEscape().convert(text)}</p>';
    } catch (_) {
      // cook 超时/失败降级为纯文本段落,不阻塞发送
      cooked = '<p>${const HtmlEscape().convert(text)}</p>';
    }

    final staged = ChatMessage(
      // 本地占位 id 用负 hash,不与服务端正 id 冲突,替换靠 stagedId
      id: -stagedId.hashCode.abs(),
      channelId: channelId,
      message: text,
      cooked: cooked,
      createdAt: DateTime.now(),
      user: user == null
          ? null
          : ChatUser(
              id: user.id,
              username: user.username,
              name: user.name,
              avatarTemplate: user.avatarTemplate,
            ),
      stagedId: stagedId,
      sendState: ChatMessageSendState.staged,
    );

    final afterStage = state.value;
    if (afterStage == null) return;
    state = AsyncData(
      afterStage.copyWith(messages: [...afterStage.messages, staged]),
    );

    try {
      final service = ref.read(discourseServiceProvider);
      final messageId = await service.sendChatMessage(
        channelId,
        message: text,
        stagedId: stagedId,
        inReplyToId: inReplyToId,
        threadId: threadId,
        uploadIds: uploadIds.isEmpty ? null : uploadIds,
      );
      // 正常靠 MessageBus sent 广播带 staged_id 回来替换;但回复被服务端
      // 归入 thread 时广播只发子通道,主流对账不到——10s 兜底:直接用
      // REST 返回的 message_id 就地转正,避免永久转圈
      _scheduleStagedFallback(stagedId, messageId);
    } catch (e) {
      debugPrint('[ChatMessages#$channelId] 发送失败: $e');
      final fresh = state.value;
      if (fresh == null) return;
      final list = [...fresh.messages];
      final index = list.indexWhere((m) => m.stagedId == stagedId);
      if (index >= 0) {
        list[index] = list[index].copyWith(
          sendState: ChatMessageSendState.failed,
        );
        state = AsyncData(fresh.copyWith(messages: list));
      }
    }
  }

  /// staged 兜底转正:10s 内没等到 sent 广播(如回复被归入 thread,
  /// 广播只发子通道),用 REST 返回的 message_id 就地把临时消息转正
  void _scheduleStagedFallback(String stagedId, int? messageId) {
    if (messageId == null) return;
    Timer(const Duration(seconds: 10), () {
      final current = state.value;
      if (current == null) return;
      final index = current.messages.indexWhere(
        (m) => m.stagedId == stagedId && m.isStaged,
      );
      if (index < 0) return; // 广播已对账,无事
      final list = [...current.messages];
      list[index] = list[index].copyWith(
        id: messageId,
        sendState: ChatMessageSendState.sent,
      );
      state = AsyncData(current.copyWith(messages: list));
    });
  }

  /// 重发失败消息
  Future<void> resend(String stagedId) async {
    final current = state.value;
    if (current == null) return;
    final index = current.messages.indexWhere((m) => m.stagedId == stagedId);
    if (index < 0) return;
    final message = current.messages[index];
    if (message.sendState != ChatMessageSendState.failed) return;

    final list = [...current.messages];
    list[index] = message.copyWith(sendState: ChatMessageSendState.staged);
    state = AsyncData(current.copyWith(messages: list));

    try {
      final service = ref.read(discourseServiceProvider);
      await service.sendChatMessage(
        channelId,
        message: message.message,
        stagedId: stagedId,
        threadId: threadId,
      );
    } catch (e) {
      final fresh = state.value;
      if (fresh == null) return;
      final freshList = [...fresh.messages];
      final freshIndex = freshList.indexWhere((m) => m.stagedId == stagedId);
      if (freshIndex >= 0) {
        freshList[freshIndex] = freshList[freshIndex].copyWith(
          sendState: ChatMessageSendState.failed,
        );
        state = AsyncData(fresh.copyWith(messages: freshList));
      }
    }
  }

  /// 移除失败的 staged 消息
  void removeStaged(String stagedId) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        messages: current.messages
            .where((m) => m.stagedId != stagedId)
            .toList(),
      ),
    );
  }

  // ========== 已读回执 ==========

  /// 可视消息上报已读(只增不减,服务端同样单调)
  Future<void> markReadUpTo(int messageId) async {
    if (messageId <= _reportedReadId) return;
    _reportedReadId = messageId;
    try {
      final service = ref.read(discourseServiceProvider);
      if (isThread) {
        await service.markChatThreadRead(channelId, threadId!);
      } else {
        await service.markChatChannelRead(channelId, messageId: messageId);
      }
    } catch (e) {
      debugPrint('[ChatMessages#$channelId] 已读上报失败: $e');
    }
  }

  // ========== 消息动作(reaction/编辑/删除) ==========

  /// 切换表情回应:本地乐观翻转,请求失败回滚
  /// (成功后的广播对同一 emoji 是幂等更新,不会二次跳变)
  Future<void> toggleReaction(int messageId, String emoji) async {
    final current = state.value;
    if (current == null) return;
    final index = current.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final message = current.messages[index];
    final existing = message.reactions
        .where((r) => r.emoji == emoji)
        .firstOrNull;
    final isRemove = existing?.reacted ?? false;

    _applyLocalReaction(messageId, emoji, add: !isRemove);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.reactChatMessage(
        channelId,
        messageId,
        emoji: emoji,
        reactAction: isRemove ? 'remove' : 'add',
      );
    } catch (e) {
      debugPrint('[ChatMessages#$channelId] reaction 失败回滚: $e');
      _applyLocalReaction(messageId, emoji, add: isRemove);
    }
  }

  /// 本地 reaction 翻转(乐观/回滚共用);只动 reacted 与 count
  void _applyLocalReaction(int messageId, String emoji, {required bool add}) {
    final current = state.value;
    if (current == null) return;
    final index = current.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final message = current.messages[index];
    final reactions = [...message.reactions];
    final rIndex = reactions.indexWhere((r) => r.emoji == emoji);
    if (add) {
      if (rIndex >= 0) {
        final r = reactions[rIndex];
        if (r.reacted) return; // 已是目标态(广播先到),幂等
        reactions[rIndex] = ChatMessageReaction(
          emoji: emoji,
          count: r.count + 1,
          reacted: true,
          users: r.users,
        );
      } else {
        reactions.add(
          ChatMessageReaction(emoji: emoji, count: 1, reacted: true),
        );
      }
    } else {
      if (rIndex < 0) return;
      final r = reactions[rIndex];
      if (!r.reacted) return;
      final newCount = r.count - 1;
      if (newCount <= 0) {
        reactions.removeAt(rIndex);
      } else {
        reactions[rIndex] = ChatMessageReaction(
          emoji: emoji,
          count: newCount,
          reacted: false,
          users: r.users,
        );
      }
    }
    final list = [...current.messages];
    list[index] = message.copyWith(reactions: reactions);
    state = AsyncData(current.copyWith(messages: list));
  }

  /// 编辑消息:请求成功即本地更新 raw(cooked 等 edit 广播覆盖)
  Future<void> edit(int messageId, String newRaw) async {
    final text = newRaw.trim();
    if (text.isEmpty) return;
    final service = ref.read(discourseServiceProvider);
    await service.editChatMessage(channelId, messageId, message: text);
    final current = state.value;
    if (current == null) return;
    final index = current.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final list = [...current.messages];
    list[index] = list[index].copyWith(message: text, edited: true);
    state = AsyncData(current.copyWith(messages: list));
  }

  /// 删除消息(软删占位由 delete 广播落地;这里先行本地标记)
  Future<void> delete(int messageId) async {
    final service = ref.read(discourseServiceProvider);
    await service.deleteChatMessage(channelId, messageId);
    _handleDelete({'deleted_id': messageId});
  }

  /// 恢复自己删除的消息
  Future<void> restore(int messageId) async {
    final service = ref.read(discourseServiceProvider);
    await service.restoreChatMessage(channelId, messageId);
  }

  /// pin/unpin 广播:更新消息 pinned 位(官方 handlePinMessage 口径)
  void _handlePin(Map<String, dynamic> data, {required bool pinned}) {
    final messageId = data['chat_message_id'] as int?;
    if (messageId == null) return;
    final current = state.value;
    if (current == null) return;
    final index = current.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final list = [...current.messages];
    list[index] = list[index].copyWith(pinned: pinned);
    state = AsyncData(current.copyWith(messages: list));
  }

  /// 置顶/取消置顶(广播回来 _handlePin 落地;这里先行本地乐观标记)
  Future<void> togglePin(int messageId, {required bool pin}) async {
    final service = ref.read(discourseServiceProvider);
    if (pin) {
      await service.pinChatMessage(channelId, messageId);
    } else {
      await service.unpinChatMessage(channelId, messageId);
    }
    _handlePin({'chat_message_id': messageId}, pinned: pin);
  }

  /// 收藏/取消收藏(无广播事件,本地乐观落地)
  Future<void> toggleBookmark(int messageId) async {
    final current = state.value;
    if (current == null) return;
    final index = current.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final message = current.messages[index];
    final service = ref.read(discourseServiceProvider);

    void apply(ChatMessageBookmark? bookmark) {
      final latest = state.value;
      if (latest == null) return;
      final i = latest.messages.indexWhere((m) => m.id == messageId);
      if (i < 0) return;
      final list = [...latest.messages];
      list[i] = list[i].copyWith(bookmark: bookmark);
      state = AsyncData(latest.copyWith(messages: list));
    }

    final existing = message.bookmark;
    if (existing != null) {
      await service.deleteBookmark(existing.id);
      apply(null);
      // 写穿透:书签列表 Hive 缓存同步删除(全入口统一收口)
      await ref
          .read(bookmarkSyncControllerProvider.notifier)
          .purgeLocal(existing.id);
    } else {
      final id = await service.bookmarkChatMessage(messageId);
      apply(ChatMessageBookmark(id: id));
      // 写穿透:静默拉书签列表第一页,新书签立刻进本地缓存
      unawaited(
        ref.read(bookmarkSyncControllerProvider.notifier).pullFirstPage(),
      );
    }
  }
}

final chatMessagesProvider = AsyncNotifierProvider.family
    .autoDispose<ChatMessagesNotifier, ChatMessagesState, ChatStreamKey>(
      ChatMessagesNotifier.new,
    );
