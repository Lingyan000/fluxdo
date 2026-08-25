part of 'discourse_service.dart';

/// 投票相关
mixin _VotingMixin on _DiscourseServiceBase {
  /// 投票
  Future<Poll?> votePoll({
    required int postId,
    required String pollName,
    required List<String> options,
  }) async {
    try {
      final data = {
        'post_id': postId,
        'poll_name': pollName,
      };

      for (int i = 0; i < options.length; i++) {
        data['options[]'] = options[i];
      }

      final response = await _dio.put(
        '/polls/vote',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      if (response.data is Map && response.data['poll'] != null) {
        return Poll.fromJson(response.data['poll'] as Map<String, dynamic>);
      }
      return null;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 撤销投票
  Future<Poll?> removeVote({
    required int postId,
    required String pollName,
  }) async {
    try {
      final response = await _dio.delete(
        '/polls/vote',
        data: {
          'post_id': postId,
          'poll_name': pollName,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      if (response.data is Map && response.data['poll'] != null) {
        return Poll.fromJson(response.data['poll'] as Map<String, dynamic>);
      }
      return null;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 话题投票
  Future<VoteResponse> voteTopicVote(int topicId) async {
    try {
      final response = await _dio.post(
        '/voting/vote',
        data: {'topic_id': topicId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return VoteResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消话题投票
  Future<VoteResponse> unvoteTopicVote(int topicId) async {
    try {
      final response = await _dio.post(
        '/voting/unvote',
        data: {'topic_id': topicId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return VoteResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取话题投票用户列表
  Future<List<VotedUser>> getTopicVoteWho(int topicId) async {
    try {
      final response = await _dio.get(
        '/voting/who',
        queryParameters: {'topic_id': topicId},
      );
      if (response.data is List) {
        return (response.data as List)
            .map((e) => VotedUser.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('[DiscourseService] getTopicVoteWho failed: $e');
      return [];
    }
  }

  // ===== post-voting(问答)插件:帖子赞成/反对 =====

  /// 问答帖子投票(direction: 'up' | 'down')。已投反方向时服务端
  /// 自动改票(删旧建新)。响应仅 {success:"OK"},票数由调用方本地算。
  Future<void> postVotingVote({
    required int postId,
    required String direction,
  }) async {
    try {
      await _dio.post(
        '/post_voting/vote',
        data: {'post_id': postId, 'direction': direction},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 撤销问答帖子投票(受站点撤票时间窗限制,超窗服务端 403)
  Future<void> postVotingRemoveVote({required int postId}) async {
    try {
      await _dio.delete(
        '/post_voting/vote',
        data: {'post_id': postId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 问答帖子投票人列表(服务端最多返回最近 20 条)。
  /// 返回 (voters, totalVotersCount)。
  Future<(List<PostVotingVoter>, int)> getPostVotingVoters(int postId) async {
    try {
      final response = await _dio.get(
        '/post_voting/voters',
        queryParameters: {'post_id': postId},
      );
      final data = response.data;
      if (data is Map) {
        final voters = (data['voters'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PostVotingVoter.fromJson)
            .toList();
        final total = (data['total_voters_count'] as num?)?.toInt() ??
            voters.length;
        return (voters, total);
      }
      return (const <PostVotingVoter>[], 0);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 加载问答帖子的更多评论(id > lastCommentId 的增量)
  Future<List<PostVotingComment>> getPostVotingComments({
    required int postId,
    required int lastCommentId,
  }) async {
    try {
      final response = await _dio.get(
        '/post_voting/comments',
        queryParameters: {'post_id': postId, 'last_comment_id': lastCommentId},
      );
      final data = response.data;
      if (data is Map && data['comments'] is List) {
        return (data['comments'] as List)
            .whereType<Map<String, dynamic>>()
            .map(PostVotingComment.fromJson)
            .toList();
      }
      return const [];
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 创建问答帖子评论,返回新评论
  Future<PostVotingComment> createPostVotingComment({
    required int postId,
    required String raw,
  }) async {
    try {
      final response = await _dio.post(
        '/post_voting/comments',
        data: {'post_id': postId, 'raw': raw},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return PostVotingComment.fromJson(
        response.data as Map<String, dynamic>,
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 给问答评论点赞(评论只有赞没有踩)/ 取消赞
  Future<void> votePostVotingComment({
    required int commentId,
    required bool vote,
  }) async {
    try {
      if (vote) {
        await _dio.post(
          '/post_voting/vote/comment',
          data: {'comment_id': commentId},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
      } else {
        await _dio.delete(
          '/post_voting/vote/comment',
          data: {'comment_id': commentId},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
      }
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }
}
