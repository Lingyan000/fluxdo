part of 'discourse_service.dart';

/// 通知相关
mixin _NotificationsMixin on _DiscourseServiceBase {
  /// 获取最近通知（recent 模式，非分页，用于快捷面板）
  /// 会触发服务端 bump_last_seen_notification，重置未读计数
  ///
  /// 传入 [types]（服务端通知类型名）时只取这些类型，并以 silent 请求，
  /// 不推进已读位置，与网页通知面板的分类标签一致。
  Future<NotificationListResponse> getRecentNotifications({
    List<String>? types,
    bool silent = false,
  }) async {
    final response = await _dio.get('/notifications', queryParameters: {
      'recent': true,
      'limit': 30,
      'bump_last_seen_reviewable': true,
      if (types != null && types.isNotEmpty) 'filter_by_types': types.join(','),
      if (silent || (types != null && types.isNotEmpty)) 'silent': true,
    });
    return NotificationListResponse.fromJson(response.data);
  }

  /// 获取通知列表（默认模式，支持完整分页）
  ///
  /// [filter] 为 `read` / `unread` 时只返回对应已读状态；服务端分页模式
  /// 不支持按类型筛选。
  Future<NotificationListResponse> getNotifications({
    int? offset,
    String? filter,
  }) async {
    final queryParams = <String, dynamic>{
      'limit': 60,
    };
    if (offset != null) {
      queryParams['offset'] = offset;
    }
    if (filter != null) {
      queryParams['filter'] = filter;
    }

    final response = await _dio.get(
      '/notifications',
      queryParameters: queryParams,
    );
    return NotificationListResponse.fromJson(response.data);
  }

  /// 标记所有通知为已读
  Future<void> markAllNotificationsRead() async {
    await _dio.put('/notifications/mark-read');
  }

  /// 将指定类型（服务端通知类型名）的通知全部标为已读
  Future<void> markNotificationsReadByTypes(List<String> types) async {
    await _dio.put(
      '/notifications/mark-read',
      data: {'dismiss_types': types.join(',')},
    );
  }

  /// 标记单条通知为已读
  Future<void> markNotificationRead(int id) async {
    await _dio.put('/notifications/mark-read', data: {'id': id});
  }
}
