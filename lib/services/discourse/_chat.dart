part of 'discourse_service.dart';

/// Chat 相关 API
mixin _ChatMixin on _DiscourseServiceBase {
  /// 获取当前用户的 Chat 频道列表
  Future<Map<String, dynamic>> getChatChannels() async {
    final response = await _dio.get('/chat/api/me/channels');
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// 获取指定频道的消息列表
  ///
  /// [direction] 可选值: 'past' | 'future' (对齐 Discourse messages_query)
  /// - 'past': 返回 target_message_id 之前的消息（不含 target）
  /// - 'future': 返回 target_message_id 之后的消息
  Future<Map<String, dynamic>> getChannelMessages(
    int channelId, {
    int? pageSize,
    int? targetMessageId,
    String? direction,
    bool? fetchFromLastRead,
  }) async {
    final queryParameters = <String, dynamic>{};
    if (pageSize != null) queryParameters['page_size'] = pageSize;
    if (targetMessageId != null) {
      queryParameters['target_message_id'] = targetMessageId;
    }
    if (direction != null) queryParameters['direction'] = direction;
    if (fetchFromLastRead != null) {
      queryParameters['fetch_from_last_read'] = fetchFromLastRead;
    }
    final response = await _dio.get(
      '/chat/api/channels/$channelId/messages',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// 发送 Chat 消息
  ///
  /// 返回服务端分配的 [message_id]
  Future<int> sendChatMessage(
    int channelId,
    String message, {
    int? threadId,
    int? inReplyToId,
    List<int>? uploadIds,
    String? stagedId,
  }) async {
    final data = <String, dynamic>{
      'message': message,
      'chat_channel_id': channelId,
    };
    if (threadId != null) data['thread_id'] = threadId;
    if (inReplyToId != null) data['in_reply_to_id'] = inReplyToId;
    if (uploadIds != null && uploadIds.isNotEmpty) {
      data['upload_ids'] = uploadIds;
    }
    if (stagedId != null) data['staged_id'] = stagedId;

    try {
      Response response;
      // 对齐 Discourse 官方前端 chat-api: POST /chat/:channelId
      // (plugins/chat/config/routes.rb: post "/:chat_channel_id" => "api/channel_messages#create")
      try {
        response = await _dio.post(
          '/chat/$channelId',
          data: data,
        );
      } catch (_) {
        try {
          response = await _dio.post(
            '/chat/api/channels/$channelId/messages',
            data: data,
          );
        } catch (_) {
          response = await _dio.post(
            '/chat/chat_channels/$channelId/messages.json',
            data: data,
          );
        }
      }

      final respData = Map<String, dynamic>.from(response.data as Map);
      final msgObj = respData['chat_message'] is Map
          ? respData['chat_message'] as Map
          : null;
      return (respData['message_id'] as num?)?.toInt() ??
          (msgObj?['id'] as num?)?.toInt() ??
          (respData['id'] as num?)?.toInt() ??
          0;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 编辑 Chat 消息
  Future<void> updateChatMessage(
    int channelId,
    int messageId,
    String message,
  ) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/messages/$messageId',
        data: {'message': message, 'chat_channel_id': channelId},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 删除 Chat 消息
  Future<void> deleteChatMessage(int channelId, int messageId) async {
    try {
      await _dio.delete(
        '/chat/api/channels/$channelId/messages/$messageId',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 标记频道已读
  ///
  /// 对齐 Discourse chat-api.markChannelAsRead:
  /// PUT /chat/api/channels/:id/read?message_id=
  Future<void> markChannelRead(int channelId, int messageId) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/read',
        queryParameters: {'message_id': messageId},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 创建直接消息频道
  ///
  /// 返回新创建的频道 [id]
  ///
  /// 对齐 Discourse `Chat::CreateDirectMessageChannel` /
  /// `POST /chat/api/direct-message-channels`：
  /// - [targetUsernames]：对方用户名（服务端会自动并入当前用户）
  /// - [name]：群聊可选名称；人数>2 或提供 name 时服务端记为 group DM
  /// - [targetGroups]：可选，按组名展开成员（可见且成员可见的组）
  ///
  /// 客户端不限制 [targetUsernames] 的人数；若服务端拒绝请求，错误会原样上抛。
  ///
  /// Discourse 响应根为 `channel`（Chat::ChannelSerializer）。
  Future<int> createDirectMessageChannel(
    List<String> targetUsernames, {
    String? name,
    List<String>? targetGroups,
  }) async {
    final data = <String, dynamic>{
      'target_usernames': targetUsernames,
    };
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isNotEmpty) {
      data['name'] = trimmedName;
    }
    if (targetGroups != null && targetGroups.isNotEmpty) {
      data['target_groups'] = targetGroups;
    }

    final response = await _dio.post(
      '/chat/api/direct-message-channels',
      data: data,
    );
    final respData = Map<String, dynamic>.from(response.data as Map);
    final channel = respData['channel'] is Map
        ? Map<String, dynamic>.from(respData['channel'] as Map)
        : respData;
    return (channel['id'] as num?)?.toInt() ??
        (respData['id'] as num?)?.toInt() ??
        0;
  }

  /// 获取单个 Chat 频道详情
  ///
  /// 对齐 Discourse chat-api: GET /chat/api/channels/:id
  Future<Map<String, dynamic>> getChatChannel(int channelId) async {
    try {
      final response = await _dio.get('/chat/api/channels/$channelId');
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 创建公开（分类）频道
  ///
  /// 对齐 Discourse chat-api.createChannel:
  /// POST /chat/api/channels  body: { channel: { name, chatable_id, ... } }
  /// 权限：Guardian#can_create_chat_channel? → staff
  Future<Map<String, dynamic>> createChannel({
    required String name,
    required int chatableId,
    String? slug,
    String? description,
    String? emoji,
    bool autoJoinUsers = false,
    bool threadingEnabled = false,
  }) async {
    final channel = <String, dynamic>{
      'name': name,
      'chatable_id': chatableId,
      'auto_join_users': autoJoinUsers,
      'threading_enabled': threadingEnabled,
    };
    if (slug != null && slug.isNotEmpty) channel['slug'] = slug;
    if (description != null) channel['description'] = description;
    if (emoji != null && emoji.isNotEmpty) channel['emoji'] = emoji;

    try {
      final response = await _dio.post(
        '/chat/api/channels',
        data: {'channel': channel},
      );
      final respData = Map<String, dynamic>.from(response.data as Map);
      if (respData['channel'] is Map) {
        return Map<String, dynamic>.from(respData['channel'] as Map);
      }
      return respData;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 搜索 Chat 可提及用户/频道
  ///
  /// 对齐 Discourse Chat::SearchChatable：查询参数为 [term]（不是 filter）。
  Future<Map<String, dynamic>> searchChatables(String term) async {
    final response = await _dio.get(
      '/chat/api/chatables',
      queryParameters: {
        'term': term,
        'include_users': true,
        'include_groups': false,
        'include_category_channels': false,
        'include_direct_message_channels': false,
      },
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// 在频道内搜索消息
  ///
  /// 对齐 Discourse: GET /chat/api/search
  /// 参数: query, channel_id, limit, offset, sort
  Future<Map<String, dynamic>> searchChannelMessages({
    required String query,
    int? channelId,
    int limit = 20,
    int offset = 0,
    String sort = 'latest',
  }) async {
    final queryParameters = <String, dynamic>{
      'query': query,
      'limit': limit.clamp(1, 40),
      'offset': offset,
      'sort': sort,
    };
    if (channelId != null) {
      queryParameters['channel_id'] = channelId;
    }
    try {
      final response = await _dio.get(
        '/chat/api/search',
        queryParameters: queryParameters,
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取指定频道的成员列表（分页）
  ///
  /// 对齐 Discourse: GET /chat/api/channels/:id/memberships
  /// 过滤参数为 [username]（非 filter）；limit 最大 50。
  ///
  /// 返回 members + totalRows（meta.total_rows，大频道用此显示真实人数）。
  Future<({List<Map<String, dynamic>> members, int? totalRows, bool hasMore})>
      getChannelMembersPage(
    int channelId, {
    String? filter,
    String? username,
    int limit = 50,
    int offset = 0,
  }) async {
    final clampedLimit = limit.clamp(1, 50);
    final queryParameters = <String, dynamic>{
      'limit': clampedLimit,
      'offset': offset,
    };
    final nameFilter = username ?? filter;
    if (nameFilter != null && nameFilter.isNotEmpty) {
      queryParameters['username'] = nameFilter;
    }

    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/memberships',
        queryParameters: queryParameters,
      );
      final members = _extractMemberList(response.data);
      int? totalRows;
      if (response.data is Map) {
        final meta = (response.data as Map)['meta'];
        if (meta is Map) {
          totalRows = (meta['total_rows'] as num?)?.toInt();
        }
      }
      final hasMore = totalRows != null
          ? offset + members.length < totalRows
          : members.length >= clampedLimit;
      return (members: members, totalRows: totalRows, hasMore: hasMore);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取指定频道的成员列表（兼容旧调用，仅首屏）
  Future<List<Map<String, dynamic>>> getChannelMembers(
    int channelId, {
    String? filter,
    String? username,
    int limit = 50,
    int offset = 0,
  }) async {
    final page = await getChannelMembersPage(
      channelId,
      filter: filter,
      username: username,
      limit: limit,
      offset: offset,
    );
    return page.members;
  }

  /// 聊天全局在线 presence 频道（对齐 Discourse chat 插件 `/chat/online`）
  static const String chatOnlinePresenceChannel = '/chat/online';

  /// 上报用户进入聊天频道（用于在线状态追踪）
  ///
  /// 对齐 Discourse PresenceChannel#present：POST /presence/update。
  /// client_id 必须是 MessageBus 的 clientId —— 服务端按 (user, client_id)
  /// 记录在线条目并在 60s 后过期，用随机值会每次生成孤儿条目且无法 leave。
  /// 客户端应周期性调用（间隔 < 60s）以维持在线状态。
  Future<void> reportChatPresence(int channelId) async {
    if (!isAuthenticated) return;
    try {
      await _dio.post(
        '/presence/update',
        data: {
          'client_id': MessageBusService().clientId,
          'present_channels[]': [chatOnlinePresenceChannel],
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'X-SILENCE-LOGGER': 'true',
            'Discourse-Background': 'true',
          },
          extra: {'isSilent': true},
        ),
      );
    } on DioException catch (e) {
      // 在线状态上报失败不影响主流程，仅记录日志
      debugPrint('Failed to report chat presence: ${e.response?.statusCode}');
    }
  }

  /// 获取聊天全局在线状态
  ///
  /// 对齐 Discourse: GET /presence/get?channels[]=/chat/online
  /// 返回形如 `{ "/chat/online": { count, users: [...] } }`。
  Future<Map<String, dynamic>> getChatPresenceState() async {
    try {
      final response = await _dio.get(
        '/presence/get',
        queryParameters: {
          'channels[]': chatOnlinePresenceChannel,
        },
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  List<Map<String, dynamic>> _extractMemberList(dynamic data) {
    if (data is Map) {
      final mapData = Map<String, dynamic>.from(data);
      final usersMap = <int, Map<String, dynamic>>{};

      // 1. 提取顶层 users 数组 (Discourse 标准 API 中包含完整的 user 对象)
      final rawUsers = mapData['users'] ??
          (mapData['chat_channel'] is Map ? mapData['chat_channel']['users'] : null) ??
          mapData['target_users'];
      if (rawUsers is List) {
        for (final u in rawUsers) {
          if (u is Map) {
            final uMap = Map<String, dynamic>.from(u);
            final id = (uMap['id'] as num?)?.toInt();
            if (id != null) usersMap[id] = uMap;
          }
        }
      }

      // 2. 提取成员或 membership 列表
      final rawMembers = mapData['members'] ??
          mapData['memberships'] ??
          mapData['channel_members'] ??
          mapData['user_chat_channel_memberships'] ??
          (mapData['chat_channel'] is Map
              ? (mapData['chat_channel']['memberships'] ?? mapData['chat_channel']['members'])
              : null);

      final result = <Map<String, dynamic>>[];
      final addedIds = <int>{};

      if (rawMembers is List) {
        for (final e in rawMembers) {
          if (e is! Map) continue;
          final item = Map<String, dynamic>.from(e);
          Map<String, dynamic>? userObj;

          if (item['user'] is Map) {
            userObj = Map<String, dynamic>.from(item['user'] as Map);
          } else if (item['user_chat_channel_membership'] is Map &&
              item['user_chat_channel_membership']['user'] is Map) {
            userObj = Map<String, dynamic>.from(
                item['user_chat_channel_membership']['user'] as Map);
          } else {
            final userId = (item['user_id'] as num?)?.toInt() ??
                (item['id'] as num?)?.toInt();
            if (userId != null && usersMap.containsKey(userId)) {
              userObj = usersMap[userId];
            } else if (item.containsKey('username')) {
              userObj = item;
            }
          }

          if (userObj != null) {
            final uid = (userObj['id'] as num?)?.toInt() ?? 0;
            if (addedIds.add(uid)) {
              result.add(userObj);
            }
          }
        }
      }

      // 3. 将顶层 usersMap 中尚未包含的成员全部加入列表
      for (final entry in usersMap.entries) {
        if (addedIds.add(entry.key)) {
          result.add(entry.value);
        }
      }

      return result;
    } else if (data is List) {
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  /// 向指定频道添加成员
  ///
  /// 对齐 Discourse chat-api.addMembersToChannel:
  /// POST /chat/api/channels/:id/memberships  body: { usernames: [...] }
  Future<void> addChannelMember(int channelId, String username) async {
    try {
      await _dio.post(
        '/chat/api/channels/$channelId/memberships',
        data: {
          'usernames': [username],
        },
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 设置/取消频道收藏（starred）
  ///
  /// 对齐 Discourse: PUT /chat/api/channels/:id/memberships/me
  /// body: { starred: true|false }
  ///
  /// 注意：这与 join/leave（memberships/me）和 unfollow（memberships/me/follows）不同。
  Future<void> setChannelStarred(int channelId, {required bool starred}) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/memberships/me',
        data: {'starred': starred},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 关注频道（加入并 following）
  ///
  /// 对齐 Discourse chat-api.followChannel:
  /// POST /chat/api/channels/:id/memberships/me
  Future<void> followChannel(int channelId) async {
    try {
      await _dio.post('/chat/api/channels/$channelId/memberships/me');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消关注频道（保留 membership，仅 following=false）
  ///
  /// 对齐 Discourse chat-api.unfollowChannel:
  /// DELETE /chat/api/channels/:id/memberships/me/follows
  Future<void> unfollowChannel(int channelId) async {
    try {
      await _dio.delete('/chat/api/channels/$channelId/memberships/me/follows');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 对 Chat 消息点赞/回应/取消回应 (Reaction)
  Future<void> reactToChatMessage(
    int channelId,
    int messageId,
    String emoji, {
    required String action, // 'add' | 'remove'
  }) async {
    final data = <String, dynamic>{
      'emoji': emoji,
      'react_action': action,
      'message_id': messageId,
    };
    try {
      // 对齐 Discourse 路由: PUT /chat/:chat_channel_id/react/:message_id
      // (plugins/chat/config/routes.rb)。旧路径 /chat/api/channels/.../reactions 不存在。
      await _dio.put(
        '/chat/$channelId/react/$messageId',
        data: data,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 为 Chat 消息创建书签
  ///
  /// 对齐 Discourse: POST /bookmarks.json
  /// bookmarkable_type 使用 `Chat::Message`（官方前端 chat-message-interactor）。
  /// 返回新建 bookmark 的 id，供后续删除使用。
  Future<int> createChatMessageBookmark(int messageId) async {
    try {
      final response = await _dio.post(
        '/bookmarks.json',
        data: {
          'bookmarkable_type': 'Chat::Message',
          'bookmarkable_id': messageId,
        },
      );
      final respData = Map<String, dynamic>.from(response.data as Map);
      return (respData['id'] as num?)?.toInt() ?? 0;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 设置/取消 Chat 消息书签
  ///
  /// [bookmarked] 为 true 时创建并返回 bookmarkId；
  /// 为 false 时必须提供 [bookmarkId]，走核心 DELETE /bookmarks/:id.json
  /// （Chat 插件没有独立的 bookmark 删除路由）。
  Future<int?> toggleChatMessageBookmark(
    int channelId,
    int messageId, {
    required bool bookmarked,
    int? bookmarkId,
  }) async {
    try {
      if (bookmarked) {
        return await createChatMessageBookmark(messageId);
      }
      if (bookmarkId == null || bookmarkId <= 0) {
        throw ArgumentError(
          '取消聊天消息书签需要 bookmarkId（Discourse 仅支持 DELETE /bookmarks/:id）',
        );
      }
      // 复用核心书签删除端点（与 _PostsMixin.deleteBookmark 一致）
      await _dio.delete('/bookmarks/$bookmarkId.json');
      return null;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 创建消息串（对齐 Discourse chat-api.createThread）
  ///
  /// POST /chat/api/channels/:channelId/threads
  /// body: { original_message_id, title? }
  Future<Map<String, dynamic>> createChatThread(
    int channelId,
    int originalMessageId, {
    String? title,
  }) async {
    final data = <String, dynamic>{
      'original_message_id': originalMessageId,
    };
    if (title != null && title.isNotEmpty) data['title'] = title;
    try {
      final response = await _dio.post(
        '/chat/api/channels/$channelId/threads',
        data: data,
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取消息串详情
  ///
  /// GET /chat/api/channels/:channelId/threads/:threadId
  Future<Map<String, dynamic>> getChatThread(
    int channelId,
    int threadId,
  ) async {
    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/threads/$threadId',
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取消息串内消息列表
  ///
  /// GET /chat/api/channels/:channelId/threads/:threadId/messages
  Future<Map<String, dynamic>> getChatThreadMessages(
    int channelId,
    int threadId, {
    int? pageSize,
    int? targetMessageId,
    String? direction,
  }) async {
    final queryParameters = <String, dynamic>{};
    if (pageSize != null) queryParameters['page_size'] = pageSize;
    if (targetMessageId != null) {
      queryParameters['target_message_id'] = targetMessageId;
    }
    if (direction != null) queryParameters['direction'] = direction;
    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/threads/$threadId/messages',
        queryParameters: queryParameters.isEmpty ? null : queryParameters,
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 列出频道消息串
  ///
  /// GET /chat/api/channels/:channelId/threads
  Future<Map<String, dynamic>> getChatChannelThreads(int channelId) async {
    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/threads',
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 修改 Chat 频道元信息（名称、缩略名、表情、消息串等）
  ///
  /// 对齐 Discourse chat-api.updateChannel:
  /// PUT /chat/api/channels/:id  body: { channel: { ... } }
  Future<void> updateChannel(
    int channelId, {
    String? name,
    String? slug,
    String? emoji,
    String? description,
    bool? threadingEnabled,
  }) async {
    final channel = <String, dynamic>{};
    if (name != null) channel['name'] = name;
    if (slug != null) channel['slug'] = slug;
    if (emoji != null) channel['emoji'] = emoji;
    if (description != null) channel['description'] = description;
    if (threadingEnabled != null) {
      channel['threading_enabled'] = threadingEnabled;
    }
    if (channel.isEmpty) return;

    try {
      await _dio.put(
        '/chat/api/channels/$channelId',
        data: {'channel': channel},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 修改当前用户在频道中的通知设置（免打扰 / 通知级别）
  ///
  /// 对齐 Discourse chat-api.updateCurrentUserChannelNotificationsSettings:
  /// PUT /chat/api/channels/:id/notifications-settings/me
  /// body: { notifications_settings: { muted, notification_level } }
  /// 返回更新后的 membership（含 muted / notification_level），便于本地同步。
  Future<Map<String, dynamic>?> updateChannelNotificationsSettings(
    int channelId, {
    bool? muted,
    String? notificationLevel,
  }) async {
    final settings = <String, dynamic>{};
    if (muted != null) settings['muted'] = muted;
    if (notificationLevel != null) {
      settings['notification_level'] = notificationLevel;
    }
    if (settings.isEmpty) return null;

    try {
      final response = await _dio.put(
        '/chat/api/channels/$channelId/notifications-settings/me',
        data: {'notifications_settings': settings},
      );
      if (response.data is Map) {
        final map = Map<String, dynamic>.from(response.data as Map);
        if (map['membership'] is Map) {
          return Map<String, dynamic>.from(map['membership'] as Map);
        }
        return map;
      }
      return null;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 修改 Chat 频道设置（兼容旧调用）
  ///
  /// 频道元信息走 [updateChannel]；muted / notificationLevel 走通知设置端点。
  Future<void> updateChannelSettings(
    int channelId, {
    String? name,
    String? slug,
    String? emoji,
    String? description,
    bool? threadingEnabled,
    bool? muted,
    String? notificationLevel,
  }) async {
    final hasChannelFields = name != null ||
        slug != null ||
        emoji != null ||
        description != null ||
        threadingEnabled != null;
    final hasNotificationFields = muted != null || notificationLevel != null;

    try {
      if (hasChannelFields) {
        await updateChannel(
          channelId,
          name: name,
          slug: slug,
          emoji: emoji,
          description: description,
          threadingEnabled: threadingEnabled,
        );
      }
      if (hasNotificationFields) {
        await updateChannelNotificationsSettings(
          channelId,
          muted: muted,
          notificationLevel: notificationLevel,
        );
      }
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 浏览论坛中的公开频道
  ///
  /// [status] 可选值: 'open' | 'closed' | null(全部)
  /// [filter] 按名称搜索
  /// [offset] 分页偏移
  Future<Map<String, dynamic>> browseChannels({
    String? status,
    String? filter,
    int offset = 0,
    int limit = 25,
  }) async {
    final queryParameters = <String, dynamic>{
      'limit': limit,
      'offset': offset,
    };
    if (status != null && status.isNotEmpty) {
      queryParameters['status'] = status;
    }
    if (filter != null && filter.isNotEmpty) {
      queryParameters['filter'] = filter;
    }

    try {
      final response = await _dio.get(
        '/chat/api/channels',
        queryParameters: queryParameters,
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 加入（关注）指定频道
  ///
  /// 使用 POST /chat/api/channels/:id/memberships/me 端点
  Future<void> joinChannel(int channelId) async {
    try {
      await _dio.post('/chat/api/channels/$channelId/memberships/me');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 离开（取消关注）指定频道
  ///
  /// 使用 DELETE /chat/api/channels/:id/memberships/me 端点
  Future<void> leaveChannel(int channelId) async {
    try {
      await _dio.delete('/chat/api/channels/$channelId/memberships/me');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 恢复已删除的 Chat 消息
  ///
  /// 对齐 Discourse: PUT /chat/api/channels/:id/messages/:messageId/restore
  Future<void> restoreChatMessage(int channelId, int messageId) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/messages/$messageId/restore',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 举报 Chat 消息
  ///
  /// 对齐 Discourse chat-api.flagMessage:
  /// POST /chat/api/channels/:id/messages/:messageId/flags
  Future<void> flagChatMessage(
    int channelId,
    int messageId,
    int flagTypeId, {
    String? message,
  }) async {
    try {
      final data = <String, dynamic>{
        'flag_type_id': flagTypeId,
        'message_id': messageId,
        'channel_id': channelId,
      };
      if (message != null && message.isNotEmpty) {
        data['message'] = message;
      }
      await _dio.post(
        '/chat/api/channels/$channelId/messages/$messageId/flags',
        data: data,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 将选中消息生成引用 Markdown
  ///
  /// 对齐 Discourse: POST /chat/:channelId/quote  body: { message_ids: [...] }
  /// 返回 markdown 字符串，可粘贴到话题/私信。
  Future<String> quoteChatMessages(
    int channelId,
    List<int> messageIds,
  ) async {
    try {
      final response = await _dio.post(
        '/chat/$channelId/quote',
        data: {'message_ids': messageIds},
      );
      final respData = Map<String, dynamic>.from(response.data as Map);
      return respData['markdown']?.toString() ?? '';
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 标记当前用户所有聊天频道已读
  ///
  /// 对齐 Discourse: PUT /chat/api/channels/read
  Future<void> markAllChannelsRead() async {
    try {
      await _dio.put('/chat/api/channels/read');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 置顶 Chat 消息（需站点开启 chat_pinned_messages）
  Future<void> pinChatMessage(int channelId, int messageId) async {
    try {
      await _dio.post(
        '/chat/api/channels/$channelId/messages/$messageId/pin',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消置顶 Chat 消息
  Future<void> unpinChatMessage(int channelId, int messageId) async {
    try {
      await _dio.delete(
        '/chat/api/channels/$channelId/messages/$messageId/pin',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取频道置顶消息列表
  Future<Map<String, dynamic>> getPinnedMessages(int channelId) async {
    try {
      final response = await _dio.get('/chat/api/channels/$channelId/pins');
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 从频道移除成员
  ///
  /// 对齐 Discourse: DELETE /chat/api/channels/:id/memberships/:userId
  Future<void> removeChannelMember(int channelId, int userId) async {
    try {
      await _dio.delete('/chat/api/channels/$channelId/memberships/$userId');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 邀请用户加入频道（公开频道用 invites，不是 memberships）
  ///
  /// 对齐 Discourse chat-api.invite:
  /// POST /chat/api/channels/:id/invites  body: { user_ids: [...] }
  Future<void> inviteUsersToChannel(
    int channelId,
    List<int> userIds, {
    int? messageId,
  }) async {
    try {
      final data = <String, dynamic>{'user_ids': userIds};
      if (messageId != null) data['message_id'] = messageId;
      await _dio.post(
        '/chat/api/channels/$channelId/invites',
        data: data,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }
}
