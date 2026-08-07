import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat/chat_channel.dart';
import '../../models/chat/chat_message.dart';
import '../../services/message_bus_service.dart';
import '../../storage/chat_cache_dao.dart';
import '../discourse_providers.dart';
import '../message_bus/message_bus_service_provider.dart';
import '../message_bus/topic_tracking_providers.dart';

/// 会话列表状态:公共频道 + DM 频道 + 每频道未读
class ChatChannelsState {
  final List<ChatChannel> publicChannels;
  final List<ChatChannel> directMessageChannels;
  final Map<int, ChatChannelTracking> tracking;

  const ChatChannelsState({
    this.publicChannels = const [],
    this.directMessageChannels = const [],
    this.tracking = const {},
  });

  /// 底栏/入口徽章总数(对齐官方 chat-channel-unread-indicator 口径):
  /// DM = unread + mention;公共频道 = 仅 mention(普通闲聊不该轰炸
  /// 全局红点);muted 频道不计。
  int get totalUnread {
    var sum = 0;
    for (final ch in directMessageChannels) {
      if (ch.currentUserMembership?.muted == true) continue;
      final t = tracking[ch.id];
      if (t != null) sum += t.unreadCount + t.mentionCount;
    }
    for (final ch in publicChannels) {
      if (ch.currentUserMembership?.muted == true) continue;
      sum += tracking[ch.id]?.mentionCount ?? 0;
    }
    return sum;
  }

  ChatChannelsState copyWith({
    List<ChatChannel>? publicChannels,
    List<ChatChannel>? directMessageChannels,
    Map<int, ChatChannelTracking>? tracking,
  }) {
    return ChatChannelsState(
      publicChannels: publicChannels ?? this.publicChannels,
      directMessageChannels:
          directMessageChannels ?? this.directMessageChannels,
      tracking: tracking ?? this.tracking,
    );
  }
}

/// 会话列表单一数据源
///
/// 首屏 GET /chat/api/me/channels;之后靠 MessageBus 增量:
/// - /chat/new-channel                   新 DM/被拉群 → 插入列表并补订阅
/// - /chat/user-tracking-state/:userId   已读同步(自己读/发时服务端才推)
/// - /chat/:id/new-messages(逐频道)     新消息 → 最后一条+重排+本地未读+1
///   (与官方 web 一致;MessageBus 所有订阅共享同一 poll,逐频道无额外
///   网络成本。未读递增只能靠它:tracking 通道只在已读位变化时推送。)
class ChatChannelsNotifier extends AsyncNotifier<ChatChannelsState> {
  MessageBusService? _bus;
  MessageBusCallback? _onNewChannel;
  MessageBusCallback? _onTrackingState;
  MessageBusCallback? _onChannelEdits;

  /// channelId -> new-messages 回调(动态增删:新会话进来要补订阅)
  final Map<int, MessageBusCallback> _newMessagesCallbacks = {};
  static final ChatCacheDao _cacheDao = ChatCacheDao();

  @override
  Future<ChatChannelsState> build() async {
    ref.watch(messageBusInitProvider);
    final user = ref.watch(currentUserProvider).value;
    final service = ref.read(discourseServiceProvider);

    _teardown();
    ref.onDispose(_teardown);

    if (user == null) return const ChatChannelsState();

    // 冷启:先出缓存快照(损坏/无缓存静默跳过),网络返回后整体覆盖
    if (state.value == null || state.value!.directMessageChannels.isEmpty) {
      try {
        final snapshot = await _cacheDao.readSnapshot(user.username);
        if (snapshot != null && state.value == null) {
          state = AsyncData(
            ChatChannelsState(
              publicChannels: _sorted(
                snapshot.publicChannels.map(ChatChannel.fromJson).toList(),
              ),
              directMessageChannels: _sorted(
                snapshot.channels.map(ChatChannel.fromJson).toList(),
              ),
              tracking: {
                for (final entry in snapshot.tracking.entries)
                  if (int.tryParse(entry.key) != null &&
                      entry.value is Map<String, dynamic>)
                    int.parse(entry.key): ChatChannelTracking.fromJson(
                      entry.value as Map<String, dynamic>,
                    ),
              },
            ),
          );
        }
      } catch (e) {
        debugPrint('[ChatChannels] 缓存读取失败: $e');
      }
    }

    final Map<String, dynamic> rawResponse;
    try {
      rawResponse = await service.getMyChatChannelsRaw();
    } catch (e) {
      // 网络失败但缓存已上屏:保留缓存态可用,不让错误盖掉列表
      final cached = state.value;
      if (cached != null && cached.directMessageChannels.isNotEmpty) {
        debugPrint('[ChatChannels] 刷新失败,保留缓存: $e');
        return cached;
      }
      rethrow;
    }
    final response = MyChatChannelsResponse.fromJson(rawResponse);
    // 有实际消息的会话按最后消息时间倒序;空会话沉底
    final channels = _sorted(response.directMessageChannels);
    final publicChannels = _sorted(response.publicChannels);

    // 落盘快照(fire-and-forget,失败不影响主流程)
    unawaited(
      _cacheDao
          .writeSnapshot(
            user.username,
            channels: (rawResponse['direct_message_channels']
                        as List<dynamic>? ??
                    [])
                .whereType<Map<String, dynamic>>()
                .toList(),
            publicChannels:
                (rawResponse['public_channels'] as List<dynamic>? ?? [])
                    .whereType<Map<String, dynamic>>()
                    .toList(),
            tracking:
                (rawResponse['tracking']
                        as Map<String, dynamic>?)?['channel_tracking']
                    as Map<String, dynamic>? ??
                {},
          )
          .catchError((Object e) {
            debugPrint('[ChatChannels] 缓存写入失败: $e');
          }),
    );

    final bus = ref.read(messageBusServiceProvider);
    _bus = bus;

    void onNewChannel(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final channelData = data['channel'] as Map<String, dynamic>? ?? data;
      try {
        final channel = ChatChannel.fromJson(channelData);
        if (!channel.isDirectMessage) return;
        upsertChannel(channel);
        // 新会话补订阅 new-messages,否则它的后续消息不驱动列表
        _subscribeNewMessages(channel);
      } catch (e) {
        debugPrint('[ChatChannels] new-channel 解析失败: $e');
      }
    }

    void onTrackingState(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final channelId = data['channel_id'] as int?;
      if (channelId == null) return;
      // thread 维度的 tracking 更新不动频道未读
      if (data['thread_id'] != null) return;
      final unread = data['unread_count'] as int?;
      final mention = data['mention_count'] as int?;
      if (unread == null && mention == null) return;
      _updateTracking(
        channelId,
        ChatChannelTracking(
          unreadCount: unread ?? 0,
          mentionCount: mention ?? 0,
        ),
      );
    }

    // 频道编辑广播(改名/描述/slug;注意不含 threading_enabled,
    // threading 本地生效靠 patchChannel 乐观更新)
    void onChannelEdits(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final channelId = data['chat_channel_id'] as int?;
      if (channelId == null) return;
      bumpChannel(
        channelId,
        update: (ch) => ch.copyWith(
          title: data['name'] as String?,
          description: data['description'] as String?,
          slug: data['slug'] as String?,
        ),
      );
    }

    _onNewChannel = onNewChannel;
    _onTrackingState = onTrackingState;
    _onChannelEdits = onChannelEdits;
    bus.subscribeWithMessageId(
      '/chat/channel-edits',
      onChannelEdits,
      response.globalBusLastIds['channel_edits'] ?? -1,
    );
    // 起始位点来自 me/channels 的 meta,避免订阅瞬间漏消息/回放积压
    bus.subscribeWithMessageId(
      '/chat/new-channel',
      onNewChannel,
      response.globalBusLastIds['new_channel'] ?? -1,
    );
    bus.subscribeWithMessageId(
      '/chat/user-tracking-state/${user.id}',
      onTrackingState,
      response.globalBusLastIds['user_tracking_state'] ?? -1,
    );

    // 逐频道订阅 new-messages:列表的"最后一条+未读+排序"实时化
    // (公共频道同样订阅——它们也在列表里)
    for (final channel in [...channels, ...publicChannels]) {
      _subscribeNewMessages(channel);
    }

    return ChatChannelsState(
      publicChannels: publicChannels,
      directMessageChannels: channels,
      tracking: response.channelTracking,
    );
  }

  /// 订阅某频道的 new-messages 通道(幂等:已订阅的跳过)
  ///
  /// payload(publisher.rb publish_new!):
  /// { type: "channel"|"thread", channel_id, thread_id, message: {完整序列化} }
  void _subscribeNewMessages(ChatChannel channel) {
    final bus = _bus;
    if (bus == null) return;
    if (_newMessagesCallbacks.containsKey(channel.id)) return;

    void onNewMessage(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      // thread 内回复不动频道级"最后一条"(与官方列表语义一致)
      if (data['type'] != 'channel') return;
      final channelId = data['channel_id'] as int? ?? channel.id;
      final messageRaw = data['message'] as Map<String, dynamic>?;
      if (messageRaw == null) return;
      try {
        final chatMessage = ChatMessage.fromJson(
          messageRaw,
          fallbackChannelId: channelId,
        );
        _applyIncomingMessage(channelId, chatMessage);
      } catch (e) {
        debugPrint('[ChatChannels] new-messages 解析失败: $e');
      }
    }

    _newMessagesCallbacks[channel.id] = onNewMessage;
    bus.subscribeWithMessageId(
      '/chat/${channel.id}/new-messages',
      onNewMessage,
      channel.busLastIds.newMessages ?? -1,
    );
  }

  /// 频道来新消息:更新最后一条+重排;非自己发的本地未读+1
  /// (真实未读数以 user-tracking-state 推送为准,这里是即时反馈)
  void _applyIncomingMessage(int channelId, ChatMessage message) {
    final current = state.value;
    if (current == null) return;

    final currentUserId = ref.read(currentUserProvider).value?.id;
    final isSelf =
        currentUserId != null && message.user?.id == currentUserId;
    var tracking = current.tracking;
    if (!isSelf) {
      final old = tracking[channelId] ?? const ChatChannelTracking();
      tracking = {
        ...tracking,
        channelId: ChatChannelTracking(
          unreadCount: old.unreadCount + 1,
          mentionCount: old.mentionCount,
        ),
      };
    }

    // 频道可能在 DM 或公共列表任意一边
    final dms = [...current.directMessageChannels];
    final dmIndex = dms.indexWhere((c) => c.id == channelId);
    if (dmIndex >= 0) {
      dms[dmIndex] = dms[dmIndex].copyWith(lastMessage: message);
      state = AsyncData(
        current.copyWith(
          directMessageChannels: _sorted(dms),
          tracking: tracking,
        ),
      );
      return;
    }
    final publics = [...current.publicChannels];
    final pubIndex = publics.indexWhere((c) => c.id == channelId);
    if (pubIndex < 0) return;
    publics[pubIndex] = publics[pubIndex].copyWith(lastMessage: message);
    state = AsyncData(
      current.copyWith(publicChannels: _sorted(publics), tracking: tracking),
    );
  }

  void _teardown() {
    final bus = _bus;
    if (bus == null) return;
    if (_onNewChannel != null) {
      bus.unsubscribe('/chat/new-channel', _onNewChannel);
    }
    if (_onTrackingState != null) {
      final user = ref.read(currentUserProvider).value;
      if (user != null) {
        bus.unsubscribe('/chat/user-tracking-state/${user.id}', _onTrackingState);
      }
    }
    if (_onChannelEdits != null) {
      bus.unsubscribe('/chat/channel-edits', _onChannelEdits);
      _onChannelEdits = null;
    }
    for (final entry in _newMessagesCallbacks.entries) {
      bus.unsubscribe('/chat/${entry.key}/new-messages', entry.value);
    }
    _newMessagesCallbacks.clear();
    _bus = null;
    _onNewChannel = null;
    _onTrackingState = null;
  }

  static List<ChatChannel> _sorted(List<ChatChannel> channels) {
    final list = [...channels];
    list.sort((a, b) {
      // 收藏区置顶(区内仍按时间)
      final aStar = a.currentUserMembership?.starred == true;
      final bStar = b.currentUserMembership?.starred == true;
      if (aStar != bStar) return aStar ? -1 : 1;
      final at = a.lastMessage?.createdAt;
      final bt = b.lastMessage?.createdAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return list;
  }

  void _updateTracking(int channelId, ChatChannelTracking tracking) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(tracking: {...current.tracking, channelId: tracking}),
    );
  }

  /// 新会话插入/已有会话更新(new-channel 推送、本地建 DM 后)
  void upsertChannel(ChatChannel channel) {
    final current = state.value;
    if (current == null) return;
    final list = [...current.directMessageChannels];
    final index = list.indexWhere((c) => c.id == channel.id);
    if (index >= 0) {
      list[index] = channel;
    } else {
      list.add(channel);
    }
    state = AsyncData(
      current.copyWith(directMessageChannels: _sorted(list)),
    );
  }

  /// 频道来了新消息:更新最后一条并按时间重排(消息层调用;双列表通吃)
  void bumpChannel(int channelId, {required ChatChannel Function(ChatChannel) update}) {
    final current = state.value;
    if (current == null) return;
    final dms = [...current.directMessageChannels];
    final dmIndex = dms.indexWhere((c) => c.id == channelId);
    if (dmIndex >= 0) {
      dms[dmIndex] = update(dms[dmIndex]);
      state = AsyncData(current.copyWith(directMessageChannels: _sorted(dms)));
      return;
    }
    final publics = [...current.publicChannels];
    final pubIndex = publics.indexWhere((c) => c.id == channelId);
    if (pubIndex < 0) return;
    publics[pubIndex] = update(publics[pubIndex]);
    state = AsyncData(current.copyWith(publicChannels: _sorted(publics)));
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final chatChannelsProvider =
    AsyncNotifierProvider<ChatChannelsNotifier, ChatChannelsState>(
      ChatChannelsNotifier.new,
    );

/// DM 未读总数(入口徽章用,单独 select 减少 rebuild)
final chatTotalUnreadProvider = Provider<int>((ref) {
  return ref.watch(chatChannelsProvider).value?.totalUnread ?? 0;
});
