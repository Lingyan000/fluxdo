part of 'discourse_service.dart';

/// 搜索相关
mixin _SearchMixin on _DiscourseServiceBase {
  /// 搜索帖子/用户
  ///
  /// [typeFilter] 用于指定搜索类型，可选值：topic, post, user, category, tag
  /// 注意：分页只有在指定 typeFilter 时才会生效
  Future<SearchResult> search({
    required String query,
    int page = 1,
    String? typeFilter,
  }) async {
    final response = await _dio.get(
      '/search.json',
      queryParameters: {
        'q': query,
        if (page > 1) 'page': page,
        if (typeFilter != null) 'type_filter': typeFilter,
      },
    );
    return SearchResult.fromJson(response.data);
  }

  /// AI 语义搜索
  /// 返回格式与标准搜索一致（使用 GroupedSearchResultSerializer）
  Future<SearchResult> semanticSearch({required String query}) async {
    final response = await _dio.get(
      '/discourse-ai/embeddings/semantic-search',
      queryParameters: {'q': query},
    );
    return SearchResult.fromJson(response.data);
  }

  /// 获取最近搜索记录
  Future<List<String>> getRecentSearches() async {
    try {
      final response = await _dio.get('/u/recent-searches.json');
      final List<dynamic> searches = response.data['recent_searches'] ?? [];
      return searches.cast<String>();
    } catch (e) {
      return [];
    }
  }

  /// 清空最近搜索记录
  Future<void> clearRecentSearches() async {
    await _dio.delete('/u/recent-searches.json');
  }

  /// 搜索标签
  ///
  /// [filterForInput] 为 true 时只返回当前分类允许的标签（创建话题用），
  /// 为 false 时返回所有标签（筛选/浏览用）。
  Future<TagSearchResult> searchTags({
    String query = '',
    int? categoryId,
    List<String>? selectedTags,
    int? limit,
    bool filterForInput = false,
  }) async {
    try {
      final queryParams = <String, dynamic>{
        'q': query,
        if (filterForInput) 'filterForInput': true,
      };
      if (limit != null) {
        queryParams['limit'] = limit;
      }
      if (categoryId != null) {
        queryParams['categoryId'] = categoryId;
      }
      if (selectedTags != null && selectedTags.isNotEmpty) {
        queryParams['selected_tags'] = selectedTags;
      }

      final response = await _dio.get('/tags/filter/search', queryParameters: queryParams);
      return TagSearchResult.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[DiscourseService] searchTags failed: $e');
      return TagSearchResult(results: []);
    }
  }

  /// 搜索用户（用于 @提及自动补全 / 私信收件人选择）
  ///
  /// [includeMessageableGroups]：只返回**当前用户能发私信**的群组
  /// （Discourse users_controller#search_users 的三个群组开关语义不同：
  /// `include_groups` = 所有可见群组、`include_mentionable_groups` = 可 @
  /// 的群组、`include_messageable_groups` = 可发私信的群组）。新建私信选
  /// 收件人时应当只开这一个，另两个关掉——否则会列出发不了私信的群组。
  Future<MentionSearchResult> searchUsers({
    required String term,
    int? topicId,
    int? categoryId,
    bool includeGroups = true,
    bool includeMessageableGroups = false,
    int limit = 6,
  }) async {
    try {
      final queryParams = <String, dynamic>{
        'term': term,
        'include_groups': includeGroups,
        'limit': limit,
      };
      if (includeMessageableGroups) {
        queryParams['include_messageable_groups'] = true;
        // 新建私信不绑定话题：不限定「话题可见用户」，否则搜不到人
        queryParams['topic_allowed_users'] = false;
      }
      if (topicId != null) {
        queryParams['topic_id'] = topicId;
      }
      if (categoryId != null) {
        queryParams['category_id'] = categoryId;
      }

      final response = await _dio.get('/u/search/users', queryParameters: queryParams);
      return MentionSearchResult.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[DiscourseService] searchUsers failed: $e');
      return const MentionSearchResult(users: [], groups: []);
    }
  }

  /// 验证 @ 提及的用户/群组是否有效
  Future<MentionCheckResult> checkMentions(List<String> names) async {
    if (names.isEmpty) {
      return const MentionCheckResult();
    }
    try {
      final response = await _dio.get(
        '/composer/mentions',
        queryParameters: {
          'names[]': names,
        },
      );
      return MentionCheckResult.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[DiscourseService] checkMentions failed: $e');
      return const MentionCheckResult();
    }
  }
}
