part of 'discourse_service.dart';

/// 草稿序列号冲突异常(对应服务端 409)
class DraftSequenceConflictException implements Exception {
  const DraftSequenceConflictException();
  @override
  String toString() => 'DraftSequenceConflictException';
}

/// 草稿相关 API
mixin _DraftsMixin on _DiscourseServiceBase {
  /// 获取草稿列表
  Future<DraftListResponse> getDrafts({int offset = 0, int limit = 20}) async {
    try {
      final response = await _dio.get(
        '/drafts.json',
        queryParameters: {
          'offset': offset,
          'limit': limit,
        },
      );
      return DraftListResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取指定草稿
  /// 返回 null 表示草稿不存在
  Future<Draft?> getDraft(String draftKey) async {
    try {
      final response = await _dio.get('/drafts/$draftKey.json');
      final data = response.data;
      if (data is Map<String, dynamic> && data.containsKey('draft')) {
        final draftData = data['draft'];
        if (draftData == null) return null;
        return Draft.fromJson({
          'draft_key': draftKey,
          'data': draftData,
          'draft_sequence': data['draft_sequence'] as int? ?? 0,
        });
      }
      return null;
    } on DioException catch (e) {
      // 404 表示草稿不存在
      if (e.response?.statusCode == 404) return null;
      _throwApiError(e);
    }
  }

  /// 保存草稿
  /// 返回新的序列号
  /// [forceSave] 为 true 时绕过服务端 sequence 校验(用于 409 冲突后重试)
  /// 409 冲突时抛出 [DraftSequenceConflictException],上层应带 forceSave=true 重试
  Future<int> saveDraft({
    required String draftKey,
    required DraftData data,
    int sequence = 0,
    bool forceSave = false,
  }) async {
    try {
      final response = await _dio.post(
        '/drafts.json',
        data: {
          'draft_key': draftKey,
          'data': data.toJsonString(),
          'sequence': sequence,
          if (forceSave) 'force_save': true,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final respData = response.data;
      if (respData is Map) {
        return respData['draft_sequence'] as int? ?? (sequence + 1);
      }
      return sequence + 1;
    } on DioException catch (e) {
      // 服务端 409 响应只含 errors/extras,不带 draft_sequence,
      // 必须靠下次 force_save 兜底
      if (e.response?.statusCode == 409) {
        throw const DraftSequenceConflictException();
      }
      _throwApiError(e);
    }
  }

  /// 删除草稿
  Future<void> deleteDraft(String draftKey, {int sequence = 0}) async {
    try {
      await _dio.delete(
        '/drafts/$draftKey.json',
        queryParameters: {'sequence': sequence},
      );
      // 发送/舍弃都经这里 —— 通知草稿列表把这条去掉（见 DraftsSignal）
      DraftsSignal.notifyChanged();
    } on DioException catch (e) {
      // 忽略 404（草稿已不存在）：服务端也没有了，同样要通知
      if (e.response?.statusCode == 404) {
        DraftsSignal.notifyChanged();
        return;
      }
      _throwApiError(e);
    }
  }
}
