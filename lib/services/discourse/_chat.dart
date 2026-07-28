part of 'discourse_service.dart';

/// Chat 插件直接消息(DM)相关
mixin _ChatMixin on _DiscourseServiceBase {
  /// 获取当前用户的 DM 频道列表
  ///
  /// 未读数不在每个频道对象的 `current_user_membership` 里(该 serializer
  /// 只有 following/muted/last_read_message_id 等字段,没有 unread 相关
  /// 字段——核对过 Discourse 源码 `BaseChannelMembershipSerializer`)。
  /// 未读数是响应顶层独立的 `tracking` 表,按频道 id 映射
  /// `{unread_count, mention_count}`(核对过 `Chat::ChannelFetcher.structured`
  /// / `StructuredChannelSerializer`),这里手动合并进 membership 字段,
  /// 让 [ChatChannel.fromJson] 不用感知这个分裂的响应结构。
  Future<List<ChatChannel>> fetchChatChannels() async {
    final response = await _dio.get('/chat/api/me/channels');
    final data = response.data as Map<String, dynamic>;
    // 已加入的公共频道 + DM 频道一起返回,UI 侧按 isDirectMessage 分组
    final channels = [
      ...(data['public_channels'] as List<dynamic>? ?? []),
      ...(data['direct_message_channels'] as List<dynamic>? ?? []),
    ];
    final tracking = data['tracking'] as Map<String, dynamic>? ?? {};

    return channels.map((e) {
      final json = Map<String, dynamic>.from(e as Map<String, dynamic>);
      final trackingInfo = tracking[json['id'].toString()] as Map<String, dynamic>?;
      if (trackingInfo != null) {
        final membership = Map<String, dynamic>.from(
          json['current_user_membership'] as Map<String, dynamic>? ?? {},
        );
        membership['unread_count'] = trackingInfo['unread_count'];
        membership['unread_mentions'] = trackingInfo['mention_count'];
        json['current_user_membership'] = membership;
      }
      return ChatChannel.fromJson(json);
    }).toList();
  }

  /// 浏览可加入的公共频道(`Chat::Api::ChannelsController#index`,
  /// 支持 filter 关键词搜索,status 传 "open" 只看开放频道)。
  Future<List<ChatChannel>> browsePublicChatChannels({
    String? filter,
    int limit = 25,
    int offset = 0,
  }) async {
    final response = await _dio.get('/chat/api/channels', queryParameters: {
      if (filter != null && filter.isNotEmpty) 'filter': filter,
      'limit': limit,
      'offset': offset,
      'status': 'open',
    });
    final channels = response.data['channels'] as List<dynamic>? ?? [];
    return channels
        .map((e) => ChatChannel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 加入(关注)一个公共频道
  Future<void> joinChatChannel(int channelId) async {
    await _dio.post('/chat/api/channels/$channelId/memberships/me');
  }

  /// 离开频道(`Chat::LeaveChannel`,DM 和公共频道都适用)
  Future<void> leaveChatChannel(int channelId) async {
    await _dio.delete('/chat/api/channels/$channelId/memberships/me');
  }

  /// 频道置顶消息列表(`Chat::Api::ChannelPinsController#index`,响应
  /// `{pinned_messages: [{id, chat_message_id, pinned_at, pinned_by, message}]}`)。
  Future<List<ChatMessage>> fetchChatChannelPins(int channelId) async {
    final response = await _dio.get('/chat/api/channels/$channelId/pins');
    final pins = response.data['pinned_messages'] as List<dynamic>? ?? [];
    return pins
        .map((e) => ChatMessage.fromJson(
            (e as Map<String, dynamic>)['message'] as Map<String, dynamic>))
        .toList();
  }

  /// 标记频道置顶列表已读(清掉"有新置顶"的小红点)
  Future<void> markChatChannelPinsRead(int channelId) async {
    await _dio.put('/chat/api/channels/$channelId/pins/read');
  }

  /// 消息串内的消息列表
  Future<List<ChatMessage>> fetchChatThreadMessages(
    int channelId,
    int threadId, {
    int pageSize = 50,
    bool fetchFromLastRead = true,
  }) async {
    final response = await _dio.get(
      '/chat/api/channels/$channelId/threads/$threadId/messages',
      queryParameters: {
        'page_size': pageSize,
        if (fetchFromLastRead) 'fetch_from_last_read': true,
      },
    );
    final messages = response.data['messages'] as List<dynamic>? ?? [];
    return messages
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 标记消息串已读
  Future<void> markChatThreadRead(int channelId, int threadId) async {
    await _dio.put('/chat/api/channels/$channelId/threads/$threadId/read');
  }

  /// 频道成员列表(服务端分页 + 用户名搜索,常规频道几万人也不用全量拉,
  /// `Chat::Api::ChannelsMembershipsController#index`,limit 上限 50)。
  Future<List<MentionUser>> fetchChatChannelMembers(
    int channelId, {
    String? username,
    int offset = 0,
    int limit = 50,
  }) async {
    final response = await _dio.get(
      '/chat/api/channels/$channelId/memberships',
      queryParameters: {
        if (username != null && username.isNotEmpty) 'username': username,
        'offset': offset,
        'limit': limit,
      },
    );
    final memberships = response.data['memberships'] as List<dynamic>? ?? [];
    return memberships
        .map((e) => MentionUser.fromJson(
            (e as Map<String, dynamic>)['user'] as Map<String, dynamic>))
        .toList();
  }

  /// 全局/单频道搜索聊天消息(`Chat::SearchMessage`,响应里每条消息带
  /// `channel` 字段)。
  Future<List<ChatMessage>> searchChatMessages(
    String query, {
    int? channelId,
    int limit = 20,
    int offset = 0,
    String sort = 'relevance', // relevance | latest
  }) async {
    final response = await _dio.get('/chat/api/search', queryParameters: {
      'query': query,
      'channel_id': ?channelId,
      'limit': limit,
      'offset': offset,
      'sort': sort,
    });
    final messages = response.data['messages'] as List<dynamic>? ?? [];
    return messages
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 给聊天消息加书签(走站点通用书签接口,类型 Chat::Message)
  Future<int> bookmarkChatMessage(int messageId) async {
    final response = await _dio.post('/bookmarks.json', data: {
      'bookmarkable_id': messageId,
      'bookmarkable_type': 'Chat::Message',
    });
    return response.data['id'] as int;
  }

  /// 发起或获取与某些用户的 DM 频道（已存在则复用，upsert 语义）
  Future<ChatChannel> createOrGetDirectMessageChannel(List<String> usernames) async {
    final response = await _dio.post('/chat/api/direct-message-channels', data: {
      'target_usernames': usernames,
      'upsert': true,
    });
    return ChatChannel.fromJson(response.data['channel'] as Map<String, dynamic>);
  }

  /// 获取某个频道的消息列表
  Future<List<ChatMessage>> fetchChatMessages(
    int channelId, {
    int pageSize = 50,
    int? targetMessageId,
    String direction = 'past',
    bool fetchFromLastRead = false,
  }) async {
    final queryParams = <String, dynamic>{'page_size': pageSize};
    if (targetMessageId != null) {
      queryParams['target_message_id'] = targetMessageId;
      queryParams['direction'] = direction;
    } else if (fetchFromLastRead) {
      queryParams['fetch_from_last_read'] = true;
    }
    final response = await _dio.get(
      '/chat/api/channels/$channelId/messages',
      queryParameters: queryParams,
    );
    final messages = response.data['messages'] as List<dynamic>? ?? [];
    return messages
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 在频道内发送一条消息([threadId] 非空时发到指定消息串里)
  Future<int> sendChatMessage(
    int channelId,
    String message, {
    int? inReplyToId,
    List<int>? uploadIds,
    int? threadId,
  }) async {
    final data = <String, dynamic>{
      'message': message,
      'staged_id': DateTime.now().microsecondsSinceEpoch.toString(),
    };
    if (inReplyToId != null) data['in_reply_to_id'] = inReplyToId;
    if (threadId != null) data['thread_id'] = threadId;
    if (uploadIds != null && uploadIds.isNotEmpty) data['upload_ids'] = uploadIds;
    // 路由表里这条是 Chat::Engine 的"顶层路由"`POST /:chat_channel_id`,
    // 但引擎本身是 `mount ::Chat::Engine, at: "/chat"`(plugin.rb),所以
    // 相对站点根其实是 `/chat/:channel_id`——之前当成裸的 `/:channelId`
    // 发,404 了(找不到请求的 URL)。
    final response = await _dio.post('/chat/$channelId', data: data);
    return response.data['message_id'] as int;
  }

  /// 给消息加/取消一个表情回应。核对过 Discourse 源码
  /// `Chat::ChatController#react` + `Chat::MessageReactor`:路由跟发消息
  /// 那条一样是 Chat::Engine 的顶层路由(挂载在 `/chat` 下),
  /// `emoji` 是不带冒号的裸名(如 `heart`),`react_action` 只认
  /// `"add"`/`"remove"` 字符串。
  Future<void> toggleChatReaction(
    int channelId,
    int messageId,
    String emoji, {
    required bool add,
  }) async {
    await _dio.put(
      '/chat/$channelId/react/$messageId',
      data: {
        'message_id': messageId,
        'emoji': emoji,
        'react_action': add ? 'add' : 'remove',
      },
    );
  }

  /// 切换频道收藏状态。核对过 Discourse 源码
  /// `Chat::UpdateUserChannelMembership`:任意频道(含 DM)都能收藏。
  Future<void> setChatChannelStarred(int channelId, bool starred) async {
    await _dio.put(
      '/chat/api/channels/$channelId/memberships/me',
      data: {'starred': starred},
    );
  }

  /// 编辑一条消息。核对过源码 `Chat::UpdateMessage`:
  /// `PUT /chat/api/channels/:channel_id/messages/:message_id`,
  /// `message` 在 `upload_ids` 为空时必填。
  Future<void> updateChatMessage(
    int channelId,
    int messageId,
    String message, {
    List<int>? uploadIds,
  }) async {
    final data = <String, dynamic>{'message': message};
    if (uploadIds != null && uploadIds.isNotEmpty) data['upload_ids'] = uploadIds;
    await _dio.put('/chat/api/channels/$channelId/messages/$messageId', data: data);
  }

  /// 删除自己的消息(软删除,可恢复)
  Future<void> deleteChatMessage(int channelId, int messageId) async {
    await _dio.delete('/chat/api/channels/$channelId/messages/$messageId');
  }

  /// 恢复被删除的消息
  Future<void> restoreChatMessage(int channelId, int messageId) async {
    await _dio.put('/chat/api/channels/$channelId/messages/$messageId/restore');
  }

  /// 举报一条消息。核对过源码 `Chat::FlagMessage`:
  /// `flag_type_id` 取 `ReviewableScore.types` 的值
  /// (off_topic=3, inappropriate=4, spam=8, notify_moderators=7),
  /// `message` 仅 notify_moderators/notify_user 时用来附言。
  Future<void> flagChatMessage(
    int channelId,
    int messageId,
    int flagTypeId, {
    String? message,
  }) async {
    final data = <String, dynamic>{'flag_type_id': flagTypeId};
    if (message != null && message.isNotEmpty) data['message'] = message;
    await _dio.post(
      '/chat/api/channels/$channelId/messages/$messageId/flags',
      data: data,
    );
  }

  /// 置顶/取消置顶一条消息(站点需开 chat_pinned_messages)
  Future<void> setChatMessagePinned(
    int channelId,
    int messageId, {
    required bool pinned,
  }) async {
    final path = '/chat/api/channels/$channelId/messages/$messageId/pin';
    if (pinned) {
      await _dio.post(path);
    } else {
      await _dio.delete(path);
    }
  }

  /// 静音/取消静音频道。核对过源码
  /// `ChannelsCurrentUserNotificationsSettingsController`:参数必须包在
  /// `notifications_settings` 里(`params.require(:notifications_settings)`)。
  Future<void> setChatChannelMuted(int channelId, bool muted) async {
    await _dio.put(
      '/chat/api/channels/$channelId/notifications-settings/me',
      data: {
        'notifications_settings': {'muted': muted},
      },
    );
  }

  /// 设置频道通知级别(never=0 / mention=1 / always=2,对应
  /// `Chat::UserChatChannelMembership::NOTIFICATION_LEVELS`)。
  Future<void> setChatChannelNotificationLevel(int channelId, int level) async {
    const names = {0: 'never', 1: 'mention', 2: 'always'};
    await _dio.put(
      '/chat/api/channels/$channelId/notifications-settings/me',
      data: {
        'notifications_settings': {'notification_level': names[level] ?? 'always'},
      },
    );
  }

  /// 开关频道"消息串"(threading)。核对过源码 `Chat::UpdateChannel`:
  /// `PUT /chat/api/channels/:id`,参数是顶层 `threading_enabled`。
  Future<void> setChatChannelThreadingEnabled(int channelId, bool enabled) async {
    await _dio.put(
      '/chat/api/channels/$channelId',
      data: {'threading_enabled': enabled},
    );
  }

  /// 标记单个频道已读到某条消息
  Future<void> markChatChannelRead(int channelId, int messageId) async {
    await _dio.put('/chat/api/channels/$channelId/read', data: {'message_id': messageId});
  }

  /// 标记所有 DM 频道已读
  Future<void> markAllChatChannelsRead() async {
    await _dio.put('/chat/api/channels/read');
  }

  /// AI 总结频道近期消息(discourse-ai 插件,未装插件/未开该功能时接口
  /// 404,调用方需处理)。核对过源码 `DiscourseAi::Summarization::ChatSummaryController`:
  /// `POST /discourse-ai/summarization/channels/:channel_id.json`,
  /// `since` 只能是 [1,3,6,12,24,72,168](小时),返回 `{summary: String}`。
  Future<String> summarizeChatChannel(int channelId, int sinceHours) async {
    final response = await _dio.post(
      '/discourse-ai/summarization/channels/$channelId.json',
      data: {'since': sinceHours},
    );
    return (response.data as Map<String, dynamic>)['summary'] as String? ?? '';
  }
}
