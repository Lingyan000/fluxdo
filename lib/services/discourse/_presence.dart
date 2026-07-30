part of 'discourse_service.dart';

/// Presence 相关
mixin _PresenceMixin on _DiscourseServiceBase {
  /// 上报帖子阅读时间
  Future<int?> topicsTimings({
    required int topicId,
    required int topicTime,
    required Map<int, int> timings,
    Map<String, dynamic>? logContext,
  }) async {
    try {
      if (!isAuthenticated) return null;
      final data = <String, dynamic>{
        'topic_id': topicId,
        'topic_time': topicTime,
      };
      timings.forEach((k, v) => data['timings[$k]'] = v);

      final response = await _dio.post(
        '/topics/timings',
        data: data,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'X-SILENCE-LOGGER': 'true',
            'Discourse-Background': 'true',
          },
          extra: {
            'isSilent': true,
            '_networkLogFields': {
              'topicId': topicId,
              'topicTime': topicTime,
              'timingsCount': timings.length,
              if (logContext != null) ...logContext,
            },
          },
        ),
      );
      return response.statusCode;
    } on DioException catch (e) {
      debugPrint('[DiscourseService] topicsTimings failed: ${e.response?.statusCode}');
      return e.response?.statusCode;
    }
  }

  /// 获取话题回复 presence 状态
  Future<PresenceResponse> getPresence(int topicId) async {
    final response = await _dio.get(
      '/presence/get',
      queryParameters: {
        'channels[]': '/discourse-presence/reply/$topicId',
      },
    );
    return PresenceResponse.fromJson(response.data, topicId);
  }

  /// 更新 Presence 状态
  Future<void> updatePresence({
    List<String>? presentChannels,
    List<String>? leaveChannels,
  }) async {
    if (!isAuthenticated) return;

    final clientId = MessageBusService().clientId;
    final data = <String, dynamic>{
      'client_id': clientId,
    };

    if (presentChannels != null && presentChannels.isNotEmpty) {
      data['present_channels[]'] = presentChannels;
    }
    if (leaveChannels != null && leaveChannels.isNotEmpty) {
      data['leave_channels[]'] = leaveChannels;
    }

    try {
      await _dio.post(
        '/presence/update',
        data: data,
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
      debugPrint('[DiscourseService] updatePresence failed: ${e.response?.statusCode}');
    }
  }

  /// 聊天在线用户 id 集合(对齐官方 `/chat/online` presence 频道初始快照)
  Future<Set<int>> getChatOnlinePresence() async {
    try {
      final response = await _dio.get(
        '/presence/get',
        queryParameters: {'channels[]': '/chat/online'},
      );
      final data = response.data as Map<String, dynamic>;
      final channelData = data['/chat/online'] as Map<String, dynamic>?;
      final usersList = channelData?['users'] as List<dynamic>? ?? [];
      return usersList
          .map((u) => (u as Map<String, dynamic>)['id'] as int? ?? 0)
          .where((id) => id > 0)
          .toSet();
    } catch (e) {
      debugPrint('[DiscourseService] getChatOnlinePresence failed: $e');
      return {};
    }
  }

  /// 获取预加载的话题追踪频道元数据
  Future<Map<String, dynamic>?> getPreloadedTopicTrackingMeta() async {
    final preloaded = PreloadedDataService();
    return preloaded.getTopicTrackingStateMeta();
  }
}
