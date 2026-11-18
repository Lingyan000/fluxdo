import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification.dart';
import 'core_providers.dart';

/// 最近通知 Notifier（非分页，供快捷面板和 messageBus 使用）
class RecentNotificationsNotifier extends AsyncNotifier<List<DiscourseNotification>> {
  bool _reloadSilently = false;

  @override
  Future<List<DiscourseNotification>> build() async {
    final service = ref.read(discourseServiceProvider);
    final silent = _reloadSilently;
    _reloadSilently = false;
    final response = await service.getRecentNotifications(silent: silent);
    return response.notifications;
  }

  /// 添加新通知（由 messageBus 调用）
  /// 高优先级未读通知排在最前
  void addNotification(DiscourseNotification notification) {
    final currentList = state.value;
    if (currentList == null) return;

    // 检查是否已存在
    if (currentList.any((n) => n.id == notification.id)) return;

    final newList = List<DiscourseNotification>.from(currentList);

    // 高优先级且未读 → 插入到位置 0
    // 其他 → 插入到第一个非高优先级或已读通知的位置
    int insertPosition = 0;
    if (!notification.highPriority || notification.read) {
      final nextPosition = newList.indexWhere((n) => !n.highPriority || n.read);
      if (nextPosition != -1) {
        insertPosition = nextPosition;
      }
    }

    newList.insert(insertPosition, notification);
    state = AsyncValue.data(newList);
  }

  /// 根据 messageBus 推送的 recent 字段同步通知列表
  /// 复刻 Discourse 逻辑：更新已读状态 + 移除不在 recent 中的过期通知
  void syncWithRecent(Map<int, bool> readStatusMap) {
    final currentList = state.value;
    if (currentList == null) return;

    // 与 Discourse 对齐：只保留 recent 中存在的通知，同时更新已读状态
    final newList = <DiscourseNotification>[];
    for (final n in currentList) {
      final newRead = readStatusMap[n.id];
      if (newRead != null) {
        newList.add(newRead != n.read ? n.copyWith(read: newRead) : n);
      }
      // 不在 readStatusMap 中的通知被移除（过期）
    }

    if (newList.length != currentList.length ||
        newList.any((n) {
          final old = currentList.firstWhere((o) => o.id == n.id);
          return old.read != n.read;
        })) {
      state = AsyncValue.data(newList);
    }
  }

  /// 标记单个通知为已读
  void markAsRead(int notificationId) {
    state.whenData((list) {
      state = AsyncValue.data(
        list.map((n) {
          if (n.id == notificationId && !n.read) {
            return n.copyWith(read: true);
          }
          return n;
        }).toList(),
      );
    });
  }

  /// 更新已加载的通知；请求仍在途时，静默重读服务端的最新状态。
  void markLocalRead({Set<int>? typeIds}) {
    if (state.isLoading) {
      _reloadSilently = true;
      ref.invalidateSelf(asReload: true);
      return;
    }
    state.whenData((list) {
      state = AsyncValue.data([
        for (final n in list)
          if (!n.read &&
              (typeIds == null || typeIds.contains(n.notificationType.id)))
            n.copyWith(read: true)
          else
            n,
      ]);
    });
  }
}

final recentNotificationsProvider =
    AsyncNotifierProvider<RecentNotificationsNotifier, List<DiscourseNotification>>(() {
  return RecentNotificationsNotifier();
});

/// 通知面板分类，与网页通知面板的标签一致。[types] 为服务端通知类型名，
/// 「全部」为 null；「其他」由站点类型表减去其余分类推导，见 [typeNames]。
enum NotificationPanelTab {
  all(null),
  replies(['mentioned', 'group_mentioned', 'posted', 'quoted', 'replied']),
  likes(['liked', 'liked_consolidated', 'reaction']),
  messages(['private_message', 'group_message_summary']),
  bookmarks(['bookmark_reminder']),
  other(null);

  const NotificationPanelTab(this.types);
  final List<String>? types;

  /// 本分类包含的类型名，只保留站点存在的类型；「全部」返回 null
  List<String>? typeNames(Map<String, int> siteTypes) {
    if (this == all) return null;
    if (this == other) {
      final used = {
        for (final tab in values)
          if (tab.types != null) ...tab.types!,
      };
      return [
        for (final name in siteTypes.keys)
          if (!used.contains(name)) name,
      ];
    }
    return [
      for (final name in types!)
        if (siteTypes.containsKey(name)) name,
    ];
  }

  /// 本分类的未读数，「全部」返回 null
  int? unreadCount(Map<String, int> siteTypes, Map<int, int> grouped) {
    final names = typeNames(siteTypes);
    if (names == null) return null;
    var sum = 0;
    for (final name in names) {
      sum += grouped[siteTypes[name]] ?? 0;
    }
    return sum;
  }
}

/// 通知面板某个分类的最近通知（非分页）。推送到达时按类型并入新通知、
/// 同步已读状态；列表只含本分类，不按全局 recent 移除旧条目。
class CategorizedNotificationsNotifier
    extends AsyncNotifier<List<DiscourseNotification>> {
  CategorizedNotificationsNotifier(this.tab);

  final NotificationPanelTab tab;
  Set<int> _typeIds = const {};
  List<String> _typeNames = const [];

  @override
  Future<List<DiscourseNotification>> build() async {
    final siteTypes = await ref.watch(siteNotificationTypesProvider.future);
    _typeNames = tab.typeNames(siteTypes) ?? const [];
    _typeIds = {for (final name in _typeNames) ?siteTypes[name]};
    if (_typeNames.isEmpty) return const [];
    final response = await ref
        .read(discourseServiceProvider)
        .getRecentNotifications(types: _typeNames);
    return response.notifications;
  }

  /// 推送的新通知属于本分类时插到最前
  void addIfMatches(DiscourseNotification notification) {
    final list = state.value;
    if (list == null ||
        !_typeIds.contains(notification.notificationType.id) ||
        list.any((n) => n.id == notification.id)) {
      return;
    }
    state = AsyncValue.data([notification, ...list]);
  }

  /// 按推送的 recent 已读状态更新本分类中对应条目
  void applyReadStatus(Map<int, bool> readStatusMap) {
    final list = state.value;
    if (list == null) return;
    var changed = false;
    final next = list.map((n) {
      final read = readStatusMap[n.id];
      if (read == null || read == n.read) return n;
      changed = true;
      return n.copyWith(read: read);
    }).toList();
    if (changed) state = AsyncValue.data(next);
  }

  void markAsRead(int notificationId) =>
      applyReadStatus({notificationId: true});

  void markAllLocalRead() {
    if (state.isLoading) {
      // 旧请求可能返回标记前的快照；分类重查为 silent，不推进已看位置。
      ref.invalidateSelf(asReload: true);
      return;
    }
    state.whenData((list) {
      if (list.every((n) => n.read)) return;
      state = AsyncValue.data([for (final n in list) n.copyWith(read: true)]);
    });
  }

  /// 只把本分类标为已读
  Future<void> markAllAsRead() async {
    if (_typeNames.isEmpty) return;
    final requestRef = ref;
    await requestRef
        .read(discourseServiceProvider)
        .markNotificationsReadByTypes(_typeNames);
    if (!requestRef.mounted) return;
    // 计数由服务端推送校正。
    if (ref.read(recentNotificationsProvider.exists)) {
      ref.read(recentNotificationsProvider.notifier).markLocalRead(
        typeIds: _typeIds,
      );
    }
    markAllLocalRead();
  }
}

final categorizedNotificationsProvider = AsyncNotifierProvider.family
    .autoDispose<
      CategorizedNotificationsNotifier,
      List<DiscourseNotification>,
      NotificationPanelTab
    >(CategorizedNotificationsNotifier.new);

/// 通知面板当前分类。标题栏的「全部已读」按当前分类生效，面板打开时回到「全部」
class NotificationPanelTabNotifier extends Notifier<NotificationPanelTab> {
  @override
  NotificationPanelTab build() => NotificationPanelTab.all;

  void select(NotificationPanelTab tab) => state = tab;
}

final notificationPanelTabProvider =
    NotifierProvider<NotificationPanelTabNotifier, NotificationPanelTab>(
      NotificationPanelTabNotifier.new,
    );
