part of 'discourse_service.dart';

mixin _GroupsMixin on _DiscourseServiceBase {
  Future<GroupDirectoryResult> getGroups({
    String filter = '',
    String? type,
    GroupDirectoryOrder? order,
    bool ascending = true,
    int page = 0,
    String? username,
  }) async {
    final response = await _dio.get(
      '/groups.json',
      queryParameters: {
        'page': page,
        if (filter.isNotEmpty) 'filter': filter,
        'type': ?type,
        'username': ?username,
        if (order != null) ...{
          'order': order.apiValue,
          'asc': ascending.toString(),
        },
      },
    );
    return GroupDirectoryResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<UserGroupDetail> getGroup(String name) async {
    final response = await _dio.get('/g/${Uri.encodeComponent(name)}.json');
    return UserGroupDetail.fromJson(
      response.data['group'] as Map<String, dynamic>,
    );
  }

  Future<GroupMembersPage> getGroupMembers(
    String name, {
    String filter = '',
    int offset = 0,
    GroupMemberOrder? order,
    bool ascending = true,
  }) async {
    final response = await _dio.get(
      '/g/${Uri.encodeComponent(name)}/members.json',
      queryParameters: {
        'offset': offset,
        'limit': 50,
        if (filter.isNotEmpty) 'filter': filter,
        if (order != null) ...{
          'order': order.apiValue,
          'asc': ascending.toString(),
        },
      },
    );
    return GroupMembersPage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<GroupPostsPage> getGroupPosts(
    String name, {
    bool mentions = false,
    DateTime? before,
    int? categoryId,
  }) async {
    final response = await _dio.get(
      '/groups/${Uri.encodeComponent(name)}/${mentions ? 'mentions' : 'posts'}.json',
      queryParameters: {
        if (before != null) 'before': before.toUtc().toIso8601String(),
        'category_id': ?categoryId,
      },
    );
    return GroupPostsPage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<TopicListResponse> getGroupTopics(
    String name, {
    int page = 0,
    int? categoryId,
  }) async {
    final response = await _dio.get(
      '/topics/groups/${Uri.encodeComponent(name)}.json',
      queryParameters: {'page': page, 'category_id': ?categoryId},
    );
    return compute(
      _parseTopicListResponse,
      response.data as Map<String, dynamic>,
    );
  }

  Future<List<GroupCategoryPermission>> getGroupPermissions(String name) async {
    final response = await _dio.get(
      '/g/${Uri.encodeComponent(name)}/permissions.json',
    );
    return (response.data as List)
        .map(
          (item) =>
              GroupCategoryPermission.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> joinGroup(int id) =>
      _changeGroupMembership('/groups/$id/join.json', method: 'PUT');

  Future<void> leaveGroup(int id) =>
      _changeGroupMembership('/groups/$id/leave.json', method: 'DELETE');

  Future<String?> requestGroupMembership(String name, String reason) async {
    final result = await _changeGroupMembership(
      '/groups/${Uri.encodeComponent(name)}/request_membership.json',
      method: 'POST',
      data: {'reason': reason},
    );
    return result['relative_url'] as String?;
  }

  Future<Map<String, dynamic>> _changeGroupMembership(
    String path, {
    required String method,
    Map<String, dynamic>? data,
  }) async {
    final response = await _dio.request<dynamic>(
      path,
      data: data,
      options: Options(
        method: method,
        contentType: Headers.formUrlEncodedContentType,
        extra: {FluxRequestKeys.noRecovery: true},
      ),
    );
    if (response.data != null && response.data != '' && response.data is! Map) {
      throw const FormatException('Invalid group membership response');
    }
    final result = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (result['success'] == false ||
        result['failed'] != null ||
        result['error'] != null ||
        result['errors'] != null) {
      throw StateError(
        '${result['error'] ?? result['errors'] ?? result['message'] ?? S.current.group_actionFailed}',
      );
    }
    return result;
  }
}
