part of 'discourse_service.dart';

/// 话题相关
mixin _TopicsMixin on _DiscourseServiceBase {
  /// 按 topic_ids 获取话题（对齐网页版 loadBefore 请求）
  /// 请求 /latest.json?topic_ids=1,2,3 返回指定话题的最新数据
  Future<TopicListResponse> getTopicsByIds(List<int> topicIds) async {
    if (topicIds.isEmpty) {
      return TopicListResponse(topics: [], moreTopicsUrl: null);
    }
    final response = await _dio.get(
      '/latest.json',
      queryParameters: {'topic_ids': topicIds.join(',')},
    );
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  Future<TopicListResponse> getLatestTopics({int page = 0, String? order, bool? ascending}) async {
    if (page == 0 && order == null) {
      final preloaded = PreloadedDataService();
      final preloadedList = await preloaded.getInitialTopicList();
      if (preloadedList != null) {
        return preloadedList;
      }
    }

    final queryParams = <String, dynamic>{};
    if (page > 0) queryParams['page'] = page;
    if (order != null) queryParams['order'] = order;
    if (ascending != null) queryParams['ascending'] = ascending.toString();

    final response = await _dio.get(
      '/latest.json',
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  /// 获取话题列表（支持分类和标签筛选）
  Future<TopicListResponse> getFilteredTopics({
    required String filter,
    int? categoryId,
    String? categorySlug,
    String? parentCategorySlug,
    List<String>? tags,
    String? period,
    int page = 0,
    String? order,
    bool? ascending,
    String? subset,
  }) async {
    String path;
    final queryParams = <String, dynamic>{};

    if (page > 0) {
      queryParams['page'] = page;
    }

    if (period != null) {
      queryParams['period'] = period;
    }

    if (order != null) {
      queryParams['order'] = order;
    }

    if (ascending != null) {
      queryParams['ascending'] = ascending.toString();
    }

    if (subset != null) {
      queryParams['subset'] = subset;
    }

    if (categoryId != null && categorySlug != null) {
      // 分类路径，标签通过 tags[] 查询参数传递
      if (parentCategorySlug != null) {
        path = '/c/$parentCategorySlug/$categorySlug/$categoryId/l/$filter.json';
      } else {
        path = '/c/$categorySlug/$categoryId/l/$filter.json';
      }
      if (tags != null && tags.isNotEmpty) {
        queryParams['tags[]'] = tags;
      }
    } else if (tags != null && tags.isNotEmpty) {
      // 纯标签筛选：单标签用路径，多标签用第一个标签路径 + 其余标签查询参数
      path = '/tag/${tags.first}/l/$filter.json';
      if (tags.length > 1) {
        queryParams['tags[]'] = tags.skip(1).toList();
        queryParams['match_all_tags'] = 'true';
      }
    } else {
      path = '/$filter.json';
    }

    final response = await _dio.get(path, queryParameters: queryParams.isNotEmpty ? queryParams : null);
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  Future<TopicListResponse> getNewTopics({int page = 0, String? order, bool? ascending, String? subset}) async {
    final queryParams = <String, dynamic>{};
    if (page > 0) queryParams['page'] = page;
    if (order != null) queryParams['order'] = order;
    if (ascending != null) queryParams['ascending'] = ascending.toString();
    if (subset != null) queryParams['subset'] = subset;

    final response = await _dio.get(
      '/new.json',
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  Future<TopicListResponse> getUnreadTopics({int page = 0, String? order, bool? ascending}) async {
    final queryParams = <String, dynamic>{};
    if (page > 0) queryParams['page'] = page;
    if (order != null) queryParams['order'] = order;
    if (ascending != null) queryParams['ascending'] = ascending.toString();

    final response = await _dio.get(
      '/unread.json',
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  Future<TopicListResponse> getUnseenTopics({int page = 0, String? order, bool? ascending}) async {
    final queryParams = <String, dynamic>{};
    if (page > 0) queryParams['page'] = page;
    if (order != null) queryParams['order'] = order;
    if (ascending != null) queryParams['ascending'] = ascending.toString();

    final response = await _dio.get(
      '/unseen.json',
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  Future<TopicListResponse> getHotTopics({int page = 0, String? order, bool? ascending}) async {
    final queryParams = <String, dynamic>{};
    if (page > 0) queryParams['page'] = page;
    if (order != null) queryParams['order'] = order;
    if (ascending != null) queryParams['ascending'] = ascending.toString();

    final response = await _dio.get(
      '/hot.json',
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  /// 获取话题详情
  Future<TopicDetail> getTopicDetail(int id, {int? postNumber, bool trackVisit = false, String? filter, String? usernameFilters, bool filterTopLevelReplies = false}) async {
    final path = postNumber != null ? '/t/$id/$postNumber.json' : '/t/$id.json';
    final queryParams = <String, dynamic>{};
    if (trackVisit) {
      queryParams['track_visit'] = true;
    }
    if (filter != null) {
      queryParams['filter'] = filter;
    }
    if (usernameFilters != null) {
      queryParams['username_filters'] = usernameFilters;
    }
    if (filterTopLevelReplies) {
      queryParams['filter_top_level_replies'] = true;
    }
    final options = trackVisit
        ? Options(headers: {
            'Discourse-Track-View': '1',
            'Discourse-Track-View-Topic-Id': '$id',
          })
        : null;
    final response = await _dio.get<String>(
      path,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
      options: (options ?? Options())
          .copyWith(responseType: ResponseType.plain),
    );
    // isolate 内 jsonDecode + fromJson:大话题响应几百 KB~几 MB,主线程
    // 解析实测把 DartIsolate::HandleMessage 顶到 46~56ms(滚动/进话题时
    // 直接掉帧)。结果对象经 Isolate.exit 转移,回传零拷贝。
    return compute(_parseTopicDetailJson, response.data!);
  }

  /// 通过 slug 获取话题详情（返回真实的 topic ID）
  Future<TopicDetail> getTopicDetailBySlug(String slug, {int? postNumber, bool trackVisit = false}) async {
    final path = postNumber != null ? '/t/$slug/$postNumber.json' : '/t/$slug.json';
    final queryParams = <String, dynamic>{};
    if (trackVisit) {
      queryParams['track_visit'] = true;
    }
    // 通过 slug 获取时无法提前知道 topic_id，仅设置 Track-View 头
    final options = trackVisit
        ? Options(headers: {
            'Discourse-Track-View': '1',
          })
        : null;
    final response = await _dio.get<String>(
      path,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
      options: (options ?? Options())
          .copyWith(responseType: ResponseType.plain),
    );
    return compute(_parseTopicDetailJson, response.data!);
  }

  /// 批量获取帖子内容
  Future<PostStream> getPosts(int topicId, List<int> postIds) async {
    final response = await _dio.get<String>(
      '/t/$topicId/posts.json',
      queryParameters: {
        'post_ids[]': postIds,
      },
      options: Options(responseType: ResponseType.plain),
    );
    return compute(_parsePostStreamJson, response.data!);
  }

  /// 按帖子编号获取帖子
  Future<PostStream> getPostsByNumber(int topicId, {required int postNumber, required bool asc}) async {
    final response = await _dio.get<String>(
      '/t/$topicId/posts.json',
      queryParameters: {
        'post_number': postNumber,
        'asc': asc,
      },
      options: Options(responseType: ResponseType.plain),
    );
    return compute(_parsePostStreamJson, response.data!);
  }

  Future<TopicListResponse> getTopTopics() async {
    final response = await _dio.get('/top.json');
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  Future<TopicListResponse> getCategoryTopics(String categorySlug) async {
    final response = await _dio.get('/c/$categorySlug.json');
    // isolate 内构造(jsonDecode 已由 BackgroundTransformer 移出主线程,
    // 几十个 Topic 对象的 fromJson 构造同样不便宜):返回值经
    // Isolate.exit 转移,回传零拷贝
    return compute(_parseTopicListResponse, response.data as Map<String, dynamic>);
  }

  /// 创建话题
  Future<int> createTopic({
    required String title,
    required String raw,
    required int categoryId,
    List<String>? tags,
  }) async {
    final data = <String, dynamic>{
      'title': title,
      'raw': raw,
      'category': categoryId,
      'archetype': 'regular',
    };

    if (tags != null && tags.isNotEmpty) {
      data['tags[]'] = tags;
    }

    final response = await _dio.post(
      '/posts.json',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );

    final respData = response.data;

    // 帖子进入审核队列
    if (respData is Map && respData['action'] == 'enqueued') {
      throw PostEnqueuedException(
        pendingCount: respData['pending_count'] as int? ?? 0,
        pendingPost: _parsePendingPost(respData['pending_post']),
      );
    }

    if (respData is Map && respData.containsKey('post') && respData['post']['topic_id'] != null) {
      return respData['post']['topic_id'] as int;
    }

    if (respData is Map && respData['topic_id'] != null) {
      return respData['topic_id'] as int;
    }

    if (respData is Map && respData['success'] == false) {
      final errors = respData['errors'];
      final msg = errors is List ? errors.join('\n') : errors?.toString();
      throw Exception(msg ?? S.current.error_createTopicFailed);
    }

    throw Exception(S.current.error_unknownResponseFormat);
  }

  /// 忽略新话题/新回复
  Future<void> dismissNewTopics({
    int? categoryId,
    bool dismissTopics = true,
    bool dismissPosts = false,
  }) async {
    final data = <String, dynamic>{
      'dismiss_topics': dismissTopics,
      'dismiss_posts': dismissPosts,
    };
    if (categoryId != null) {
      data['category_id'] = categoryId;
    }
    await _dio.put(
      '/topics/reset-new.json',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  /// 忽略未读话题
  Future<void> dismissUnreadTopics({int? categoryId}) async {
    final data = <String, dynamic>{
      'filter': 'unread',
      'operation': {'type': 'dismiss_posts'},
    };
    if (categoryId != null) {
      data['category_id'] = categoryId;
    }
    await _dio.put(
      '/topics/bulk.json',
      data: data,
    );
  }

  /// 设置话题订阅级别
  Future<void> setTopicNotificationLevel(int topicId, TopicNotificationLevel level) async {
    await _dio.post(
      '/t/$topicId/notifications',
      data: {'notification_level': level.value},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  /// 更新话题元数据
  Future<void> updateTopic({
    required int topicId,
    String? title,
    int? categoryId,
    List<String>? tags,
  }) async {
    try {
      final data = <String, dynamic>{};
      if (title != null) data['title'] = title;
      if (categoryId != null) data['category_id'] = categoryId;
      if (tags != null) data['tags[]'] = tags;

      await _dio.put(
        '/t/-/$topicId.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取话题 AI 摘要。
  ///
  /// Discourse v2026.5.0 起，生成摘要改为 POST（aa3e44b32cf），传入
  /// `stream=true` 后通过 MessageBus 频道推送增量结果。
  Stream<TopicSummary?> watchTopicSummary(
    int topicId, {
    bool skipAgeCheck = false,
  }) async* {
    final messageBus = MessageBusService();
    final channel = '/discourse-ai/summaries/topic/$topicId';
    final updates = StreamController<Map<String, dynamic>>();

    void onMessage(MessageBusMessage message) {
      final data = message.data;
      if (!updates.isClosed && data is Map) {
        updates.add(Map<String, dynamic>.from(data));
      }
    }

    messageBus.subscribe(channel, onMessage);

    try {
      final requestData = <String, dynamic>{'stream': 'true'};
      if (skipAgeCheck) {
        requestData['skip_age_check'] = 'true';
      }

      late Response<dynamic> response;
      try {
        response = await _dio.post(
          '/discourse-ai/summarization/t/$topicId',
          data: requestData,
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
      } on DioException catch (e) {
        final statusCode = e.response?.statusCode;
        if (statusCode != 404 && statusCode != 405) {
          rethrow;
        }

        // 兼容 v2026.5.0 之前仅支持 GET 的 Discourse。
        response = await _dio.get(
          '/discourse-ai/summarization/t/$topicId',
          queryParameters: requestData,
        );
      }

      final responseData = response.data;
      if (responseData is Map && responseData['ai_topic_summary'] is Map) {
        yield TopicSummary.fromJson(
          Map<String, dynamic>.from(responseData['ai_topic_summary'] as Map),
        );
        return;
      }

      await for (final update in updates.stream) {
        if (update['error'] == true) {
          throw StateError(
            update['message'] as String? ?? 'Topic summary generation failed',
          );
        }

        final summaryData = update['ai_topic_summary'];
        if (summaryData is Map) {
          final summaryJson = Map<String, dynamic>.from(summaryData);
          summaryJson['done'] = update['done'];
          yield TopicSummary.fromJson(summaryJson);
        }

        if (update['done'] == true) {
          return;
        }
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 || e.response?.statusCode == 403) {
        yield null;
        return;
      }
      debugPrint('[DiscourseService] watchTopicSummary failed: $e');
      rethrow;
    } finally {
      messageBus.unsubscribe(channel, onMessage);
      await updates.close();
    }
  }

  Future<TopicSummary?> getTopicSummary(
    int topicId, {
    bool skipAgeCheck = false,
  }) {
    return watchTopicSummary(topicId, skipAgeCheck: skipAgeCheck).last;
  }

  /// 获取话题主贴的 HTML 内容（轻量请求，只解析第一楼）
  Future<String?> getTopicFirstPostCooked(int topicId) async {
    final response = await _dio.get('/t/$topicId/1.json');
    final data = response.data as Map<String, dynamic>;
    final postStream = data['post_stream'] as Map<String, dynamic>?;
    final posts = postStream?['posts'] as List<dynamic>?;
    if (posts == null || posts.isEmpty) return null;
    final firstPost = posts.first as Map<String, dynamic>;
    return firstPost['cooked'] as String?;
  }
}

/// isolate 入口:话题详情响应解析(jsonDecode + fromJson 全部移出 UI 线程)
TopicDetail _parseTopicDetailJson(String body) {
  return TopicDetail.fromJson(jsonDecode(body) as Map<String, dynamic>);
}

/// isolate 入口:posts 响应解析(含 topic 级 badges 注入)
PostStream _parsePostStreamJson(String body) {
  final data = jsonDecode(body) as Map<String, dynamic>;
  final streamJson = data.containsKey('post_stream')
      ? data['post_stream'] as Map<String, dynamic>
      : data;
  final postStream = PostStream.fromJson(streamJson);
  PostStream.injectBadges(
    postStream.posts,
    data,
    streamJson['posts'] as List<dynamic>?,
  );
  return postStream;
}

/// isolate 入口:话题列表响应构造
TopicListResponse _parseTopicListResponse(Map<String, dynamic> data) {
  return TopicListResponse.fromJson(data);
}
