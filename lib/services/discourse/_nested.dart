part of 'discourse_service.dart';

/// 嵌套视图（树形话题）相关 API
mixin _NestedMixin on _DiscourseServiceBase {
  /// 获取根帖子列表
  /// GET /n/topic/:topic_id.json?sort=old&page=0&track_visit=true
  Future<NestedRootsResponse> getNestedRoots(
    int topicId, {
    String sort = 'old',
    int page = 0,
    bool trackVisit = false,
  }) async {
    final response = await _dio.get(
      '/n/topic/$topicId.json',
      queryParameters: {
        'sort': sort,
        'page': page,
        if (trackVisit) 'track_visit': true,
      },
    );
    return NestedRootsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// 获取指定楼层的上下文（祖先链 + 目标帖子树），用于通知等带楼层进入的定位场景
  /// GET /n/topic/:topic_id/context/:postNumber.json?sort=old&track_visit=true
  Future<NestedContextResponse> getNestedContext(
    int topicId,
    int postNumber, {
    String sort = 'old',
    bool trackVisit = false,
  }) async {
    final response = await _dio.get(
      '/n/topic/$topicId/context/$postNumber.json',
      queryParameters: {
        'sort': sort,
        if (trackVisit) 'track_visit': true,
      },
    );
    return NestedContextResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// 获取子回复
  /// GET /n/topic/:topic_id/children/:postNumber.json?sort=old&page=0&depth=1
  Future<NestedChildrenResponse> getNestedChildren(
    int topicId,
    int postNumber, {
    String sort = 'old',
    int page = 0,
    int depth = 1,
  }) async {
    final response = await _dio.get(
      '/n/topic/$topicId/children/$postNumber.json',
      queryParameters: {
        'sort': sort,
        'page': page,
        'depth': depth,
      },
    );
    return NestedChildrenResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
