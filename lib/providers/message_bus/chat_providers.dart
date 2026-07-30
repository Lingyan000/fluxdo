import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/chat/chat_channel.dart';
import '../../models/chat/chat_message.dart';
import '../../services/local_notification_service.dart';
import '../../services/message_bus_service.dart';
import '../../utils/blocked_user_filter.dart';
import '../core_providers.dart';
import '../preferences_provider.dart';
import 'message_bus_service_provider.dart';
import 'topic_tracking_providers.dart';

/// 当前正打开的聊天详情页频道 id(没打开则为 null)。用于解决"频道详情页
/// 收到新消息本地清零未读"和"频道列表订阅收到同一条消息本地未读+1"这
/// 两条独立订阅之间的竞态——谁的回调后跑到,未读数就以谁为准,顺序不
/// 确定时会出现"消息明明读了,左侧红点却还在"。详情页 initState/dispose
/// 里维护这个值,[ChatChannelListNotifier.applyIncomingMessage] 据此跳过
/// 正在被查看的频道的未读自增。
final activeChatChannelIdProvider = StateProvider<int?>((ref) => null);

/// DM 频道列表(仅 Chat 插件的 Direct Message 频道,不含公开频道)。
/// autoDispose:未读徽标常驻监听,页面/徽标都不在时自动释放。
class ChatChannelListNotifier extends AsyncNotifier<List<ChatChannel>> {
  @override
  Future<List<ChatChannel>> build() async {
    final service = ref.read(discourseServiceProvider);
    return service.fetchChatChannels();
  }

  Future<void> refresh() async {
    final service = ref.read(discourseServiceProvider);
    state = await AsyncValue.guard(() => service.fetchChatChannels());
  }

  /// 对某个频道就地替换(找不到就不动),所有本地增量更新的公共骨架。
  void _updateChannel(
    int channelId,
    ChatChannel Function(ChatChannel old) transform,
  ) {
    state.whenData((channels) {
      final index = channels.indexWhere((c) => c.id == channelId);
      if (index == -1) return;
      final next = List<ChatChannel>.from(channels);
      next[index] = transform(channels[index]);
      state = AsyncValue.data(next);
    });
  }

  /// 本地增量更新某频道未读数(来自 user-tracking-state 推送),
  /// 避免每条消息都整表重拉。
  void applyUnreadUpdate(
    int channelId, {
    int? unreadCount,
    int? unreadMentions,
  }) {
    _updateChannel(
      channelId,
      (old) => old.copyWith(
        membership: old.membership.copyWith(
          unreadCount: unreadCount,
          unreadMentions: unreadMentions,
        ),
      ),
    );
  }

  /// 本地清零某频道未读数(打开详情页读到最新消息后调用,
  /// 避免等下一次整表刷新才把徽标降下去)。
  void markRead(int channelId) {
    applyUnreadUpdate(channelId, unreadCount: 0, unreadMentions: 0);
  }

  /// 本地切换某频道收藏状态(服务端调用已在别处完成,这里只同步 UI)。
  void applyStarred(int channelId, bool starred) {
    _updateChannel(
      channelId,
      (old) =>
          old.copyWith(membership: old.membership.copyWith(starred: starred)),
    );
  }

  /// 本地切换某频道静音状态(服务端调用已在别处完成,这里只同步 UI)。
  void applyMuted(int channelId, bool muted) {
    _updateChannel(
      channelId,
      (old) => old.copyWith(membership: old.membership.copyWith(muted: muted)),
    );
  }

  /// 本地更新某频道通知级别(服务端调用已在别处完成,这里只同步 UI)。
  void applyNotificationLevel(int channelId, int level) {
    _updateChannel(
      channelId,
      (old) => old.copyWith(
        membership: old.membership.copyWith(notificationLevel: level),
      ),
    );
  }

  /// 本地更新某频道消息串开关(服务端调用已在别处完成)。
  void applyThreadingEnabled(int channelId, bool enabled) {
    _updateChannel(channelId, (old) => old.copyWith(threadingEnabled: enabled));
  }

  /// 本地更新群聊名称/缩略名/emoji 图标(服务端调用已在别处完成)。
  void applyChannelInfo(int channelId, {String? title, String? slug, String? emoji}) {
    _updateChannel(
      channelId,
      (old) => old.copyWith(title: title, slug: slug, emoji: emoji),
    );
  }

  /// 离开频道后从本地列表移除(服务端调用已在别处完成)。
  void removeChannel(int channelId) {
    state.whenData((channels) {
      state = AsyncValue.data(
        channels.where((c) => c.id != channelId).toList(),
      );
    });
  }

  /// 列表页开着时收到某频道的新消息(来自 [ChatTrackingChannelNotifier] 对
  /// 每个已加载频道的 new-messages 订阅):更新最后一条消息预览,自己发的
  /// 不计未读,别人发的本地未读 +1(列表页本身没有数字角标,但每行的
  /// 加粗/小圆点状态还是要跟着变,不然看着像没收到消息)。
  void applyIncomingMessage(
    int channelId,
    ChatMessage message, {
    required bool isOwnMessage,
  }) {
    state.whenData((channels) {
      final index = channels.indexWhere((c) => c.id == channelId);
      if (index == -1) return;
      // 详情页正开着这个频道时,消息会被详情页自己的订阅立刻标记已读,
      // 这里不再自增,避免跟那边的清零动作产生竞态导致红点消不掉。
      final isActivelyViewed = ref.read(activeChatChannelIdProvider) == channelId;
      final updated = channels[index].copyWith(
        lastMessage: ChatLastMessage(
          id: message.id,
          message: message.message,
          createdAt: message.createdAt,
        ),
        membership: channels[index].membership.copyWith(
          unreadCount: (isOwnMessage || isActivelyViewed)
              ? (isActivelyViewed ? 0 : channels[index].membership.unreadCount)
              : channels[index].membership.unreadCount + 1,
        ),
      );
      // 有新消息就把这个频道挪到列表最前——之前只在原位置替换,列表顺序
      // 一直停在首次拉取时的样子,看着像没刷新。
      final next = List<ChatChannel>.from(channels)..removeAt(index);
      next.insert(0, updated);
      state = AsyncValue.data(next);
    });
  }

  /// 本地更新某频道最后一条消息的预览文字(来自根频道的 processed/edit/
  /// delete 事件)——之前只订阅了 new-messages,编辑/撤回/图片处理完成
  /// 这几种事件完全没接,预览文字会一直停在旧内容上。
  void applyLastMessagePreview(int channelId, int messageId, String? text) {
    _updateChannel(channelId, (old) {
      if (old.lastMessage?.id != messageId) return old;
      return old.copyWith(
        lastMessage: ChatLastMessage(
          id: messageId,
          message: text,
          createdAt: old.lastMessage?.createdAt,
        ),
      );
    });
  }
}

final chatChannelListProvider =
    AsyncNotifierProvider.autoDispose<
      ChatChannelListNotifier,
      List<ChatChannel>
    >(ChatChannelListNotifier.new);

/// DM 频道列表页的追踪监听器:
/// - `/chat/new-channel`:感知到新DM频道到达,整表重拉一次;
/// - `/chat/user-tracking-state/{userId}`:自己在别的设备/标签页把某频道
///   标成已读时同步清零(**不会**在别人给你发消息时推给你——核对过源码
///   Chat::Publisher#publish_user_tracking_state!,只在"当前用户自己标记
///   已读"的调用链里触发,纯粹是多端已读状态同步,不是新消息通知);
/// - 对列表里**每一个**频道各自订阅 `/chat/{id}/new-messages`,让列表页
///   开着时收到消息也能实时刷新预览/加粗状态(官方网页端 chat-channels-
///   manager 就是这么订的)。这层随频道列表增删动态增减订阅,列表页关掉
///   (autoDispose)时随之整体退订。
///
/// 由频道列表页 `ref.watch` 激活;不接未读徽标——本 app 通知 tab 本身
/// 在底栏就没有角标,DM 保持一致,不单独做。
class ChatTrackingChannelNotifier extends Notifier<void> {
  final List<(String, MessageBusCallback)> _globalSubscriptions = [];
  final Map<int, MessageBusCallback> _channelSubscriptions = {};
  final Map<int, MessageBusCallback> _rootSubscriptions = {};

  @override
  void build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;
    final channels = ref.watch(chatChannelListProvider).value ?? const [];

    for (final (channel, callback) in _globalSubscriptions) {
      messageBus.unsubscribe(channel, callback);
    }
    _globalSubscriptions.clear();

    if (currentUser == null) {
      for (final entry in _channelSubscriptions.entries) {
        messageBus.unsubscribe('/chat/${entry.key}/new-messages', entry.value);
      }
      _channelSubscriptions.clear();
      for (final entry in _rootSubscriptions.entries) {
        messageBus.unsubscribe('/chat/${entry.key}', entry.value);
      }
      _rootSubscriptions.clear();
      return;
    }

    void onNewChannel(MessageBusMessage message) {
      debugPrint('[ChatTracking] 收到新 DM 频道推送');
      if (ref.exists(chatChannelListProvider)) {
        unawaited(ref.read(chatChannelListProvider.notifier).refresh());
      }
    }

    void onTrackingState(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final channelId = data['channel_id'] as int?;
      if (channelId == null) return;
      debugPrint('[ChatTracking] 频道 $channelId 已读状态同步');
      if (ref.exists(chatChannelListProvider)) {
        ref
            .read(chatChannelListProvider.notifier)
            .applyUnreadUpdate(
              channelId,
              unreadCount: data['unread_count'] as int?,
              unreadMentions: data['mention_count'] as int?,
            );
      }
    }

    const newChannelChannel = '/chat/new-channel';
    final trackingChannel = '/chat/user-tracking-state/${currentUser.id}';

    messageBus.subscribe(newChannelChannel, onNewChannel);
    messageBus.subscribe(trackingChannel, onTrackingState);
    _globalSubscriptions.add((newChannelChannel, onNewChannel));
    _globalSubscriptions.add((trackingChannel, onTrackingState));

    // 按当前频道列表动态增减 per-channel 订阅
    final currentIds = channels.map((c) => c.id).toSet();
    final removedIds = _channelSubscriptions.keys
        .where((id) => !currentIds.contains(id))
        .toList();
    for (final id in removedIds) {
      messageBus.unsubscribe(
        '/chat/$id/new-messages',
        _channelSubscriptions.remove(id),
      );
      final rootCallback = _rootSubscriptions.remove(id);
      if (rootCallback != null)
        messageBus.unsubscribe('/chat/$id', rootCallback);
    }

    for (final chatChannel in channels) {
      final channelId = chatChannel.id;

      if (!_rootSubscriptions.containsKey(channelId)) {
        void onRootMessage(MessageBusMessage message) {
          final data = message.data;
          if (data is! Map<String, dynamic>) return;
          if (!ref.exists(chatChannelListProvider)) return;
          final notifier = ref.read(chatChannelListProvider.notifier);

          if (data['type'] == 'processed' || data['type'] == 'edit') {
            final raw = data['chat_message'] as Map<String, dynamic>?;
            if (raw == null) return;
            final id = raw['id'] as int?;
            if (id == null) return;
            notifier.applyLastMessagePreview(
              channelId,
              id,
              raw['message'] as String?,
            );
            return;
          }

          if (data['type'] == 'delete') {
            final deletedId = data['deleted_id'] as int?;
            if (deletedId == null) return;
            notifier.applyLastMessagePreview(channelId, deletedId, null);
          }
        }

        messageBus.subscribe('/chat/$channelId', onRootMessage);
        _rootSubscriptions[channelId] = onRootMessage;
      }

      if (_channelSubscriptions.containsKey(channelId)) continue;
      void onChannelMessage(MessageBusMessage message) {
        final data = message.data;
        if (data is! Map<String, dynamic> || data['type'] == 'thread') return;
        final raw = data['message'] as Map<String, dynamic>?;
        if (raw == null) return;
        try {
          final incoming = ChatMessage.fromJson(raw);
          final isOwn = incoming.user?.username == currentUser.username;
          if (ref.exists(chatChannelListProvider)) {
            ref
                .read(chatChannelListProvider.notifier)
                .applyIncomingMessage(channelId, incoming, isOwnMessage: isOwn);
          }
        } catch (e) {
          debugPrint('[ChatTracking] 解析频道 $channelId 新消息失败: $e');
        }
      }

      messageBus.subscribe('/chat/$channelId/new-messages', onChannelMessage);
      _channelSubscriptions[channelId] = onChannelMessage;
    }

    ref.onDispose(() {
      for (final (channel, callback) in _globalSubscriptions) {
        messageBus.unsubscribe(channel, callback);
      }
      _globalSubscriptions.clear();
      for (final entry in _channelSubscriptions.entries) {
        messageBus.unsubscribe('/chat/${entry.key}/new-messages', entry.value);
      }
      _channelSubscriptions.clear();
    });
  }
}

final chatTrackingChannelProvider =
    NotifierProvider.autoDispose<ChatTrackingChannelNotifier, void>(
      ChatTrackingChannelNotifier.new,
    );

/// DM 系统通知:订阅 `/chat/notification-alert/{userId}`(Discourse Chat
/// 插件 `Jobs::Chat::NotifyWatching` 在对方"watching"这个频道时推送,payload
/// 里已经有服务端拼好的标题/摘要,不用自己再拼)。本 app 通知列表/角标都
/// 走的是普通 `/notification-alert/{userId}`,chat 是完全独立的一条推送
/// 通道,必须单独订阅,不会自动出现在通知列表里。
/// 常驻(非 autoDispose),由 main.dart 在用户登录后统一激活。
class ChatNotificationAlertChannelNotifier extends Notifier<void> {
  String? _subscribedChannel;
  MessageBusCallback? _callback;

  @override
  void build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_subscribedChannel != null && _callback != null) {
      messageBus.unsubscribe(_subscribedChannel!, _callback);
      _subscribedChannel = null;
      _callback = null;
    }

    if (currentUser == null) return;

    final channel = '/chat/notification-alert/${currentUser.id}';

    void onAlert(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      debugPrint('[ChatNotificationAlert] 收到提醒: $data');

      final username = data['username'] as String? ?? '';
      final blockedUsernames = ref
          .read(preferencesProvider)
          .normalizedBlockedUsernames;
      if (BlockedUserFilter.isBlockedUsername(username, blockedUsernames))
        return;

      final channelId = data['channel_id'] as int?;
      final title = data['translated_title'] as String? ?? username;
      final body = data['excerpt'] as String? ?? '';

      LocalNotificationService().show(
        title: title,
        body: body,
        chatChannelId: channelId,
      );
    }

    _subscribedChannel = channel;
    _callback = onAlert;
    messageBus.subscribe(channel, onAlert);

    ref.onDispose(() {
      if (_subscribedChannel != null && _callback != null) {
        messageBus.unsubscribe(_subscribedChannel!, _callback);
      }
    });
  }
}

final chatNotificationAlertChannelProvider =
    NotifierProvider<ChatNotificationAlertChannelNotifier, void>(
      ChatNotificationAlertChannelNotifier.new,
    );

/// 单个 DM 频道的消息流:进入详情页加载历史消息 + 订阅频道内新消息,
/// 离开页面(不再被引用)自动退订。
/// 非 codegen 的 family AsyncNotifier 写法:参数通过构造函数传入并存成
/// 字段,`build()` 不接收参数(对齐 riverpod 3 手写 API,而非 @riverpod 生成版)。
class ChatMessagesNotifier extends AsyncNotifier<List<ChatMessage>> {
  ChatMessagesNotifier(this.channelId);

  final int channelId;

  String? _subscribedChannel;
  MessageBusCallback? _callback;
  String? _subscribedRootChannel;
  MessageBusCallback? _rootCallback;
  // autoDispose 场景下,MessageBus 分发某个 chunk 时先给回调列表拍了张快照
  // 再逐个调用(见 message_bus_service.dart 的 ConcurrentModificationError
  // 修复),快照里的回调即便随后被 unsubscribe 也还是会跑完——如果这时
  // provider 已经 dispose(比如快速切换私聊频道),回调里的 `state = ...`
  // 会打在已死的 Element 上炸 `_lifecycleState != defunct` 断言。
  // 所有回调开头都要先检查这个标志。
  bool _disposed = false;

  @override
  Future<List<ChatMessage>> build() async {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final service = ref.read(discourseServiceProvider);

    if (_subscribedChannel != null && _callback != null) {
      messageBus.unsubscribe(_subscribedChannel!, _callback);
      _subscribedChannel = null;
      _callback = null;
    }
    if (_subscribedRootChannel != null && _rootCallback != null) {
      messageBus.unsubscribe(_subscribedRootChannel!, _rootCallback);
      _subscribedRootChannel = null;
      _rootCallback = null;
    }

    final messages = await service.fetchChatMessages(
      channelId,
      fetchFromLastRead: true,
    );
    // 接口返回按时间倒序或正序取决于 fetch_from_last_read,统一按创建时间升序排列
    final sorted = [...messages]
      ..sort(
        (a, b) =>
            (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
      );

    if (sorted.isNotEmpty) {
      _markRead(sorted.last.id);
    }

    final channel = '/chat/$channelId/new-messages';
    void onMessage(MessageBusMessage message) {
      if (_disposed) return;
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      // 核对过 Discourse 源码 Chat::Publisher#publish_new!:payload 是
      // `{type: "channel"|"thread", channel_id, thread_id, message: <序列化后的消息>}`,
      // 键名是 `message` 不是 `chat_message`;`type == "thread"` 时是子串消息,
      // DM 场景不开线程,这里跳过以免误当主时间线消息插入。
      if (data['type'] == 'thread') return;
      final raw = data['message'] as Map<String, dynamic>?;
      if (raw == null) return;
      try {
        final incoming = ChatMessage.fromJson(raw);
        final current = state.value ?? const [];
        if (current.any((m) => m.id == incoming.id)) return;
        state = AsyncValue.data([...current, incoming]);
        _markRead(incoming.id);
      } catch (e) {
        debugPrint('[ChatMessages] 解析新消息失败: $e');
      }
    }

    _subscribedChannel = channel;
    _callback = onMessage;
    messageBus.subscribe(channel, onMessage);

    // 表情回应走的是频道**根**频道(`/chat/{id}`),不是 new-messages 子
    // 频道——核对过源码 Chat::Publisher#publish_reaction!→
    // publish_to_targets!→calculate_publish_targets,非线程消息只发根频道。
    final rootChannel = '/chat/$channelId';
    void onRootMessage(MessageBusMessage message) {
      if (_disposed) return;
      final data = message.data;
      if (data is! Map<String, dynamic>) return;

      // 图片/附件消息发出时服务端异步"cook"(生成最终 HTML),首次广播
      // 常常 cooked 还没算完;算完后走 `processed` 事件补发完整消息
      // (核对过源码 Chat::Publisher#publish_processed!/publish_edit!/
      // publish_restore!,统一走 `serialize_message_with_type`,payload
      // 形状是 `{chat_message: {...完整字段...}, type: "processed"}`——
      // 注意键名是 `chat_message` 不是 `message`,跟 new-messages 频道
      // 那条不是一回事)。不接这个事件的话,图片/附件消息会一直停在
      // "没有 cooked"的状态,表现为"收不到图片"。
      if (data['type'] == 'processed' ||
          data['type'] == 'edit' ||
          data['type'] == 'restore') {
        final raw = data['chat_message'] as Map<String, dynamic>?;
        if (raw == null) return;
        try {
          final updated = ChatMessage.fromJson(raw);
          final current = state.value ?? const [];
          final index = current.indexWhere((m) => m.id == updated.id);
          if (index == -1) return;
          final next = [...current];
          next[index] = updated;
          state = AsyncValue.data(next);
        } catch (e) {
          debugPrint('[ChatMessages] 解析更新消息失败: $e');
        }
        return;
      }

      // 删除是软删除:标记 deletedAt 让气泡显示"(消息已删除)",不从列表移除
      // (payload 核对过 publish_delete!:`{type:"delete", deleted_id, deleted_at, ...}`)。
      if (data['type'] == 'delete') {
        final deletedId = data['deleted_id'] as int?;
        if (deletedId == null) return;
        final current = state.value ?? const [];
        final index = current.indexWhere((m) => m.id == deletedId);
        if (index == -1) return;
        final next = [...current];
        next[index] = next[index].copyWith(deletedAt: DateTime.now());
        state = AsyncValue.data(next);
        return;
      }

      if (data['type'] != 'reaction') return;
      final messageId = data['chat_message_id'] as int?;
      final emoji = data['emoji'] as String?;
      final action = data['action'] as String?;
      final reactUser = data['user'] as Map<String, dynamic>?;
      if (messageId == null || emoji == null || action == null) return;
      final currentUsername = ref.read(currentUserProvider).value?.username;
      final isSelf = reactUser?['username'] == currentUsername;
      // 自己点的回应服务端也会广播回本频道(root channel 的推送是发给
      // 全体成员的,不区分"是不是操作者本人")。[toggleReaction] 已经
      // 乐观更新过一次了,这里再原样应用一次 add/remove 会把自己那份
      // 计数重复叠加——两个人各点一次同一个表情,本该显示 2,结果显示 3
      // 就是这么来的:一次自己的乐观 +1,一次自己动作的回声又 +1。
      if (isSelf) return;
      final current = state.value ?? const [];
      final index = current.indexWhere((m) => m.id == messageId);
      if (index == -1) return;
      final target = current[index];
      final reactions = [...target.reactions];
      final reactionIndex = reactions.indexWhere((r) => r.emoji == emoji);
      if (action == 'add') {
        if (reactionIndex == -1) {
          reactions.add(ChatReaction(emoji: emoji, count: 1, reacted: isSelf));
        } else {
          final old = reactions[reactionIndex];
          reactions[reactionIndex] = ChatReaction(
            emoji: emoji,
            count: old.count + 1,
            reacted: old.reacted || isSelf,
          );
        }
      } else if (reactionIndex != -1) {
        final old = reactions[reactionIndex];
        final nextCount = old.count - 1;
        if (nextCount <= 0) {
          reactions.removeAt(reactionIndex);
        } else {
          reactions[reactionIndex] = ChatReaction(
            emoji: emoji,
            count: nextCount,
            reacted: isSelf ? false : old.reacted,
          );
        }
      }
      final next = [...current];
      next[index] = target.copyWithReactions(reactions);
      state = AsyncValue.data(next);
    }

    _subscribedRootChannel = rootChannel;
    _rootCallback = onRootMessage;
    messageBus.subscribe(rootChannel, onRootMessage);

    ref.onDispose(() {
      _disposed = true;
      if (_subscribedChannel != null && _callback != null) {
        messageBus.unsubscribe(_subscribedChannel!, _callback);
      }
      if (_subscribedRootChannel != null && _rootCallback != null) {
        messageBus.unsubscribe(_subscribedRootChannel!, _rootCallback);
      }
    });

    return sorted;
  }

  /// 切换某条消息的表情回应:乐观更新本地列表,失败再改回来。
  Future<void> toggleReaction(int messageId, String emoji) async {
    final current = state.value ?? const [];
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final target = current[index];
    final reactions = [...target.reactions];
    final reactionIndex = reactions.indexWhere((r) => r.emoji == emoji);
    final wasReacted = reactionIndex != -1 && reactions[reactionIndex].reacted;

    final optimistic = [...reactions];
    if (wasReacted) {
      final old = optimistic[reactionIndex];
      if (old.count <= 1) {
        optimistic.removeAt(reactionIndex);
      } else {
        optimistic[reactionIndex] = ChatReaction(
          emoji: emoji,
          count: old.count - 1,
          reacted: false,
        );
      }
    } else if (reactionIndex == -1) {
      optimistic.add(ChatReaction(emoji: emoji, count: 1, reacted: true));
    } else {
      final old = optimistic[reactionIndex];
      optimistic[reactionIndex] = ChatReaction(
        emoji: emoji,
        count: old.count + 1,
        reacted: true,
      );
    }

    final next = [...current];
    next[index] = target.copyWithReactions(optimistic);
    state = AsyncValue.data(next);

    if (!wasReacted) {
      unawaited(ref.read(recentChatReactionsProvider.notifier).track(emoji));
    }

    try {
      final service = ref.read(discourseServiceProvider);
      await service.toggleChatReaction(
        channelId,
        messageId,
        emoji,
        add: !wasReacted,
      );
    } catch (e) {
      debugPrint('[ChatMessages] 表情回应失败: $e');
      final rollback = <ChatMessage>[...(state.value ?? const [])];
      final rollbackIndex = rollback.indexWhere((m) => m.id == messageId);
      if (rollbackIndex != -1) {
        rollback[rollbackIndex] = target;
        state = AsyncValue.data(rollback);
      }
    }
  }

  /// 本地更新某条消息的书签状态(创建/编辑/删除书签后同步 UI)。
  void applyBookmark(int messageId, ChatBookmark? bookmark) {
    final current = state.value;
    if (current == null) return;
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final next = List<ChatMessage>.from(current);
    next[index] = current[index].copyWith(
      bookmark: bookmark,
      clearBookmark: bookmark == null,
    );
    state = AsyncValue.data(next);
  }

  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  /// 往上翻加载更早的消息(以当前最早一条为锚点,direction=past)。
  Future<void> loadOlder() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    final current = state.value;
    if (current == null || current.isEmpty) return;
    _loadingOlder = true;
    ref.read(chatLoadingOlderProvider(channelId).notifier).set(true);
    try {
      final service = ref.read(discourseServiceProvider);
      final older = await service.fetchChatMessages(
        channelId,
        targetMessageId: current.first.id,
        direction: 'past',
      );
      if (older.isEmpty) {
        _hasMoreOlder = false;
        return;
      }
      final existingIds = current.map((m) => m.id).toSet();
      final fresh = older.where((m) => !existingIds.contains(m.id)).toList()
        ..sort(
          (a, b) => (a.createdAt ?? DateTime(0)).compareTo(
            b.createdAt ?? DateTime(0),
          ),
        );
      if (fresh.isEmpty) {
        _hasMoreOlder = false;
        return;
      }
      state = AsyncValue.data([...fresh, ...(state.value ?? current)]);
    } catch (e) {
      debugPrint('[ChatMessages] 加载更早消息失败: $e');
    } finally {
      _loadingOlder = false;
      if (ref.exists(chatLoadingOlderProvider(channelId))) {
        ref.read(chatLoadingOlderProvider(channelId).notifier).set(false);
      }
    }
  }

  /// 编辑一条消息:服务端保存后会通过根频道的 `edit` 事件把完整新消息
  /// 推回来(build 里已接),这里不做乐观更新,失败直接抛给调用方提示。
  Future<void> editMessage(int messageId, String text) async {
    final service = ref.read(discourseServiceProvider);
    await service.updateChatMessage(channelId, messageId, text);
  }

  /// 删除自己的消息:乐观标记为已删除,失败回滚。
  Future<void> deleteMessage(int messageId) async {
    final current = state.value ?? const [];
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = current[index];
    final next = [...current];
    next[index] = original.copyWith(deletedAt: DateTime.now());
    state = AsyncValue.data(next);
    try {
      await ref
          .read(discourseServiceProvider)
          .deleteChatMessage(channelId, messageId);
    } catch (e) {
      final rollback = <ChatMessage>[...(state.value ?? const [])];
      final i = rollback.indexWhere((m) => m.id == messageId);
      if (i != -1) {
        rollback[i] = original;
        state = AsyncValue.data(rollback);
      }
      rethrow;
    }
  }

  /// 恢复被删除的消息(restore 事件会推回完整消息,这里只发请求)。
  Future<void> restoreMessage(int messageId) async {
    await ref
        .read(discourseServiceProvider)
        .restoreChatMessage(channelId, messageId);
  }

  /// 置顶/取消置顶:乐观更新 pinned 标记,失败回滚。
  Future<void> togglePinned(int messageId) async {
    final current = state.value ?? const [];
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = current[index];
    final nextPinned = !original.pinned;
    final next = [...current];
    next[index] = original.copyWith(pinned: nextPinned);
    state = AsyncValue.data(next);
    try {
      await ref
          .read(discourseServiceProvider)
          .setChatMessagePinned(channelId, messageId, pinned: nextPinned);
    } catch (e) {
      final rollback = <ChatMessage>[...(state.value ?? const [])];
      final i = rollback.indexWhere((m) => m.id == messageId);
      if (i != -1) {
        rollback[i] = original;
        state = AsyncValue.data(rollback);
      }
      rethrow;
    }
  }

  /// 详情页开着时读到新消息,顺手标记已读:服务端 + 本地频道列表未读数
  /// 一起清零,不等下次整表刷新才把徽标降下去。fire-and-forget,失败不
  /// 影响消息流本身的展示。
  void _markRead(int messageId) {
    final service = ref.read(discourseServiceProvider);
    unawaited(
      service.markChatChannelRead(channelId, messageId).catchError((e) {
        debugPrint('[ChatMessages] 标记已读失败: $e');
      }),
    );
    if (ref.exists(chatChannelListProvider)) {
      ref.read(chatChannelListProvider.notifier).markRead(channelId);
    }
  }
}

/// 最近使用过的快捷回应 emoji(最多 3 个)。对齐官方实现:网页端存
/// localStorage(`emoji-store.js` 的 KeyValueStore),服务端不存,
/// 这里对应地存 SharedPreferences。
class RecentChatReactionsNotifier extends Notifier<List<String>> {
  static const _prefsKey = 'chat_recent_reactions';
  static const _defaults = ['+1', 'heart', 'joy'];

  @override
  List<String> build() {
    unawaited(_load());
    return _defaults;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey);
    if (stored != null && stored.isNotEmpty) {
      state = [
        ...stored,
        ..._defaults.where((e) => !stored.contains(e)),
      ].take(3).toList();
    }
  }

  Future<void> track(String emoji) async {
    final next = [emoji, ...state.where((e) => e != emoji)].take(3).toList();
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, next);
  }
}

final recentChatReactionsProvider =
    NotifierProvider<RecentChatReactionsNotifier, List<String>>(
      RecentChatReactionsNotifier.new,
    );

/// 单个消息串的消息流:加载历史 + 订阅本频道 new-messages 里
/// type == "thread" 且 thread_id 匹配的推送。参数是 (channelId, threadId)。
class ChatThreadMessagesNotifier extends AsyncNotifier<List<ChatMessage>> {
  ChatThreadMessagesNotifier(this.arg);

  final (int, int) arg;
  int get channelId => arg.$1;
  int get threadId => arg.$2;

  String? _subscribedChannel;
  MessageBusCallback? _callback;
  String? _subscribedRootChannel;
  MessageBusCallback? _rootCallback;
  // 同 ChatMessagesNotifier 的 _disposed 说明:防止已 dispose 后回调快照
  // 仍触发 `state = ...` 炸 defunct Element 断言。
  bool _disposed = false;

  @override
  Future<List<ChatMessage>> build() async {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final service = ref.read(discourseServiceProvider);

    if (_subscribedChannel != null && _callback != null) {
      messageBus.unsubscribe(_subscribedChannel!, _callback);
      _subscribedChannel = null;
      _callback = null;
    }
    if (_subscribedRootChannel != null && _rootCallback != null) {
      messageBus.unsubscribe(_subscribedRootChannel!, _rootCallback);
      _subscribedRootChannel = null;
      _rootCallback = null;
    }

    final messages = await service.fetchChatThreadMessages(channelId, threadId);
    final sorted = [...messages]
      ..sort(
        (a, b) =>
            (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
      );

    unawaited(
      service.markChatThreadRead(channelId, threadId).catchError((_) {}),
    );

    final channel = '/chat/$channelId/new-messages';
    void onMessage(MessageBusMessage message) {
      if (_disposed) return;
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      if (data['type'] != 'thread' || data['thread_id'] != threadId) return;
      final raw = data['message'] as Map<String, dynamic>?;
      if (raw == null) return;
      try {
        final incoming = ChatMessage.fromJson(raw);
        final current = state.value ?? const [];
        if (current.any((m) => m.id == incoming.id)) return;
        state = AsyncValue.data([...current, incoming]);
      } catch (e) {
        debugPrint('[ChatThread] 解析线程新消息失败: $e');
      }
    }

    _subscribedChannel = channel;
    _callback = onMessage;
    messageBus.subscribe(channel, onMessage);

    // 主频道那份(ChatMessagesNotifier.build)接了根频道 `/chat/{id}` 的
    // processed/edit/restore/delete/reaction,串这边之前只接了
    // new-messages,图片处理完成/编辑/撤回/回应这些事件全收不到——
    // 表现就是串里内容不会自动更新,得手动刷新。这里补齐同一套处理,
    // 按 messageId 是否存在于当前串状态里过滤,不用额外核对 thread_id。
    final rootChannel = '/chat/$channelId';
    void onRootMessage(MessageBusMessage message) {
      if (_disposed) return;
      final data = message.data;
      if (data is! Map<String, dynamic>) return;

      if (data['type'] == 'processed' ||
          data['type'] == 'edit' ||
          data['type'] == 'restore') {
        final raw = data['chat_message'] as Map<String, dynamic>?;
        if (raw == null) return;
        try {
          final updated = ChatMessage.fromJson(raw);
          final current = state.value ?? const [];
          final index = current.indexWhere((m) => m.id == updated.id);
          if (index == -1) return;
          final next = [...current];
          next[index] = updated;
          state = AsyncValue.data(next);
        } catch (e) {
          debugPrint('[ChatThread] 解析更新消息失败: $e');
        }
        return;
      }

      if (data['type'] == 'delete') {
        final deletedId = data['deleted_id'] as int?;
        if (deletedId == null) return;
        final current = state.value ?? const [];
        final index = current.indexWhere((m) => m.id == deletedId);
        if (index == -1) return;
        final next = [...current];
        next[index] = next[index].copyWith(deletedAt: DateTime.now());
        state = AsyncValue.data(next);
        return;
      }

      if (data['type'] != 'reaction') return;
      final messageId = data['chat_message_id'] as int?;
      final emoji = data['emoji'] as String?;
      final action = data['action'] as String?;
      final reactUser = data['user'] as Map<String, dynamic>?;
      if (messageId == null || emoji == null || action == null) return;
      final currentUsername = ref.read(currentUserProvider).value?.username;
      final isSelf = reactUser?['username'] == currentUsername;
      if (isSelf) return;
      final current = state.value ?? const [];
      final index = current.indexWhere((m) => m.id == messageId);
      if (index == -1) return;
      final target = current[index];
      final reactions = [...target.reactions];
      final reactionIndex = reactions.indexWhere((r) => r.emoji == emoji);
      if (action == 'add') {
        if (reactionIndex == -1) {
          reactions.add(ChatReaction(emoji: emoji, count: 1, reacted: isSelf));
        } else {
          final old = reactions[reactionIndex];
          reactions[reactionIndex] = ChatReaction(
            emoji: emoji,
            count: old.count + 1,
            reacted: old.reacted || isSelf,
          );
        }
      } else if (reactionIndex != -1) {
        final old = reactions[reactionIndex];
        final nextCount = old.count - 1;
        if (nextCount <= 0) {
          reactions.removeAt(reactionIndex);
        } else {
          reactions[reactionIndex] = ChatReaction(
            emoji: emoji,
            count: nextCount,
            reacted: isSelf ? false : old.reacted,
          );
        }
      }
      final next = [...current];
      next[index] = target.copyWithReactions(reactions);
      state = AsyncValue.data(next);
    }

    _subscribedRootChannel = rootChannel;
    _rootCallback = onRootMessage;
    messageBus.subscribe(rootChannel, onRootMessage);

    ref.onDispose(() {
      _disposed = true;
      if (_subscribedChannel != null && _callback != null) {
        messageBus.unsubscribe(_subscribedChannel!, _callback);
      }
      if (_subscribedRootChannel != null && _rootCallback != null) {
        messageBus.unsubscribe(_subscribedRootChannel!, _rootCallback);
      }
    });

    return sorted;
  }

  Future<void> toggleReaction(int messageId, String emoji) async {
    final current = state.value ?? const [];
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final target = current[index];
    final reactions = [...target.reactions];
    final reactionIndex = reactions.indexWhere((r) => r.emoji == emoji);
    final wasReacted = reactionIndex != -1 && reactions[reactionIndex].reacted;

    final optimistic = [...reactions];
    if (wasReacted) {
      final old = optimistic[reactionIndex];
      if (old.count <= 1) {
        optimistic.removeAt(reactionIndex);
      } else {
        optimistic[reactionIndex] = ChatReaction(
          emoji: emoji,
          count: old.count - 1,
          reacted: false,
        );
      }
    } else if (reactionIndex == -1) {
      optimistic.add(ChatReaction(emoji: emoji, count: 1, reacted: true));
    } else {
      final old = optimistic[reactionIndex];
      optimistic[reactionIndex] = ChatReaction(
        emoji: emoji,
        count: old.count + 1,
        reacted: true,
      );
    }

    final next = [...current];
    next[index] = target.copyWithReactions(optimistic);
    state = AsyncValue.data(next);

    if (!wasReacted) {
      unawaited(ref.read(recentChatReactionsProvider.notifier).track(emoji));
    }

    try {
      final service = ref.read(discourseServiceProvider);
      await service.toggleChatReaction(
        channelId,
        messageId,
        emoji,
        add: !wasReacted,
      );
    } catch (e) {
      debugPrint('[ChatThread] 切换回应失败,回退: $e');
      final rollback = state.value ?? const [];
      final rollbackIndex = rollback.indexWhere((m) => m.id == messageId);
      if (rollbackIndex == -1) return;
      final rolledBack = [...rollback];
      rolledBack[rollbackIndex] = rolledBack[rollbackIndex].copyWithReactions(
        reactions,
      );
      state = AsyncValue.data(rolledBack);
    }
  }

  Future<void> editMessage(int messageId, String text) async {
    final service = ref.read(discourseServiceProvider);
    await service.updateChatMessage(channelId, messageId, text);
  }

  /// 删除自己的消息:乐观标记为已删除,失败回滚。
  Future<void> deleteMessage(int messageId) async {
    final current = state.value ?? const [];
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = current[index];
    final next = [...current];
    next[index] = original.copyWith(deletedAt: DateTime.now());
    state = AsyncValue.data(next);
    try {
      await ref.read(discourseServiceProvider).deleteChatMessage(channelId, messageId);
    } catch (e) {
      final rollback = <ChatMessage>[...(state.value ?? const [])];
      final i = rollback.indexWhere((m) => m.id == messageId);
      if (i != -1) {
        rollback[i] = original;
        state = AsyncValue.data(rollback);
      }
      rethrow;
    }
  }

  Future<void> restoreMessage(int messageId) async {
    await ref.read(discourseServiceProvider).restoreChatMessage(channelId, messageId);
  }

  Future<void> togglePinned(int messageId) async {
    final current = state.value ?? const [];
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = current[index];
    final nextPinned = !original.pinned;
    final next = [...current];
    next[index] = original.copyWith(pinned: nextPinned);
    state = AsyncValue.data(next);
    try {
      await ref
          .read(discourseServiceProvider)
          .setChatMessagePinned(channelId, messageId, pinned: nextPinned);
    } catch (e) {
      final rollback = <ChatMessage>[...(state.value ?? const [])];
      final i = rollback.indexWhere((m) => m.id == messageId);
      if (i != -1) {
        rollback[i] = original;
        state = AsyncValue.data(rollback);
      }
      rethrow;
    }
  }

  void applyBookmark(int messageId, ChatBookmark? bookmark) {
    final current = state.value;
    if (current == null) return;
    final index = current.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final next = List<ChatMessage>.from(current);
    next[index] = current[index].copyWith(
      bookmark: bookmark,
      clearBookmark: bookmark == null,
    );
    state = AsyncValue.data(next);
  }
}

final chatThreadMessagesProvider = AsyncNotifierProvider.autoDispose
    .family<ChatThreadMessagesNotifier, List<ChatMessage>, (int, int)>(
      (arg) => ChatThreadMessagesNotifier(arg),
    );

/// 某频道"正在向上加载更早消息"的 UI 状态,详情页顶部转圈用。
class ChatLoadingOlderNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final chatLoadingOlderProvider = NotifierProvider.autoDispose
    .family<ChatLoadingOlderNotifier, bool, int>(
      (channelId) => ChatLoadingOlderNotifier(),
    );

final chatMessagesProvider = AsyncNotifierProvider.autoDispose
    .family<ChatMessagesNotifier, List<ChatMessage>, int>(
      (channelId) => ChatMessagesNotifier(channelId),
    );

/// 聊天在线用户 id 集合,对齐官方 `/chat/online` presence 频道:
/// 初始 `/presence/get` 快照 + MessageBus `/presence/chat/online` 增量
/// (`entering_users`/`leaving_user_ids`)。autoDispose:没有聊天页面/头像
/// 使用时自动释放订阅。
class ChatOnlinePresenceNotifier extends AsyncNotifier<Set<int>> {
  String? _subscribedChannel;
  MessageBusCallback? _callback;
  // 同 ChatMessagesNotifier 的 _disposed 说明:防止已 dispose 后回调快照
  // 仍触发 `state = ...` 炸 defunct Element 断言。
  bool _disposed = false;

  @override
  Future<Set<int>> build() async {
    final messageBus = ref.watch(messageBusServiceProvider);
    final service = ref.read(discourseServiceProvider);

    ref.onDispose(() {
      _disposed = true;
      if (_subscribedChannel != null && _callback != null) {
        messageBus.unsubscribe(_subscribedChannel!, _callback!);
      }
    });

    final channel = '/presence/chat/online';
    _callback = (message) {
      if (_disposed) return;
      final data = message.data as Map<String, dynamic>?;
      if (data == null) return;
      final current = Set<int>.from(state.value ?? const {});
      final entering = data['entering_users'] as List<dynamic>?;
      if (entering != null) {
        for (final u in entering) {
          final id = (u as Map<String, dynamic>)['id'] as int?;
          if (id != null) current.add(id);
        }
      }
      final leaving = data['leaving_user_ids'] as List<dynamic>?;
      if (leaving != null) {
        for (final id in leaving) {
          current.remove(id as int);
        }
      }
      state = AsyncValue.data(current);
    };
    messageBus.subscribe(channel, _callback!);
    _subscribedChannel = channel;

    return service.getChatOnlinePresence();
  }
}

final chatOnlinePresenceProvider =
    AsyncNotifierProvider.autoDispose<ChatOnlinePresenceNotifier, Set<int>>(
  ChatOnlinePresenceNotifier.new,
);
