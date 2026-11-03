import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat/chat_channel.dart';
import '../../services/local_notification_service.dart';
import '../../services/message_bus_service.dart';
import '../../utils/blocked_user_filter.dart';
import '../discourse_providers.dart';
import '../message_bus/message_bus_service_provider.dart';
import '../message_bus/topic_tracking_providers.dart';
import '../preferences_provider.dart';
import 'chat_channels_provider.dart';

/// Chat 系统通知:订阅 /chat/notification-alert/:userId
///
/// 服务端(notify_watching.rb)只给"频道通知级别 always 且未在
/// 该频道页面看过这条消息"的成员推,静音/已读语义在服务端已处理。
/// payload: { channel_id, translated_title, excerpt, username, ... }
class ChatNotificationAlertNotifier extends Notifier<void> {
  String? _subscribedChannel;
  MessageBusCallback? _callback;

  @override
  void build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUserId = ref.watch(
      currentUserProvider.select((value) => value.value?.id),
    );

    if (_subscribedChannel != null && _callback != null) {
      messageBus.unsubscribe(_subscribedChannel!, _callback);
      _subscribedChannel = null;
      _callback = null;
    }

    if (currentUserId == null) return;

    final channel = '/chat/notification-alert/$currentUserId';

    void onAlert(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;

      final username = data['username'] as String? ?? '';
      final blockedUsernames = ref
          .read(preferencesProvider)
          .normalizedBlockedUsernames;
      if (BlockedUserFilter.isBlockedUsername(username, blockedUsernames)) {
        return;
      }

      final channelId = data['channel_id'] as int?;
      final title = data['translated_title'] as String? ?? username;
      final excerpt = data['excerpt'] as String? ?? '';

      debugPrint('[ChatAlert] 系统通知: channel=$channelId title=$title');

      LocalNotificationService().show(
        title: title,
        body: excerpt,
        id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        chatChannelId: channelId,
        conversation: channelId != null && username.isNotEmpty
            ? _conversationFor(
                channelId: channelId,
                isDirectMessage:
                    data['is_direct_message_channel'] as bool? ?? false,
                username: username,
                selfName: ref.read(currentUserProvider).value?.username ?? '',
                fallbackTitle: title,
              )
            : null,
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

  /// 1:1 私聊走单聊排版(首行对方名字);群聊/公共频道走群聊排版
  /// (首行频道名,正文前带发送者名)。频道名取本地频道列表,查不到
  /// 退回服务端的 translated_title。
  NotificationConversation _conversationFor({
    required int channelId,
    required bool isDirectMessage,
    required String username,
    required String selfName,
    required String fallbackTitle,
  }) {
    final channels = ref.read(chatChannelsProvider).value;
    ChatChannel? channel;
    if (channels != null) {
      for (final c in [
        ...channels.directMessageChannels,
        ...channels.publicChannels,
      ]) {
        if (c.id == channelId) {
          channel = c;
          break;
        }
      }
    }
    final isGroup = !isDirectMessage || (channel?.isGroupDm ?? false);
    final channelTitle = channel?.title;
    return NotificationConversation(
      id: 'chat_${channelId}_${username.toLowerCase()}',
      title: !isGroup
          ? username
          : (channelTitle != null && channelTitle.isNotEmpty
                ? channelTitle
                : fallbackTitle),
      senderUsername: username,
      selfName: selfName,
      isGroup: isGroup,
    );
  }
}

final chatNotificationAlertProvider =
    NotifierProvider<ChatNotificationAlertNotifier, void>(
      ChatNotificationAlertNotifier.new,
    );
