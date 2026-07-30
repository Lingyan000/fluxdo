part of 'discourse_service.dart';

/// 指定(discourse-assign 插件)相关。核对过插件源码 config/routes.rb:
/// 挂载在 `/assign` 下,`assign`/`unassign` 走 PUT,`suggestions` 走 GET。
/// `target_type` 目前站内只用到 `'Topic'`(帖子级指定用得少,先不做)。
mixin _AssignMixin on _DiscourseServiceBase {
  /// 指定给某个用户或群组。[username]/[groupName] 二选一。
  Future<void> assignTarget({
    required int targetId,
    String targetType = 'Topic',
    String? username,
    String? groupName,
    String? note,
    String? status,
    bool shouldNotify = true,
  }) async {
    assert(
      (username != null) != (groupName != null),
      'assignTarget: username 和 groupName 必须二选一',
    );
    try {
      await _dio.put(
        '/assign/assign',
        data: {
          'target_id': targetId,
          'target_type': targetType,
          if (username != null) 'username': username,
          if (groupName != null) 'group_name': groupName,
          if (note != null) 'note': note,
          if (status != null) 'status': status,
          'should_notify': shouldNotify,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消指定。
  Future<void> unassignTarget({
    required int targetId,
    String targetType = 'Topic',
  }) async {
    try {
      await _dio.put(
        '/assign/unassign',
        data: {'target_id': targetId, 'target_type': targetType},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 指定弹窗的候选用户列表(含最近指定过的人,插件自带排序)。
  Future<AssignSuggestions> fetchAssignSuggestions() async {
    try {
      final response = await _dio.get('/assign/suggestions');
      return AssignSuggestions.fromJson(
        response.data as Map<String, dynamic>,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }
}
