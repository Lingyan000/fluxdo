part of 'discourse_service.dart';

/// 用户相关
mixin _UsersMixin on _DiscourseServiceBase {
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
  Future<User> getUser(String username) async {
    final response = await _dio.get('/u/$username.json');
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
    );
    return UserActionResponse.fromJson(response.data);
  }

  /// 获取用户回应列表
  Future<UserReactionsResponse> getUserReactions(
    String username, {
    int? beforeReactionUserId,
  }) async {
    final queryParams = <String, dynamic>{'username': username};
    if (beforeReactionUserId != null) {
      queryParams['before_reaction_user_id'] = beforeReactionUserId;
    }
    final response = await _dio.get(
      '/discourse-reactions/posts/reactions.json',
      queryParameters: queryParams,
    );
    return UserReactionsResponse.fromJson(response.data);
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
        if (expiringAt case final expiringAt?) 'expiring_at': expiringAt,
      },
    );
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
  Future<TopicListResponse> getUserBookmarks({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception('未登录或无法获取用户名');
    }
    final response = await _dio.get(
      '/u/$username/bookmarks.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户创建的话题
  Future<TopicListResponse> getUserCreatedTopics({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception('未登录或无法获取用户名');
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

  InviteLinkResponse _inviteResponseFromPendingItem(
    Map<String, dynamic> item,
  ) {
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
    try {
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
    } on DioException catch (e) {
      rethrow;
    }
  }
}
