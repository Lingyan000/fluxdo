/// 私信追踪状态（对齐 Discourse 网页版 services/pm-topic-tracking-state.js）
///
/// 与普通话题追踪（topic_tracking_providers.dart）分开的原因和网页版一致：
/// 私信的可见性由「收件人 + 所在群组」决定，服务端为此单独开了一组频道，
/// payload 结构与 /latest /unread 那套也不同（带 group_ids、acting_user_id 等）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/message_bus_service.dart';
import '../../services/preloaded_data_service.dart';
import '../discourse_providers.dart';
import 'message_bus_service_provider.dart';
import 'topic_tracking_providers.dart';

/// 频道前缀，与服务端 PrivateMessageTopicTrackingState 保持一致
const String _pmChannelPrefix = '/private-message-topic-tracking-state';

/// 私信收件箱的新消息状态
///
/// 只登记「有哪些私信话题来了新内容」，不承载列表本身：列表由
/// pmInboxProvider 等负责拉取，这里的作用是让 UI 知道该提示/该刷新。
class PmIncomingState {
  /// 有新内容的私信话题 ID（保持插入顺序）
  final Set<int> incomingTopicIds;

  const PmIncomingState({this.incomingTopicIds = const {}});

  bool get hasIncoming => incomingTopicIds.isNotEmpty;
  int get incomingCount => incomingTopicIds.length;

  PmIncomingState copyWith({Set<int>? incomingTopicIds}) =>
      PmIncomingState(incomingTopicIds: incomingTopicIds ?? this.incomingTopicIds);
}

/// 私信追踪 Notifier
///
/// 订阅两类频道（对齐网页版 startTracking）：
/// - `/private-message-topic-tracking-state/user/:user_id`
/// - `/private-message-topic-tracking-state/group/:group_id`（每个有私信的群组一条）
class PmTrackingNotifier extends Notifier<PmIncomingState> {
  final Map<String, MessageBusCallback> _callbacks = {};

  /// 与列表侧一致的上限兜底：长会话下不让集合无限增长
  static const int _maxTracked = 500;

  @override
  PmIncomingState build() {
    // 确保 MessageBus 已 configure（域名配置），避免用主站域名轮询
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    // 清理旧订阅（换账号 / provider 重建）
    for (final entry in _callbacks.entries) {
      messageBus.unsubscribe(entry.key, entry.value);
    }
    _callbacks.clear();

    if (currentUser == null) {
      return const PmIncomingState();
    }

    final channels = <String>[
      '$_pmChannelPrefix/user/${currentUser.id}',
      // 群组私信：只订阅「确实有私信」的群组，对齐 groupsWithMessages。
      // 全量订阅用户所在群组会白白扩大轮询 payload。
      for (final groupId in _groupIdsWithMessages())
        '$_pmChannelPrefix/group/$groupId',
    ];

    debugPrint('[PmTracking] 订阅 ${channels.length} 个私信频道: $channels');

    for (final channel in channels) {
      void onMessage(MessageBusMessage message) => _processMessage(
            message,
            currentUserId: currentUser.id,
          );
      _callbacks[channel] = onMessage;
      messageBus.subscribe(channel, onMessage);
    }

    ref.onDispose(() {
      debugPrint('[PmTracking] 取消订阅: ${_callbacks.keys}');
      for (final entry in _callbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _callbacks.clear();
    });

    return const PmIncomingState();
  }

  /// 从预加载的 current_user.groups 里挑出 has_messages 的群组
  ///
  /// 对齐网页版 `User#groupsWithMessages`。User 模型没建这两个字段，
  /// 直接读预加载 JSON 比为一处订阅去扩模型更划算。
  List<int> _groupIdsWithMessages() {
    final groups = PreloadedDataService().currentUserSync?['groups'];
    if (groups is! List) return const [];
    final ids = <int>[];
    for (final group in groups) {
      if (group is Map && group['has_messages'] == true) {
        final id = group['id'];
        if (id is int) ids.add(id);
      }
    }
    return ids;
  }

  /// 处理一条私信追踪消息（对齐网页版 _processMessage）
  ///
  /// 仅测试可见：真实路径由订阅回调驱动，单测直接嗂消息进来验证分支。
  @visibleForTesting
  void processMessageForTest(
    MessageBusMessage message, {
    required int currentUserId,
  }) =>
      _processMessage(message, currentUserId: currentUserId);

  void _processMessage(
    MessageBusMessage message, {
    required int currentUserId,
  }) {
    final data = message.data;
    if (data is! Map<String, dynamic>) return;

    final messageType = data['message_type'] as String?;
    final topicId = data['topic_id'] as int?;
    if (topicId == null) return;

    final payload = data['payload'] as Map<String, dynamic>? ?? const {};

    switch (messageType) {
      case 'new_topic':
        // 自己发出去的私信不该在自己的收件箱冒新消息提示
        if (payload['created_by_user_id'] == currentUserId) return;
        _addIncoming(topicId);

      case 'unread':
        // 注:网页版此处留了注释说明服务端目前是「按用户精确推送」,
        // 所以不需要像普通话题那样再过滤自己触发的 unread。
        _addIncoming(topicId);

      case 'group_archive':
        // 别人（或自己在别的端）归档了群组私信。自己刚做的操作不用提示。
        final actingUserId = payload['acting_user_id'];
        if (actingUserId is int && actingUserId == currentUserId) return;
        _addIncoming(topicId);

      case 'read':
        // 已读只需要把提示撤掉，不新增
        _removeIncoming(topicId);
    }
  }

  void _addIncoming(int topicId) {
    if (state.incomingTopicIds.contains(topicId)) return;
    final next = {...state.incomingTopicIds, topicId};
    state = state.copyWith(
      incomingTopicIds: next.length > _maxTracked
          ? next.skip(next.length - _maxTracked).toSet()
          : next,
    );
  }

  void _removeIncoming(int topicId) {
    if (!state.incomingTopicIds.contains(topicId)) return;
    state = state.copyWith(
      incomingTopicIds: {...state.incomingTopicIds}..remove(topicId),
    );
  }

  /// 用户已查看收件箱后清空提示（供列表页在刷新后调用）
  void clearIncoming() {
    if (state.incomingTopicIds.isEmpty) return;
    state = const PmIncomingState();
  }
}

final pmTrackingProvider =
    NotifierProvider<PmTrackingNotifier, PmIncomingState>(
  PmTrackingNotifier.new,
);
