import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/message_bus_service.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/background/ios_background_fetch.dart';
import '../discourse_providers.dart';
import 'message_bus_service_provider.dart';

/// 话题追踪状态元数据 Provider（MessageBus 频道初始 message ID）
final topicTrackingStateMetaProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getPreloadedTopicTrackingMeta();
});

// ─── 话题追踪状态（对齐 Discourse 网页版 topic-tracking-state.js）───

/// 单个话题的追踪状态
class TrackedTopicState {
  final int topicId;
  final int? lastReadPostNumber;  // null = 未读过（NEW）
  final int highestPostNumber;
  final int? categoryId;
  final int notificationLevel;  // 0=MUTED, 1=REGULAR, 2=TRACKING, 3=WATCHING
  final bool createdInNewPeriod;
  final bool isSeen;

  const TrackedTopicState({
    required this.topicId,
    this.lastReadPostNumber,
    required this.highestPostNumber,
    this.categoryId,
    this.notificationLevel = 1,
    this.createdInNewPeriod = false,
    this.isSeen = false,
  });

  TrackedTopicState copyWith({
    int? lastReadPostNumber,
    bool clearLastRead = false,
    int? highestPostNumber,
    int? categoryId,
    int? notificationLevel,
    bool? createdInNewPeriod,
    bool? isSeen,
  }) {
    return TrackedTopicState(
      topicId: topicId,
      lastReadPostNumber: clearLastRead ? null : (lastReadPostNumber ?? this.lastReadPostNumber),
      highestPostNumber: highestPostNumber ?? this.highestPostNumber,
      categoryId: categoryId ?? this.categoryId,
      notificationLevel: notificationLevel ?? this.notificationLevel,
      createdInNewPeriod: createdInNewPeriod ?? this.createdInNewPeriod,
      isSeen: isSeen ?? this.isSeen,
    );
  }

  /// 从预加载数据的 JSON 构建
  ///
  /// 注意：Discourse 预加载数据中没有 created_in_new_period 字段，
  /// 该值在网页版由客户端根据 created_at 计算。
  /// 但服务端 SQL 已过滤：last_read_post_number 为 null 的话题
  /// 一定是在用户 treat_as_new_topic_start_date 之后创建的，
  /// 所以此处当 last_read_post_number 为 null 时默认 createdInNewPeriod=true。
  factory TrackedTopicState.fromJson(Map<String, dynamic> json) {
    final lastRead = json['last_read_post_number'] as int?;
    return TrackedTopicState(
      topicId: json['topic_id'] as int,
      lastReadPostNumber: lastRead,
      highestPostNumber: (json['highest_post_number'] as int?) ?? 1,
      categoryId: json['category_id'] as int?,
      notificationLevel: (json['notification_level'] as int?) ?? 1,
      // 服务端已按 new_since 过滤，未读过的话题一定在新话题期限内
      createdInNewPeriod: json['created_in_new_period'] as bool? ?? (lastRead == null),
      isSeen: json['is_seen'] as bool? ?? false,
    );
  }
}

/// 全局话题追踪状态 Notifier
/// 对齐 Discourse 网页版的 topic-tracking-state.js
class TopicTrackingStateNotifier extends Notifier<Map<int, TrackedTopicState>> {
  bool _loadingPreloadedStates = false;

  @override
  Map<int, TrackedTopicState> build() {
    // 从预加载数据初始化
    final preloaded = PreloadedDataService();
    final states = preloaded.topicTrackingStatesSync;
    if (states != null) {
      return _buildPreloadedStateMap(states);
    }
    _loadPreloadedStatesAsync(preloaded);
    return {};
  }

  Map<int, TrackedTopicState> _buildPreloadedStateMap(
    List<Map<String, dynamic>> states,
  ) {
    final map = <int, TrackedTopicState>{};
    for (final json in states) {
      final tracked = TrackedTopicState.fromJson(json);
      map[tracked.topicId] = tracked;
    }
    // 调试：打印首条数据的字段和计数
    if (states.isNotEmpty) {
      debugPrint('[TopicTrackingState] 首条原始数据 keys: ${states.first.keys.toList()}');
      debugPrint('[TopicTrackingState] 首条原始数据: ${states.first}');
    }
    final newCount = map.values.where((s) => _isNew(s)).length;
    final unreadCount = map.values.where((s) => _isUnread(s)).length;
    debugPrint('[TopicTrackingState] 从预加载数据初始化 ${map.length} 条追踪状态, new=$newCount, unread=$unreadCount');
    return map;
  }

  void _loadPreloadedStatesAsync(PreloadedDataService preloaded) {
    if (_loadingPreloadedStates) return;
    _loadingPreloadedStates = true;
    unawaited(
      preloaded.getTopicTrackingStates().then((states) {
        _loadingPreloadedStates = false;
        if (!ref.mounted || states == null) return;
        final loaded = _buildPreloadedStateMap(states);
        state = state.isEmpty ? loaded : {...loaded, ...state};
      }).catchError((Object e, StackTrace st) {
        _loadingPreloadedStates = false;
        debugPrint('[TopicTrackingState] 异步加载预加载追踪状态失败: $e');
      }),
    );
  }

  /// 统计 NEW 话题数量（对齐网页版 countNew）
  int countNew({int? categoryId}) {
    return state.values.where((s) {
      if (categoryId != null && s.categoryId != categoryId) return false;
      return _isNew(s);
    }).length;
  }

  /// 统计 UNREAD 话题数量（对齐网页版 countUnread）
  int countUnread({int? categoryId}) {
    return state.values.where((s) {
      if (categoryId != null && s.categoryId != categoryId) return false;
      return _isUnread(s);
    }).length;
  }

  /// 判断是否为 NEW 话题（对齐网页版 isNew）
  /// 条件：未读过 + 在新话题期限内创建 +
  ///   (非静音且未看过 或 TRACKING 及以上)
  bool _isNew(TrackedTopicState s) {
    return s.lastReadPostNumber == null &&
        s.createdInNewPeriod &&
        ((s.notificationLevel != 0 && !s.isSeen) ||
            s.notificationLevel >= 2);
  }

  /// 判断是否为 UNREAD 话题（对齐网页版 isUnread）
  /// 条件：已读过 + 有新帖子 + TRACKING 或以上
  bool _isUnread(TrackedTopicState s) {
    return s.lastReadPostNumber != null &&
        s.lastReadPostNumber! < s.highestPostNumber &&
        s.notificationLevel >= 2;
  }

  /// 处理 MessageBus 频道消息，更新追踪状态
  /// 对齐 Discourse JS topic-tracking-state.js 的 _processChannelPayload
  void processChannelPayload(MessageBusMessage message) {
    final data = message.data;
    if (data is! Map<String, dynamic>) return;

    final messageType = data['message_type'] as String?;
    debugPrint('[TopicTrackingState] 处理消息: type=$messageType, channel=${message.channel}, data=$data');

    // dismiss_new / dismiss_new_posts 单独处理
    if (messageType == 'dismiss_new') {
      _handleDismissNew(data);
      return;
    }
    if (messageType == 'dismiss_new_posts') {
      _handleDismissNewPosts(data);
      return;
    }

    // new_topic / unread / read 统一处理（对齐网页版）
    if (messageType == 'new_topic' || messageType == 'unread' || messageType == 'read') {
      final topicId = data['topic_id'] as int?;
      if (topicId == null) return;

      final existing = state[topicId];

      // 合并 payload 到已有 state（对齐 deepMerge(old, data.payload)）
      final payload = data['payload'] as Map<String, dynamic>? ?? {};

      // 对于 unread 消息，补全缺失字段（对齐网页版推断逻辑）
      final highest = (payload['highest_post_number'] as int?) ?? existing?.highestPostNumber ?? 1;
      int? lastRead = payload['last_read_post_number'] as int?;
      int? notifLevel = payload['notification_level'] as int?;

      if (messageType == 'unread') {
        // /unread 频道的 payload 不含 last_read_post_number 和 notification_level
        // 推断：大概落后 1 个帖子，通知级别至少是 TRACKING
        lastRead ??= existing?.lastReadPostNumber ?? (highest - 1);
        notifLevel ??= existing?.notificationLevel ?? 2; // TRACKING
      } else {
        lastRead ??= existing?.lastReadPostNumber;
        notifLevel ??= existing?.notificationLevel ?? 1;
      }

      final categoryId = (payload['category_id'] as int?) ?? existing?.categoryId;
      final createdInNewPeriod = payload['created_in_new_period'] as bool?
          ?? existing?.createdInNewPeriod
          ?? (lastRead == null); // 未读过则视为新话题
      final isSeen = existing?.isSeen ?? false;

      state = {
        ...state,
        topicId: TrackedTopicState(
          topicId: topicId,
          lastReadPostNumber: lastRead,
          highestPostNumber: highest,
          categoryId: categoryId,
          notificationLevel: notifLevel,
          createdInNewPeriod: createdInNewPeriod,
          isSeen: isSeen,
        ),
      };
      return;
    }
  }

  /// 批量忽略新话题：设置 isSeen=true
  void _handleDismissNew(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>?;
    final topicIds = payload?['topic_ids'] as List?;
    if (topicIds == null || topicIds.isEmpty) {
      // 没有指定 topicIds，按分类忽略所有
      final categoryId = payload?['category_id'] as int?;
      final newState = Map<int, TrackedTopicState>.from(state);
      for (final entry in newState.entries) {
        if (_isNew(entry.value)) {
          if (categoryId == null || entry.value.categoryId == categoryId) {
            newState[entry.key] = entry.value.copyWith(isSeen: true);
          }
        }
      }
      state = newState;
    } else {
      final ids = topicIds.cast<int>().toSet();
      final newState = Map<int, TrackedTopicState>.from(state);
      for (final id in ids) {
        final existing = newState[id];
        if (existing != null) {
          newState[id] = existing.copyWith(isSeen: true);
        }
      }
      state = newState;
    }
  }

  /// 批量忽略未读帖子：将 lastReadPostNumber 设为 highestPostNumber
  void _handleDismissNewPosts(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>?;
    final topicIds = payload?['topic_ids'] as List?;
    if (topicIds == null || topicIds.isEmpty) {
      // 按分类忽略所有
      final categoryId = payload?['category_id'] as int?;
      final newState = Map<int, TrackedTopicState>.from(state);
      for (final entry in newState.entries) {
        if (_isUnread(entry.value)) {
          if (categoryId == null || entry.value.categoryId == categoryId) {
            newState[entry.key] = entry.value.copyWith(
              lastReadPostNumber: entry.value.highestPostNumber,
            );
          }
        }
      }
      state = newState;
    } else {
      final ids = topicIds.cast<int>().toSet();
      final newState = Map<int, TrackedTopicState>.from(state);
      for (final id in ids) {
        final existing = newState[id];
        if (existing != null && _isUnread(existing)) {
          newState[id] = existing.copyWith(
            lastReadPostNumber: existing.highestPostNumber,
          );
        }
      }
      state = newState;
    }
  }

  /// 本地阅读话题后更新追踪状态（减少 new/unread 计数）
  void updateTopicRead(int topicId, int lastReadPostNumber, int highestPostNumber) {
    final existing = state[topicId];
    if (existing != null) {
      final updated = existing.copyWith(
        lastReadPostNumber: lastReadPostNumber,
        highestPostNumber: highestPostNumber,
        isSeen: true,
      );
      state = {...state, topicId: updated};
    }
  }

  /// 忽略所有新话题（本地调用，用于 dismissAll 同步）
  void dismissNewTopics({int? categoryId}) {
    final newState = Map<int, TrackedTopicState>.from(state);
    for (final entry in newState.entries) {
      if (_isNew(entry.value)) {
        if (categoryId == null || entry.value.categoryId == categoryId) {
          newState[entry.key] = entry.value.copyWith(isSeen: true);
        }
      }
    }
    state = newState;
  }

  /// 忽略所有未读帖子（本地调用，用于 dismissAll 同步）
  void dismissUnreadTopics({int? categoryId}) {
    final newState = Map<int, TrackedTopicState>.from(state);
    for (final entry in newState.entries) {
      if (_isUnread(entry.value)) {
        if (categoryId == null || entry.value.categoryId == categoryId) {
          newState[entry.key] = entry.value.copyWith(
            lastReadPostNumber: entry.value.highestPostNumber,
          );
        }
      }
    }
    state = newState;
  }
}

final topicTrackingStateProvider =
    NotifierProvider<TopicTrackingStateNotifier, Map<int, TrackedTopicState>>(
  TopicTrackingStateNotifier.new,
);

/// MessageBus 初始化 Notifier
/// 统一管理所有频道的批量订阅，避免串行等待
class MessageBusInitNotifier extends Notifier<void> {
  final Map<String, MessageBusCallback> _allCallbacks = {};
  
  @override
  void build() {
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;
    final metaAsync = ref.watch(topicTrackingStateMetaProvider);
    
    // 清理之前的订阅
    if (_allCallbacks.isNotEmpty) {
      debugPrint('[MessageBusInit] 清理旧订阅: ${_allCallbacks.keys}');
      for (final entry in _allCallbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _allCallbacks.clear();
    }
    
    // 对齐 Discourse：long_polling_base_url 对匿名和登录用户都生效，
    // sharedSessionKey 仅在登录且跨域长轮询时存在。
    final preloaded = PreloadedDataService();
    messageBus.configure(
      baseUrl: preloaded.longPollingBaseUrl,
      sharedSessionKey: preloaded.sharedSessionKey,
    );

    if (currentUser == null) {
      debugPrint('[MessageBusInit] 用户未登录，仅配置公开频道轮询域名');
      return;
    }

    // 同步保存到 SharedPreferences 供 iOS 后台任务使用
    saveBackgroundMessageBusConfig(
      longPollingBaseUrl: preloaded.longPollingBaseUrl,
      sharedSessionKey: preloaded.sharedSessionKey,
    );

    final meta = metaAsync.value;
    if (meta == null) {
      debugPrint('[MessageBusInit] topicTrackingStateMeta 未加载');
      return;
    }
    
    // 逐个订阅话题追踪频道
    // 注意: /notification/ 和 /notification-alert/ 频道由专门的
    // NotificationChannelNotifier 和 NotificationAlertChannelNotifier 管理，
    // 此处只负责话题追踪频道
    debugPrint('[MessageBusInit] 订阅 ${meta.length} 个频道: ${meta.keys}');
    for (final entry in meta.entries) {
      final channel = entry.key;
      final messageId = entry.value as int;

      void onTopicTracking(MessageBusMessage message) {
        debugPrint('[TopicTracking] 收到消息: ${message.channel} #${message.messageId}');
        // 转发给 TopicTrackingStateNotifier 更新追踪计数
        ref.read(topicTrackingStateProvider.notifier).processChannelPayload(message);
      }

      _allCallbacks[channel] = onTopicTracking;
      messageBus.subscribeWithMessageId(channel, onTopicTracking, messageId);
    }
    
    ref.onDispose(() {
      debugPrint('[MessageBusInit] 取消所有订阅: ${_allCallbacks.keys}');
      for (final entry in _allCallbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _allCallbacks.clear();
    });
  }
}

final messageBusInitProvider = NotifierProvider<MessageBusInitNotifier, void>(
  MessageBusInitNotifier.new,
);

/// 话题列表新消息状态（按分类隔离）
class TopicListIncomingState {
  /// topicId → categoryId 的映射，用于按 tab/分类隔离新话题指示器
  final Map<int, int?> incomingTopics;

  const TopicListIncomingState({this.incomingTopics = const {}});

  bool get hasIncoming => incomingTopics.isNotEmpty;
  int get incomingCount => incomingTopics.length;

  /// 指定分类是否有新话题（null 表示"全部"tab，统计所有分类）
  bool hasIncomingForCategory(int? categoryId) {
    if (categoryId == null) return incomingTopics.isNotEmpty;
    return incomingTopics.values.any((c) => c == categoryId);
  }

  /// 获取指定分类的新话题数量（null 表示"全部"tab）
  int incomingCountForCategory(int? categoryId) {
    if (categoryId == null) return incomingTopics.length;
    return incomingTopics.values.where((c) => c == categoryId).length;
  }

  /// 获取指定分类的 incoming topic IDs（null 表示全部）
  List<int> incomingTopicIdsForCategory(int? categoryId) {
    if (categoryId == null) return incomingTopics.keys.toList();
    return incomingTopics.entries
        .where((e) => e.value == categoryId)
        .map((e) => e.key)
        .toList();
  }
}

/// 话题列表频道监听器（对齐 Discourse 网页版 TopicTrackingState）
///
/// 同时订阅 /latest 和 /new 两个频道：
/// - /latest 频道：message_type="latest"，表示已有话题收到新回复
/// - /new 频道：message_type="new_topic"，表示有新话题创建
///
/// 在 latest 页面中，两种消息都计入 incoming（同一 topic_id 去重）。
/// 与网页版一致，每条消息即时更新计数，不做防抖。
/// MessageBus 的 long polling 已自然做了批次化。
class LatestChannelNotifier extends Notifier<TopicListIncomingState> {

  @override
  TopicListIncomingState build() {
    // 确保 MessageBus 已 configure（域名配置），避免用主站域名轮询
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);

    // 构建静音分类 ID 集合（对齐网页版 muted_category_ids + indirectly_muted_category_ids）
    // 从分类列表的 notificationLevel 推导，结合本地覆盖实时反映用户修改
    final categoryMap = ref.watch(categoryMapProvider).value ?? {};
    final notifOverrides = ref.watch(categoryNotificationOverridesProvider);
    final mutedCategoryIds = <int>{};
    for (final category in categoryMap.values) {
      // 本地覆盖优先
      final level = notifOverrides[category.id] ?? category.notificationLevel;
      if (level == 0) {
        mutedCategoryIds.add(category.id);
      }
    }

    // 处理 /latest 和 /new 频道消息的统一回调
    void onMessage(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;

      final topicId = data['topic_id'] as int?;
      if (topicId == null) return;

      final messageType = data['message_type'] as String?;
      // 仅处理 latest（话题更新）和 new_topic（新话题创建）两种类型
      if (messageType != 'latest' && messageType != 'new_topic') return;

      // 同一 topic_id 去重（与网页版 _addIncoming 一致）
      if (state.incomingTopics.containsKey(topicId)) return;

      // 提取话题分类 ID（用于按 tab 隔离和静音过滤）
      final payload = data['payload'] as Map<String, dynamic>?;
      final topicCategoryId = payload?['category_id'] as int?;

      // 过滤静音分类（对齐网页版 _processChannelPayload 的 muted_category_ids 检查）
      if (topicCategoryId != null && mutedCategoryIds.contains(topicCategoryId)) {
        return;
      }

      debugPrint('[LatestChannel] incoming +1: type=$messageType, topicId=$topicId, category=$topicCategoryId');

      // 注意:不在此处转发给 TopicTrackingStateNotifier —— MessageBusInit
      // 已订阅含 /latest 在内的全部追踪频道并统一转发,此前这里的二次
      // 转发让每条 /latest 消息被同一状态机处理两遍(两次解析 + 两次
      // 通知 + 下游两次重建;滚动中即"帧开工晚"型掉帧的税源之一)

      // 即时更新（与网页版一致，无防抖）
      state = TopicListIncomingState(
        incomingTopics: {...state.incomingTopics, topicId: topicCategoryId},
      );
    }

    // 订阅 /latest 频道（话题更新）
    messageBus.subscribe('/latest', onMessage);
    // 订阅 /new 频道（新话题创建）
    messageBus.subscribe('/new', onMessage);

    ref.onDispose(() {
      messageBus.unsubscribe('/latest', onMessage);
      messageBus.unsubscribe('/new', onMessage);
    });

    return const TopicListIncomingState();
  }

  /// 按 topic IDs 清除 incoming（对齐网页版 clearIncoming）
  void clearIncoming(List<int> topicIds) {
    final toRemove = topicIds.toSet();
    final remaining = Map<int, int?>.from(state.incomingTopics)
      ..removeWhere((id, _) => toRemove.contains(id));
    if (remaining.length == state.incomingTopics.length) return;
    state = TopicListIncomingState(incomingTopics: remaining);
  }

  /// 清除指定分类的新话题标记（null 表示清除全部）
  void clearNewTopicsForCategory(int? categoryId) {
    if (categoryId == null) {
      state = const TopicListIncomingState();
    } else {
      final remaining = Map<int, int?>.from(state.incomingTopics)
        ..removeWhere((_, c) => c == categoryId);
      state = TopicListIncomingState(incomingTopics: remaining);
    }
  }
}

final latestChannelProvider = NotifierProvider<LatestChannelNotifier, TopicListIncomingState>(() {
  return LatestChannelNotifier();
});
