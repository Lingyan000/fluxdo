part of 'discourse_service.dart';

/// 用户相关
mixin _UsersMixin on _DiscourseServiceBase {
  /// 后台用户请求走现有调度器的低优先级静默通道。
  ///
  /// 仍复用主站 Dio、Cookie、代理和 CF 会话，只让前台普通请求在排队时
  /// 优先执行，避免创建第二套网络身份。
  Options? _userRequestOptions(bool isSilent) {
    if (!isSilent) return null;
    return Options(
      extra: const {
        'isSilent': true,
        // 通道标注只需进网络日志(_networkLogFields 是日志拦截器的读取口);
        // 顶层同名键无人消费,不再重复写。
        '_networkLogFields': {'requestLane': 'seeking'},
      },
    );
  }

  /// 获取缓存的用户名
  Future<String?> getUsername() async {
    if (_username != null && _username!.isNotEmpty) return _username;

    _username = await _storage.read(key: DiscourseService._usernameKey);
    if (_username != null && _username!.isNotEmpty) return _username;

    try {
      final preloaded = PreloadedDataService();
      final currentUser = await preloaded.getCurrentUser();
      if (currentUser != null && currentUser['username'] != null) {
        _username = currentUser['username'] as String;
        await _storage.write(
          key: DiscourseService._usernameKey,
          value: _username!,
        );
        return _username;
      }
    } catch (e) {
      debugPrint('[DIO] Failed to get username from preloaded: $e');
    }

    return null;
  }

  /// 获取用户信息
  Future<User> getUser(String username, {bool isSilent = false}) async {
    final activeRequest = _activeUserRequests[username];
    if (activeRequest != null) return activeRequest;

    late final Future<User> request;
    request = _fetchUser(username, isSilent: isSilent).whenComplete(() {
      if (identical(_activeUserRequests[username], request)) {
        _activeUserRequests.remove(username);
      }
    });
    _activeUserRequests[username] = request;
    return request;
  }

  Future<User> _fetchUser(String username, {required bool isSilent}) async {
    final response = await _dio.get(
      '/u/$username.json',
      options: _userRequestOptions(isSilent),
    );
    final data = response.data as Map<String, dynamic>;
    return User.fromJson(data['user'] ?? data);
  }

  /// 获取用户卡片数据（card serializer，对应网页版 user-card）。
  ///
  /// 与 [getUser] 区别：走 `/u/{username}/card.json`，由 `UserCardSerializer` 渲染——
  /// 含 `card_background_upload_url`（卡片背景，完整资料页 serializer 不返回）、
  /// `bio_excerpt`（摘要简介）、`topic_post_count` 等卡片专用字段，且更轻量。
  ///
  /// [includePostCountFor] 传话题 id 时响应注入该用户在此话题内的发帖数
  /// (topic_post_count),卡片据此决定是否显示「只看 TA」过滤按钮。
  Future<User> getUserCard(String username, {int? includePostCountFor}) async {
    final response = await _dio.get(
      '/u/$username/card.json',
      queryParameters: {'include_post_count_for': ?includePostCountFor},
    );
    final data = response.data as Map<String, dynamic>;
    return User.fromJson(data['user'] ?? data);
  }

  /// 从预加载数据获取当前用户
  Future<User?> getPreloadedCurrentUser() async {
    try {
      final preloaded = PreloadedDataService();
      final currentUserData = await preloaded.getCurrentUser();
      if (currentUserData != null) {
        final user = User.fromJson(currentUserData);
        currentUserNotifier.value = user;
        if (user.username.isNotEmpty) {
          _username = user.username;
          await _storage.write(
            key: DiscourseService._usernameKey,
            value: _username!,
          );
        }
        return user;
      }
    } catch (e) {
      debugPrint('[DiscourseService] getPreloadedCurrentUser failed: $e');
    }
    return null;
  }

  /// 获取当前用户信息
  /// 网络错误时会抛出异常，由调用方决定如何处理
  Future<User?> getCurrentUser() async {
    final username = await getUsername();
    if (username == null) return null;

    final user = await getUser(username);
    currentUserNotifier.value = user;
    return user;
  }

  /// 获取用户统计数据（带缓存，按用户名区分）
  Future<UserSummary> getUserSummary(
    String username, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _cachedUserSummary != null &&
        _cachedUserSummaryUsername == username &&
        _userSummaryCacheTime != null &&
        DateTime.now().difference(_userSummaryCacheTime!) <
            DiscourseService._summaryCacheDuration) {
      return _cachedUserSummary!;
    }

    final activeRequest = _activeUserSummaryRequests[username];
    if (activeRequest != null) return activeRequest;

    late final Future<UserSummary> request;
    request = _fetchUserSummary(username).whenComplete(() {
      if (identical(_activeUserSummaryRequests[username], request)) {
        _activeUserSummaryRequests.remove(username);
      }
    });
    _activeUserSummaryRequests[username] = request;
    return request;
  }

  Future<UserSummary> _fetchUserSummary(String username) async {
    final response = await _dio.get('/u/$username/summary.json');
    final summary = UserSummary.fromJson(response.data);

    _cachedUserSummary = summary;
    _cachedUserSummaryUsername = username;
    _userSummaryCacheTime = DateTime.now();

    return summary;
  }

  /// 获取用户动态
  Future<UserActionResponse> getUserActions(
    String username, {
    String? filter,
    int offset = 0,
    bool isSilent = false,
  }) async {
    final queryParams = <String, dynamic>{
      'username': username,
      'offset': offset,
    };
    if (filter != null) {
      queryParams['filter'] = filter;
    }
    final response = await _dio.get(
      '/user_actions.json',
      queryParameters: queryParams,
      options: _userRequestOptions(isSilent),
    );
    return UserActionResponse.fromJson(response.data);
  }

  /// 获取用户回应列表
  Future<UserReactionsResponse> getUserReactions(
    String username, {
    int? beforeReactionUserId,
    bool isSilent = false,
  }) async {
    final queryParams = <String, dynamic>{'username': username};
    if (beforeReactionUserId != null) {
      queryParams['before_reaction_user_id'] = beforeReactionUserId;
    }
    final response = await _dio.get(
      '/discourse-reactions/posts/reactions.json',
      queryParameters: queryParams,
      options: _userRequestOptions(isSilent),
    );
    return UserReactionsResponse.fromJson(response.data);
  }

  /// 获取用户发出的 Boost 列表（discourse-boosts 插件，游标分页每页 20）
  Future<UserBoostsResponse> getUserBoostsGiven(
    String username, {
    int? beforeBoostId,
    bool isSilent = false,
  }) async {
    final response = await _dio.get(
      '/discourse-boosts/users/$username/boosts-given.json',
      queryParameters: beforeBoostId != null
          ? {'before_boost_id': beforeBoostId}
          : null,
      options: _userRequestOptions(isSilent),
    );
    return UserBoostsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// 获取用户投过票的话题列表（discourse-topic-voting 插件，标准话题列表分页）
  Future<TopicListResponse> getVotedTopics(
    String username, {
    int page = 0,
  }) async {
    final response = await _dio.get(
      '/topics/voted-by/$username.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户被采纳为答案的帖子列表（discourse-solved 插件，offset 分页每页 30）
  Future<SolvedPostsResponse> getUserSolvedPosts(
    String username, {
    int offset = 0,
  }) async {
    final response = await _dio.get(
      '/solution/by_user.json',
      queryParameters: {'username': username, 'offset': offset},
    );
    return SolvedPostsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// 获取用户关注列表
  Future<List<FollowUser>> getFollowing(String username) async {
    final response = await _dio.get('/u/$username/follow/following');
    return (response.data as List)
        .map((json) => FollowUser.fromJson(json))
        .toList();
  }

  /// 获取用户粉丝列表
  Future<List<FollowUser>> getFollowers(String username) async {
    final response = await _dio.get('/u/$username/follow/followers');
    return (response.data as List)
        .map((json) => FollowUser.fromJson(json))
        .toList();
  }

  /// 关注用户
  Future<void> followUser(String username) async {
    try {
      await _dio.put('/follow/$username');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消关注用户
  Future<void> unfollowUser(String username) async {
    try {
      await _dio.delete('/follow/$username');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 设置用户订阅级别（normal/mute/ignore）
  Future<void> updateUserNotificationLevel(
    String username, {
    required String level,
    String? expiringAt,
  }) async {
    await _dio.put(
      '/u/$username/notification_level.json',
      data: {
        'notification_level': level,
        ...?(expiringAt == null ? null : {'expiring_at': expiringAt}),
      },
    );
  }

  /// 获取私信列表（收件箱）
  Future<TopicListResponse> getPrivateMessages({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception(S.current.error_notLoggedInNoUsername);
    }
    final response = await _dio.get(
      '/topics/private-messages/$username.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取已发送私信
  Future<TopicListResponse> getPrivateMessagesSent({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception(S.current.error_notLoggedInNoUsername);
    }
    final response = await _dio.get(
      '/topics/private-messages-sent/$username.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取归档私信
  Future<TopicListResponse> getPrivateMessagesArchive({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception(S.current.error_notLoggedInNoUsername);
    }
    final response = await _dio.get(
      '/topics/private-messages-archive/$username.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户浏览历史
  Future<TopicListResponse> getBrowsingHistory({int page = 0}) async {
    final response = await _dio.get(
      '/read.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户个人书签
  Future<TopicListResponse> getUserBookmarks({int page = 0, int? limit}) async {
    final response = await _getUserBookmarksRaw(page: page, limit: limit);
    return TopicListResponse.fromJson(response);
  }

  /// 拉书签接口并返回原始 JSON map，给本地缓存对账层使用——
  /// 需要保留每条书签自身的 updated_at 等字段，无法通过 [TopicListResponse] 转回。
  Future<Map<String, dynamic>> getUserBookmarksRaw({
    int page = 0,
    int? limit,
  }) {
    return _getUserBookmarksRaw(page: page, limit: limit);
  }

  Future<Map<String, dynamic>> _getUserBookmarksRaw({
    required int page,
    required int? limit,
  }) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception(S.current.error_notLoggedInNoUsername);
    }
    final queryParameters = <String, dynamic>{};
    if (page > 0) {
      queryParameters['page'] = page;
    }
    if (limit != null) {
      // Discourse 书签接口单页上限是 20，超过会直接返回 invalid_parameters。
      if (limit > 0) {
        queryParameters['limit'] = limit > 20 ? 20 : limit;
      }
    }
    final response = await _dio.get(
      '/u/$username/bookmarks.json',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// 获取用户创建的话题
  Future<TopicListResponse> getUserCreatedTopics({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception(S.current.error_notLoggedInNoUsername);
    }
    final response = await _dio.get(
      '/topics/created-by/$username.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户徽章列表
  Future<BadgeDetailResponse> getUserBadges({required String username}) async {
    final response = await _dio.get(
      '/user-badges/${username.toLowerCase()}.json',
      queryParameters: {'grouped': 'true'},
    );
    return BadgeDetailResponse.fromJson(response.data);
  }

  /// 获取徽章信息
  Future<Badge> getBadge({required int badgeId}) async {
    final response = await _dio.get('/badges/$badgeId.json');
    final badgeData = response.data['badge'] as Map<String, dynamic>;
    return Badge.fromJson(badgeData);
  }

  /// 获取徽章的所有获得者
  Future<BadgeDetailResponse> getBadgeUsers({
    required int badgeId,
    String? username,
  }) async {
    final queryParams = <String, dynamic>{'badge_id': badgeId};
    if (username != null) {
      queryParams['username'] = username;
    }

    final response = await _dio.get(
      '/user_badges.json',
      queryParameters: queryParams,
    );

    return BadgeDetailResponse.fromJson(response.data);
  }

  /// 获取待使用的邀请链接
  Future<List<InviteLinkResponse>> getPendingInvites(String username) async {
    try {
      final response = await _dio.get('/u/$username/invited/pending');
      return _parsePendingInvites(response.data);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  List<InviteLinkResponse> _parsePendingInvites(dynamic data) {
    final items = <dynamic>[];
    if (data is List) {
      items.addAll(data);
    } else if (data is Map) {
      final invites =
          data['invites'] ??
          data['pending_invites'] ??
          data['invited'] ??
          data['pending'];
      if (invites is List) {
        items.addAll(invites);
      } else if (data['invite'] is Map ||
          data['invite_link'] is String ||
          data['invite_key'] is String) {
        items.add(data);
      }
    }

    final results = <InviteLinkResponse>[];
    for (final item in items) {
      if (item is Map) {
        results.add(
          _inviteResponseFromPendingItem(Map<String, dynamic>.from(item)),
        );
      }
    }
    return results;
  }

  InviteLinkResponse _inviteResponseFromPendingItem(Map<String, dynamic> item) {
    final payload = Map<String, dynamic>.from(item);
    if (!payload.containsKey('invite_link')) {
      final url = payload['invite_url'] ?? payload['url'] ?? payload['link'];
      if (url is String) {
        payload['invite_link'] = url;
      }
    }
    if (payload.containsKey('invite') || payload.containsKey('invite_link')) {
      return InviteLinkResponse.fromJson(payload);
    }
    return InviteLinkResponse.fromJson({
      'invite_link': payload['invite_link'],
      'invite': payload,
    });
  }

  /// 生成邀请链接
  Future<InviteLinkResponse> createInviteLink({
    required int maxRedemptionsAllowed,
    DateTime? expiresAt,
    String? description,
    String? email,
  }) async {
    final response = await _dio.post(
      '/invites',
      data: {
        'max_redemptions_allowed': maxRedemptionsAllowed,
        if (expiresAt != null)
          'expires_at': expiresAt.toUtc().toIso8601String(),
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      },
    );
    return InviteLinkResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
