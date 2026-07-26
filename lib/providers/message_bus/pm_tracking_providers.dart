import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/message_bus_service.dart';
import '../../utils/time_utils.dart';
import '../discourse_providers.dart';
import '../user_content_providers.dart';
import 'message_bus_service_provider.dart';
import 'topic_tracking_providers.dart';

/// 私信追踪频道监听器(对齐 Discourse 网页版 pm-topic-tracking-state)。
///
/// 网页版订阅 `/private-message-topic-tracking-state/{userId}`,收到
/// new_topic / unread / read / archive / group_archive 消息即更新私信
/// 列表;此前 App 的私信列表只有手动下拉刷新,收到新私信列表纹丝不动。
///
/// 由私信页 `ref.watch` 激活(autoDispose:离开页面即退订),收到消息
/// 后静默刷新**存活的**私信列表 provider —— 列表 provider 本身也是
/// autoDispose,页面不在时 `ref.exists` 为 false,不会凭空发请求。
class PmTrackingChannelNotifier extends Notifier<void> {
  String? _subscribedChannel;
  MessageBusCallback? _callback;
  Timer? _debounce;

  @override
  void build() {
    // 确保 MessageBus 已 configure(域名配置),避免用主站域名轮询
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_subscribedChannel != null && _callback != null) {
      messageBus.unsubscribe(_subscribedChannel!, _callback);
      _subscribedChannel = null;
      _callback = null;
    }

    if (currentUser == null) return;

    // 注意频道名带 `/user` 段(Discourse PrivateMessageTopicTrackingState
    // .user_channel;群组收件箱是 `/group/{groupId}`,暂不订阅)。第一版
    // 漏了这段,订到不存在的频道上,位置永远停在 0。
    final channel =
        '/private-message-topic-tracking-state/user/${currentUser.id}';
    debugPrint('[PmTracking] 订阅频道: $channel');

    void onMessage(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final type = data['message_type'] as String?;
      final topicId = data['topic_id'] as int?;
      final payload = data['payload'] as Map<String, dynamic>? ?? const {};
      debugPrint('[PmTracking] 收到消息: type=$type topic=$topicId');
      // 增量口径(对齐网页版):read/unread 改内存状态原地重渲染;
      // 只有「列表里没有的会话」(新私信/翻页外)才兜底重拉一次。
      // 硬刷新版本实测把接口打到 429,不能回去。
      switch (type) {
        case 'read':
          if (topicId == null) return;
          if (ref.exists(pmInboxProvider)) {
            ref.read(pmInboxProvider.notifier).applyTrackingRead(
                  topicId,
                  lastRead: payload['last_read_post_number'] as int?,
                  highest: payload['highest_post_number'] as int?,
                );
          }
        case 'unread':
          if (topicId == null) return;
          var handled = true;
          if (ref.exists(pmInboxProvider)) {
            handled = ref.read(pmInboxProvider.notifier).applyTrackingUnread(
                  topicId,
                  highest: payload['highest_post_number'] as int?,
                  postedAt: TimeUtils.parseUtcTime(
                    payload['created_at'] as String?,
                  ),
                );
          }
          if (!handled) _scheduleRefresh();
        case 'new_topic' || 'group_archive':
          _scheduleRefresh();
      }
    }

    _subscribedChannel = channel;
    _callback = onMessage;
    // -1 = 只收从现在起的新消息。不能从 0 订:服务器会回放该频道的
    // 全部积压,一上来连环触发刷新(429 的另一个源头)。
    messageBus.subscribeWithMessageId(channel, onMessage, -1);

    ref.onDispose(() {
      _debounce?.cancel();
      if (_subscribedChannel != null && _callback != null) {
        debugPrint('[PmTracking] 取消订阅: $_subscribedChannel');
        messageBus.unsubscribe(_subscribedChannel!, _callback);
      }
    });
  }

  /// 兜底刷新(仅新会话/列表外话题):去抖合并,只刷收件箱。
  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _refreshAlive);
  }

  void _refreshAlive() {
    if (!ref.mounted) return;
    // 只刷收件箱:收到的消息(new_topic/unread)只影响 inbox;已发送
    // 由发送动作本地刷新,归档由归档操作本地处理。全刷是三倍请求。
    if (ref.exists(pmInboxProvider)) {
      unawaited(ref.read(pmInboxProvider.notifier).refresh());
    }
  }
}

final pmTrackingChannelProvider =
    NotifierProvider.autoDispose<PmTrackingChannelNotifier, void>(
  PmTrackingChannelNotifier.new,
);
