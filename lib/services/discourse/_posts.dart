part of 'discourse_service.dart';

/// 帖子相关
mixin _PostsMixin on _DiscourseServiceBase {
  /// 创建回复
  ///
  /// 带上 [draftKey] 时,服务端在 [PostCreator] 里会 `DraftSequence.next!`
  /// 推进 sequence(对齐 Discourse 前端 composer.js `_create_serializer` 的
  /// `draft_key` 字段)。响应里的 `target.draft_sequence` 经由 [onDraftSequence]
  /// 回写到本地 `DraftController`,避免发送后用户继续打字触发的草稿保存撞 409。
  Future<Post> createReply({
    required int topicId,
    required String raw,
    int? replyToPostNumber,
    String? draftKey,
    ValueChanged<int>? onDraftSequence,
  }) async {
    final data = <String, dynamic>{
      'topic_id': topicId,
      'raw': raw,
    };

    if (replyToPostNumber != null) {
      data['reply_to_post_number'] = replyToPostNumber;
    }
    if (draftKey != null) {
      data['draft_key'] = draftKey;
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

    if (respData is Map) {
      // 服务端 PostsController 通过 PostSerializer.draft_sequence 把推进后的
      // sequence 挂在响应的 target 里(对齐 composer.js:1382)
      final target = respData['target'];
      final seq = (target is Map ? target['draft_sequence'] : null) ??
          respData['draft_sequence'];
      if (seq is int) {
        onDraftSequence?.call(seq);
      }
    }

    if (respData is Map && respData.containsKey('post') && respData['post'] != null) {
      return Post.fromJson(respData['post'] as Map<String, dynamic>);
    }

    if (respData is Map && respData['id'] != null) {
      return Post.fromJson(respData as Map<String, dynamic>);
    }

    if (respData is Map && respData['success'] == false) {
      final errors = respData['errors'];
      final msg = errors is List ? errors.join('\n') : errors?.toString();
      throw Exception(msg ?? S.current.error_replyFailed);
    }

    throw Exception(S.current.error_unknownResponseFormat);
  }

  /// 点赞帖子
  Future<void> likePost(int postId) async {
    try {
      await _dio.post(
        '/post_actions',
        data: {'id': postId, 'post_action_type_id': 2},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消点赞
  Future<void> unlikePost(int postId) async {
    try {
      await _dio.delete(
        '/post_actions/$postId',
        queryParameters: {'post_action_type_id': 2},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 切换回应
  Future<Map<String, dynamic>> toggleReaction(int postId, String reaction) async {
    try {
      final response = await _dio.put(
        '/discourse-reactions/posts/$postId/custom-reactions/$reaction/toggle.json',
      );
      final data = response.data as Map<String, dynamic>;
      return {
        'reactions': (data['reactions'] as List?)
            ?.map((e) => PostReaction.fromJson(e as Map<String, dynamic>))
            .toList() ?? [],
        'currentUserReaction': data['current_user_reaction'] != null
            ? PostReaction.fromJson(data['current_user_reaction'] as Map<String, dynamic>)
            : null,
      };
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取帖子的回复历史
  Future<List<Post>> getPostReplyHistory(int postId) async {
    final response = await _dio.get('/posts/$postId/reply-history');
    final data = response.data as List<dynamic>;
    return data.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 获取帖子的回复列表
  Future<List<Post>> getPostReplies(int postId, {int after = 1}) async {
    final response = await _dio.get(
      '/posts/$postId/replies',
      queryParameters: {'after': after},
    );
    final data = response.data as List<dynamic>;
    return data.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 通过话题 ID 和楼层编号获取单个帖子
  Future<Post> getPostByNumber(int topicId, int postNumber) async {
    final response = await _dio.get('/posts/by_number/$topicId/$postNumber');
    final data = response.data as Map<String, dynamic>;
    return Post.fromJson(data);
  }

  /// 获取帖子所有层级回复的 ID 列表（递归查询）
  Future<List<int>> getPostReplyIds(int postId) async {
    final response = await _dio.get('/posts/$postId/reply-ids.json');
    final data = response.data as List<dynamic>;
    return data.map((e) => (e as Map<String, dynamic>)['id'] as int).toList();
  }

  /// 获取单个帖子完整数据（用于 MessageBus 刷新）
  Future<Post> getPost(int postId) async {
    final response = await _dio.get('/posts/$postId.json');
    final data = response.data as Map<String, dynamic>;
    return Post.fromJson(data);
  }

  /// 获取帖子原始内容
  Future<String?> getPostRaw(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId.json');
      final data = response.data as Map<String, dynamic>?;
      return data?['raw'] as String?;
    } catch (e) {
      debugPrint('[DiscourseService] getPostRaw failed: $e');
      return null;
    }
  }

  /// 更新帖子内容
  Future<Post> updatePost({
    required int postId,
    required String raw,
    String? editReason,
  }) async {
    try {
      final data = <String, dynamic>{
        'post[raw]': raw,
      };
      if (editReason != null && editReason.isNotEmpty) {
        data['post[edit_reason]'] = editReason;
      }

      final response = await _dio.put(
        '/posts/$postId.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;
      if (respData is Map && respData['post'] != null) {
        return Post.fromJson(respData['post'] as Map<String, dynamic>);
      }
      throw Exception(S.current.error_updatePostFailed);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 添加话题书签
  Future<int> bookmarkTopic(int topicId, {String? name, DateTime? reminderAt, int? autoDeletePreference}) async {
    try {
      final data = <String, dynamic>{
        'bookmarkable_id': topicId,
        'bookmarkable_type': 'Topic',
      };
      if (name != null && name.isNotEmpty) {
        data['name'] = name;
      }
      if (reminderAt != null) {
        data['reminder_at'] = reminderAt.toUtc().toIso8601String();
      }
      if (autoDeletePreference != null) {
        data['auto_delete_preference'] = autoDeletePreference;
      }

      final response = await _dio.post(
        '/bookmarks.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;
      if (respData is Map && respData['id'] != null) {
        return respData['id'] as int;
      }
      throw Exception(S.current.error_unrecognizedDataFormat);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 添加帖子书签
  Future<int> bookmarkPost(int postId, {String? name, DateTime? reminderAt, int? autoDeletePreference}) async {
    try {
      final data = <String, dynamic>{
        'bookmarkable_id': postId,
        'bookmarkable_type': 'Post',
      };
      if (name != null && name.isNotEmpty) {
        data['name'] = name;
      }
      if (reminderAt != null) {
        data['reminder_at'] = reminderAt.toUtc().toIso8601String();
      }
      if (autoDeletePreference != null) {
        data['auto_delete_preference'] = autoDeletePreference;
      }

      final response = await _dio.post(
        '/bookmarks.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;
      if (respData is Map && respData['id'] != null) {
        return respData['id'] as int;
      }
      throw Exception(S.current.error_unrecognizedDataFormat);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 更新书签
  Future<void> updateBookmark(int bookmarkId, {String? name, DateTime? reminderAt, int? autoDeletePreference}) async {
    try {
      final data = <String, dynamic>{};
      // name 传空字符串表示清除
      if (name != null) {
        data['name'] = name;
      }
      if (reminderAt != null) {
        data['reminder_at'] = reminderAt.toUtc().toIso8601String();
      }
      if (autoDeletePreference != null) {
        data['auto_delete_preference'] = autoDeletePreference;
      }

      await _dio.put(
        '/bookmarks/$bookmarkId.json',
        data: data,
        options: Options(contentType: Headers.jsonContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 清除书签提醒
  Future<void> clearBookmarkReminder(int bookmarkId) async {
    try {
      await _dio.put(
        '/bookmarks/bulk.json',
        data: {
          'bookmark_ids': [bookmarkId],
          'operation': {'type': 'clear_reminder'},
        },
        options: Options(contentType: Headers.jsonContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 删除书签
  Future<void> deleteBookmark(int bookmarkId) async {
    try {
      await _dio.delete('/bookmarks/$bookmarkId.json');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 举报帖子
  Future<void> flagPost(int postId, int flagTypeId, {String? message}) async {
    try {
      final data = <String, dynamic>{
        'id': postId,
        'post_action_type_id': flagTypeId,
      };
      if (message != null && message.isNotEmpty) {
        data['message'] = message;
      }

      await _dio.post(
        '/post_actions',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取可用的举报类型
  Future<List<FlagType>> getFlagTypes() async {
    try {
      final response = await _dio.get('/post_action_types.json');
      final data = response.data;
      if (data is Map && data['post_action_types'] != null) {
        return (data['post_action_types'] as List)
            .map((e) => FlagType.fromJson(e as Map<String, dynamic>))
            .where((f) => f.isFlag)
            .toList();
      }
      return FlagType.defaultTypes;
    } catch (e) {
      debugPrint('[DiscourseService] getFlagTypes failed: $e');
      return FlagType.defaultTypes;
    }
  }

  /// 接受答案
  Future<Map<String, dynamic>> acceptAnswer(int postId) async {
    try {
      final response = await _dio.post(
        '/solution/accept',
        data: {'id': postId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消接受答案
  Future<void> unacceptAnswer(int postId) async {
    try {
      await _dio.post(
        '/solution/unaccept',
        data: {'id': postId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 切换 "俺也一样" (shared_issue) 状态
  ///
  /// 同一接口 toggle: 已存在则取消，不存在则创建。
  /// 服务端限流 5 次/小时/用户/帖子，触发后抛 429。
  Future<SharedIssueResponse> toggleSharedIssue(int topicId) async {
    try {
      final response = await _dio.post(
        '/solution/shared_issue',
        data: {'topic_id': topicId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return SharedIssueResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 删除帖子
  Future<void> deletePost(int postId) async {
    try {
      await _dio.delete('/posts/$postId.json');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 恢复已删除的帖子
  Future<void> recoverPost(int postId) async {
    try {
      await _dio.put('/posts/$postId/recover.json');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取帖子回应人列表
  Future<List<ReactionUsersGroup>> getReactionUsers(int postId) async {
    final response = await _dio.get(
      '/discourse-reactions/posts/$postId/reactions-users.json',
    );
    final data = response.data as Map<String, dynamic>;
    final list = data['reaction_users'] as List? ?? [];
    return list
        .map((e) => ReactionUsersGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取隐藏帖子的原始 cooked 内容
  Future<String> getPostCooked(int postId) async {
    final response = await _dio.get('/posts/$postId/cooked.json');
    return (response.data as Map<String, dynamic>)['cooked'] as String;
  }

  /// 追踪链接点击
  void trackClick({
    required String url,
    required int postId,
    required int topicId,
  }) {
    _dio.post(
      '/clicks/track',
      data: {
        'url': url,
        'post_id': postId,
        'topic_id': topicId,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    ).catchError((e) {
      debugPrint('[DiscourseService] trackClick failed: $e');
      return Response(requestOptions: RequestOptions());
    });
  }

  // ==================== Boost ====================

  /// 创建 Boost
  Future<Boost> createBoost(int postId, String raw) async {
    final response = await _dio.post(
      '/discourse-boosts/posts/$postId/boosts',
      data: {'raw': raw},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    return Boost.fromJson(response.data as Map<String, dynamic>);
  }

  /// 删除 Boost
  Future<void> deleteBoost(int boostId) async {
    await _dio.delete('/discourse-boosts/boosts/$boostId');
  }

  /// 获取 Boost 详情（包含权限信息）
  Future<Boost> getBoost(int boostId) async {
    final response = await _dio.get('/discourse-boosts/boosts/$boostId');
    return Boost.fromJson(response.data as Map<String, dynamic>);
  }

  /// 举报 Boost
  Future<void> flagBoost(int boostId, {required int flagTypeId, String? message}) async {
    try {
      final data = <String, dynamic>{
        'flag_type_id': flagTypeId,
      };
      if (message != null && message.isNotEmpty) {
        data['message'] = message;
      }
      await _dio.post(
        '/discourse-boosts/boosts/$boostId/flags',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }
}
