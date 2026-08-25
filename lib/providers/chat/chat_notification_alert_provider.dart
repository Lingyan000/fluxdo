import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/local_notification_service.dart';
import '../../services/message_bus_service.dart';
import '../../utils/blocked_user_filter.dart';
import '../discourse_providers.dart';
import '../message_bus/message_bus_service_provider.dart';
import '../message_bus/topic_tracking_providers.dart';
import '../preferences_provider.dart';

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

final chatNotificationAlertProvider =
    NotifierProvider<ChatNotificationAlertNotifier, void>(
      ChatNotificationAlertNotifier.new,
    );
