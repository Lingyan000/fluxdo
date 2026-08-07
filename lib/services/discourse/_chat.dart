part of 'discourse_service.dart';

/// Discourse Chat 插件 API(私聊/群聊)
///
/// 路径分两族:新式 `/chat/api/*`;少数历史端点直接挂 `/chat/*`
/// (发消息 POST /chat/:id、reaction PUT /chat/:id/react/:mid)。
mixin _ChatMixin on _DiscourseServiceBase {
  /// 我的频道列表:公共频道 + 全部 DM 频道 + 未读 tracking +
  /// 各 MessageBus 通道的订阅起始位点
  Future<MyChatChannelsResponse> getMyChatChannels() async {
    return MyChatChannelsResponse.fromJson(await getMyChatChannelsRaw());
  }

  /// 原始 JSON 形态(冷启缓存落盘用:模型不持有 raw,快照直接存响应)
  Future<Map<String, dynamic>> getMyChatChannelsRaw() async {
    try {
      final response = await _dio.get('/chat/api/me/channels');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 单频道详情(进入会话时刷新能力位与 bus 位点)
  Future<ChatChannel> getChatChannel(int channelId) async {
    try {
      final response = await _dio.get('/chat/api/channels/$channelId');
      final data = response.data as Map<String, dynamic>;
      return ChatChannel.fromJson(
        data['channel'] as Map<String, dynamic>? ?? data,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 创建/复用 DM 频道
  ///
  /// 服务端判定:参与者(含自己)>2 人或带 [name] 即群聊;
  /// 1:1 与 [upsert]=true 时复用已存在频道,群聊默认每次新建。
  Future<ChatChannel> createDirectMessageChannel({
    required List<String> targetUsernames,
    String? name,
    bool upsert = false,
  }) async {
    try {
      final response = await _dio.post(
        '/chat/api/direct-message-channels',
        data: {
          'target_usernames': targetUsernames,
          if (name != null && name.isNotEmpty) 'name': name,
          if (upsert) 'upsert': true,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return ChatChannel.fromJson(
        data['channel'] as Map<String, dynamic>? ?? data,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 拉取频道消息(游标分页)
  ///
  /// 三种用法:
  /// - 首屏定位未读:[fetchFromLastRead]=true
  /// - 滚动翻页:[direction]='past'/'future' + [targetMessageId] 游标
  /// - 跳转定位:仅 [targetMessageId],服务端取锚点前后各 25 条
  Future<ChatMessagesResponse> getChatMessages(
    int channelId, {
    String? direction,
    int? targetMessageId,
    bool fetchFromLastRead = false,
    int pageSize = 50,
  }) async {
    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/messages',
        queryParameters: {
          'page_size': pageSize,
          if (direction != null) 'direction': direction,
          if (targetMessageId != null) 'target_message_id': targetMessageId,
          if (fetchFromLastRead) 'fetch_from_last_read': true,
        },
      );
      return ChatMessagesResponse.fromJson(
        response.data as Map<String, dynamic>,
        channelId: channelId,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 发送消息,返回服务端 message_id
  ///
  /// [stagedId] 客户端生成的临时 ID,服务端会在 MessageBus `sent`
  /// 广播里原样带回,用于乐观消息对账替换。
  Future<int?> sendChatMessage(
    int channelId, {
    required String message,
    String? stagedId,
    int? inReplyToId,
    int? threadId,
    List<int>? uploadIds,
  }) async {
    try {
      final response = await _dio.post(
        '/chat/$channelId',
        data: {
          'message': message,
          if (stagedId != null) 'staged_id': stagedId,
          if (inReplyToId != null) 'in_reply_to_id': inReplyToId,
          if (threadId != null) 'thread_id': threadId,
          if (uploadIds != null && uploadIds.isNotEmpty)
            'upload_ids': uploadIds,
        },
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data['message_id'] as int?;
      return null;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 拉取 thread 内消息(参数语义同 [getChatMessages])
  Future<ChatMessagesResponse> getChatThreadMessages(
    int channelId,
    int threadId, {
    String? direction,
    int? targetMessageId,
    bool fetchFromLastRead = false,
    int pageSize = 50,
  }) async {
    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/threads/$threadId/messages',
        queryParameters: {
          'page_size': pageSize,
          if (direction != null) 'direction': direction,
          if (targetMessageId != null) 'target_message_id': targetMessageId,
          if (fetchFromLastRead) 'fetch_from_last_read': true,
        },
      );
      return ChatMessagesResponse.fromJson(
        response.data as Map<String, dynamic>,
        channelId: channelId,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// thread 标记已读
  Future<void> markChatThreadRead(int channelId, int threadId) async {
    try {
      await _dio.put('/chat/api/channels/$channelId/threads/$threadId/read');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 为某消息创建(或获取已有)消息串,返回 thread id
  ///
  /// threading 频道里"回复"的正确语义:回复进串,不是平面 in_reply_to
  /// (网页版点回复即建串进串;平面回复的 sent 广播只发 thread 子通道,
  /// 主流等不到对账)。
  Future<int> createChatThread(
    int channelId, {
    required int originalMessageId,
  }) async {
    try {
      final response = await _dio.post(
        '/chat/api/channels/$channelId/threads',
        data: {'original_message_id': originalMessageId},
      );
      final data = response.data as Map<String, dynamic>;
      final thread = data['thread'] as Map<String, dynamic>? ?? data;
      return thread['id'] as int;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 浏览公共频道(含未加入的;[filter] 搜索词,offset 分页)
  Future<List<ChatChannel>> browseChatChannels({
    String? filter,
    int offset = 0,
    int limit = 25,
  }) async {
    try {
      final response = await _dio.get(
        '/chat/api/channels',
        queryParameters: {
          'offset': offset,
          'limit': limit,
          'status': 'open',
          if (filter != null && filter.isNotEmpty) 'filter': filter,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return (data['channels'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatChannel.fromJson)
          .toList();
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 加入公共频道(建立我的成员关系并 follow)
  Future<void> joinChatChannel(int channelId) async {
    try {
      await _dio.post('/chat/api/channels/$channelId/memberships/me');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 举报消息(flag_type_id 来自 post_action_types;服务端限流 4 次/分)
  Future<void> flagChatMessage(
    int channelId,
    int messageId, {
    required int flagTypeId,
    String? message,
  }) async {
    try {
      await _dio.post(
        '/chat/api/channels/$channelId/messages/$messageId/flags',
        data: {
          'flag_type_id': flagTypeId,
          if (message != null && message.isNotEmpty) 'message': message,
        },
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 引用多条消息:服务端生成 [chat] transcript markdown
  Future<String> quoteChatMessages(
    int channelId,
    List<int> messageIds,
  ) async {
    try {
      final response = await _dio.post(
        '/chat/$channelId/quote',
        data: {'message_ids': messageIds},
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data['markdown'] as String? ?? '';
      }
      return '';
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 批量删除消息
  Future<void> deleteChatMessages(int channelId, List<int> messageIds) async {
    try {
      await _dio.delete(
        '/chat/api/channels/$channelId/messages',
        data: {'message_ids': messageIds},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 搜索消息([channelId] 非空=会话内搜索;limit 服务端上限 40)
  Future<({List<ChatMessage> messages, bool hasMore})> searchChatMessages(
    String query, {
    int? channelId,
    int offset = 0,
    int limit = 20,
  }) async {
    try {
      final response = await _dio.get(
        '/chat/api/search',
        queryParameters: {
          'query': query,
          'offset': offset,
          'limit': limit,
          if (channelId != null) 'channel_id': channelId,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return (
        messages: (data['messages'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList(),
        hasMore:
            (data['meta'] as Map<String, dynamic>?)?['has_more'] as bool? ??
                false,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 收藏/取消收藏会话(membership.starred)
  Future<void> starChatChannel(int channelId, {required bool starred}) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/memberships/me',
        data: {'starred': starred},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// AI 总结频道消息(discourse-ai 插件;[sinceHours] 只认
  /// 1/3/6/12/24/72/168;服务端限流 6 次/5 分,慢请求)
  Future<String> summarizeChatChannel(
    int channelId, {
    required int sinceHours,
  }) async {
    try {
      final response = await _dio.post(
        '/discourse-ai/summarization/channels/$channelId',
        queryParameters: {'since': sinceHours},
        options: Options(
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data['summary'] as String? ?? '';
      }
      return '';
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 我的频道通知设置([muted] 静音;[notificationLevel]:
  /// 'never'|'mention'|'always')
  Future<void> updateChatChannelNotificationsSettings(
    int channelId, {
    bool? muted,
    String? notificationLevel,
  }) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/notifications-settings/me',
        data: {
          'notifications_settings': {
            if (muted != null) 'muted': muted,
            if (notificationLevel != null)
              'notification_level': notificationLevel,
          },
        },
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 保存/清除聊天草稿([data] 为 null/空对象即清除;服务端发送成功
  /// 时也会自动清)。data 形状:{message, uploads, replyToMsg, editing}
  Future<void> saveChatDraft(
    int channelId, {
    int? threadId,
    Map<String, dynamic>? data,
  }) async {
    try {
      final path = threadId != null
          ? '/chat/api/channels/$channelId/threads/$threadId/drafts'
          : '/chat/api/channels/$channelId/drafts';
      await _dio.post(
        path,
        data: {'data': data == null || data.isEmpty ? '' : jsonEncode(data)},
        options: Options(extra: const {'isSilent': true}),
      );
    } on DioException catch (e) {
      // 草稿保存失败不打扰用户(对齐网页版静默吞错)
      debugPrint('[DiscourseService] saveChatDraft failed: ${e.message}');
    }
  }

  /// 编辑消息
  Future<void> editChatMessage(
    int channelId,
    int messageId, {
    required String message,
    List<int>? uploadIds,
  }) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/messages/$messageId',
        data: {
          'message': message,
          if (uploadIds != null) 'upload_ids': uploadIds,
        },
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 删除消息
  Future<void> deleteChatMessage(int channelId, int messageId) async {
    try {
      await _dio.delete('/chat/api/channels/$channelId/messages/$messageId');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 恢复已删除消息
  Future<void> restoreChatMessage(int channelId, int messageId) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/messages/$messageId/restore',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 频道置顶消息列表(站点开 chat_pinned_messages;上限每频道 MAX_PINS)
  Future<List<ChatMessage>> getChannelPins(int channelId) async {
    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/pins',
      );
      final data = response.data as Map<String, dynamic>;
      return (data['pinned_messages'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((pin) {
            final raw = pin['message'];
            return raw is Map<String, dynamic>
                ? ChatMessage.fromJson(raw, fallbackChannelId: channelId)
                : null;
          })
          .whereType<ChatMessage>()
          .toList();
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 置顶消息
  Future<void> pinChatMessage(int channelId, int messageId) async {
    try {
      await _dio.post(
        '/chat/api/channels/$channelId/messages/$messageId/pin',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消置顶
  Future<void> unpinChatMessage(int channelId, int messageId) async {
    try {
      await _dio.delete(
        '/chat/api/channels/$channelId/messages/$messageId/pin',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 标记频道置顶为已读(顶栏 pin 徽记消隐)
  Future<void> markChannelPinsRead(int channelId) async {
    try {
      await _dio.put('/chat/api/channels/$channelId/pins/read');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 收藏聊天消息(标准 bookmarks API,bookmarkable_type=Chat::Message);
  /// 返回 bookmark id(取消收藏用)
  Future<int> bookmarkChatMessage(int messageId) async {
    try {
      final response = await _dio.post(
        '/bookmarks.json',
        data: {
          'bookmarkable_id': messageId,
          'bookmarkable_type': 'Chat::Message',
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = response.data;
      if (data is Map && data['id'] != null) return data['id'] as int;
      throw Exception(S.current.error_unrecognizedDataFormat);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 表情回应 [reactAction]: 'add' | 'remove'
  Future<void> reactChatMessage(
    int channelId,
    int messageId, {
    required String emoji,
    required String reactAction,
  }) async {
    try {
      await _dio.put(
        '/chat/$channelId/react/$messageId',
        data: {
          'emoji': emoji,
          'react_action': reactAction,
        },
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 上报已读回执:把频道的 last_read_message_id 推进到 [messageId]
  /// (服务端要求单调不减,回退会被拒)
  Future<void> markChatChannelRead(int channelId, {int? messageId}) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId/read',
        queryParameters: {if (messageId != null) 'message_id': messageId},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  // ========== 成员管理(群聊) ==========

  /// 成员列表(offset 分页,单页上限 50;[username] 服务端过滤)
  Future<List<ChatChannelMember>> getChatChannelMembers(
    int channelId, {
    int offset = 0,
    int limit = 50,
    String? username,
  }) async {
    try {
      final response = await _dio.get(
        '/chat/api/channels/$channelId/memberships',
        queryParameters: {
          'offset': offset,
          'limit': limit,
          if (username != null && username.isNotEmpty) 'username': username,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return (data['memberships'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatChannelMember.fromJson)
          .toList();
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 群聊拉人(受 DM 人数上限/对方私信许可约束,失败带服务端原因)
  Future<void> addChatChannelMembers(
    int channelId,
    List<String> usernames,
  ) async {
    try {
      await _dio.post(
        '/chat/api/channels/$channelId/memberships',
        data: {'usernames': usernames},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 踢人(需 can_remove_members)
  Future<void> removeChatChannelMember(int channelId, int userId) async {
    try {
      await _dio.delete('/chat/api/channels/$channelId/memberships/$userId');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 退出会话(unfollow:DM 语义=从列表隐藏,历史保留,有新消息会回来)
  Future<void> leaveChatChannel(int channelId) async {
    try {
      await _dio.delete(
        '/chat/api/channels/$channelId/memberships/me/follows',
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 改群名/描述/消息串开关(DM 成员可改;公共频道需管理权限)
  Future<void> updateChatChannel(
    int channelId, {
    String? name,
    String? description,
    bool? threadingEnabled,
  }) async {
    try {
      await _dio.put(
        '/chat/api/channels/$channelId',
        data: {
          if (name != null) 'name': name,
          if (description != null) 'description': description,
          if (threadingEnabled != null) 'threading_enabled': threadingEnabled,
        },
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }
}
