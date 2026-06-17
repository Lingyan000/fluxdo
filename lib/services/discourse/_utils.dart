part of 'discourse_service.dart';

/// 工具方法
mixin _UtilsMixin on _DiscourseServiceBase {
  /// 获取所有表情列表
  Future<Map<String, List<Emoji>>> getEmojis() async {
    try {
      final response = await _dio.get('/emojis.json');
      final data = response.data as Map<String, dynamic>;

      final Map<String, List<Emoji>> emojiGroups = {};

      data.forEach((group, emojis) {
        if (emojis is List) {
          emojiGroups[group] = emojis
              .map((e) => Emoji.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      });

      return emojiGroups;
    } catch (e) {
      if (e is DioException) {
        throw _handleDioError(e);
      }
      rethrow;
    }
  }

  /// 获取可用的回应表情列表
  Future<List<String>> getEnabledReactions() async {
    final preloaded = PreloadedDataService();
    return preloaded.getEnabledReactions();
  }

  /// 同步获取可用回应表情列表（仅返回已 preload 结果，未 preload 时返回兜底）
  List<String> get enabledReactionsSync =>
      PreloadedDataService().enabledReactionsSync;

  /// 创建私信
  /// 参数语义同 [createReply]
  Future<int> createPrivateMessage({
    required List<String> targetUsernames,
    required String title,
    required String raw,
    String? draftKey,
    ValueChanged<int>? onDraftSequence,
  }) async {
    final data = <String, dynamic>{
      'title': title,
      'raw': raw,
      'archetype': 'private_message',
      'target_recipients': targetUsernames.join(','),
    };
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
      );
    }

    if (respData is Map) {
      final target = respData['target'];
      final seq = (target is Map ? target['draft_sequence'] : null) ??
          respData['draft_sequence'];
      if (seq is int) {
        onDraftSequence?.call(seq);
      }
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
      throw Exception(msg ?? S.current.error_sendPMFailed);
    }

    throw Exception(S.current.error_unknownResponseFormat);
  }

}
