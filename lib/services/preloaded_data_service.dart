import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import '../constants.dart';
import '../models/topic.dart';
import '../models/category.dart';
import 'network/discourse_dio.dart';
import 'network/cookie/cookie_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'cf_challenge_service.dart';
import 'auth_log_service.dart';
import 'auth_verify_service.dart';

/// 预加载数据服务
/// 从首页 HTML 的 data-preloaded 属性中提取数据，避免额外 API 请求
class PreloadedDataService {
  static final PreloadedDataService _instance = PreloadedDataService._internal();
  factory PreloadedDataService() => _instance;

  final Dio _dio;
  final CookieSyncService _cookieSync = CookieSyncService();
  final CfChallengeService _cfChallenge = CfChallengeService();

  // 缓存的预加载数据
  Map<String, dynamic>? _currentUser;
  Map<String, dynamic>? _siteSettings;
  Map<String, dynamic>? _site;           // 站点信息（包含 categories）
  Map<String, dynamic>? _topicTrackingStateMeta;
  Map<String, dynamic>? _topicListData;  // 首页话题列表原始数据
  TopicListResponse? _cachedTopicListResponse;  // 缓存的已解析话题列表
  Completer<TopicListResponse?>? _topicListResponseCompleter;
  List<Map<String, dynamic>>? _customEmoji;  // 自定义 emoji
  List<Map<String, dynamic>>? _topicTrackingStates;  // 话题追踪状态
  List<String>? _enabledReactions;
  bool _loaded = false;
  bool _loading = false;
  Completer<void>? _loadingCompleter;

  // 登录失效回调
  void Function()? _onAuthInvalidCallback;

  PreloadedDataService._internal()
      : _dio = DiscourseDio.create(
          defaultHeaders: {
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        );

  /// 是否已加载数据
  bool get isLoaded => _loaded;
  Map<String, dynamic>? get currentUserSync => _currentUser;

  /// 设置登录失效回调
  void setAuthInvalidCallback(void Function() callback) {
    _onAuthInvalidCallback = callback;
  }

  /// 设置导航 context（用于弹出 CF 验证页面）
  void setNavigatorContext(BuildContext context) {
    _cfChallenge.setContext(context);
  }

  /// 确保预加载数据已准备好
  Future<void> ensureLoaded() async {
    await _ensureLoaded();
  }

  /// 获取 currentUser 数据（包含通知计数等）
  Future<Map<String, dynamic>?> getCurrentUser() async {
    await _ensureLoaded();
    return _currentUser;
  }

  /// 获取站点设置
  Future<Map<String, dynamic>?> getSiteSettings() async {
    await _ensureLoaded();
    return _siteSettings;
  }

  /// 获取站点信息（包含 categories、top_tags 等）
  Future<Map<String, dynamic>?> getSite() async {
    await _ensureLoaded();
    return _site;
  }

  /// 获取分类列表（从预加载的 site 数据中提取）
  Future<List<Category>?> getCategories() async {
    await _ensureLoaded();
    if (_site == null) return null;

    try {
      final categoriesJson = _site!['categories'] as List?;
      if (categoriesJson != null) {
        return categoriesJson
            .map((c) => Category.fromJson(c as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('[PreloadedData] 解析 categories 失败: $e');
    }
    return null;
  }

  /// 获取热门标签（从预加载的 site 数据中提取）
  Future<List<String>?> getTopTags() async {
    await _ensureLoaded();
    if (_site == null) return null;

    final topTags = _site!['top_tags'] as List?;
    if (topTags != null) {
      // 兼容新旧格式：如果是对象则取 name 字段，如果是字符串则直接用
      return topTags.map((t) {
        if (t is Map<String, dynamic>) {
          return t['name'] as String? ?? '';
        }
        return t.toString();
      }).where((name) => name.isNotEmpty).toList();
    }
    return null;
  }

  /// 获取帖子操作类型（举报类型等）
  Future<List<Map<String, dynamic>>?> getPostActionTypes() async {
    await _ensureLoaded();
    if (_site == null) return null;

    final types = _site!['post_action_types'] as List?;
    if (types != null) {
      return types.cast<Map<String, dynamic>>();
    }
    return null;
  }

  /// 检查站点是否支持标签功能
  Future<bool?> canTagTopics() async {
    await _ensureLoaded();
    if (_site == null) return null;
    return _site!['can_tag_topics'] as bool?;
  }

  /// 获取默认发帖分类 ID
  /// 从 siteSettings 的 default_composer_category 获取
  Future<int?> getDefaultComposerCategoryId() async {
    await _ensureLoaded();
    if (_siteSettings == null) return null;
    final value = _siteSettings!['default_composer_category'];
    if (value == null) return null;
    if (value is int) {
      // 忽略无效值（-1 或 0 表示未设置）
      if (value <= 0) return null;
      return value;
    }
    if (value is String && value.isNotEmpty) {
      final parsed = int.tryParse(value);
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  /// 获取话题标题最小长度
  Future<int> getMinTopicTitleLength() async {
    await _ensureLoaded();
    final value = _siteSettings?['min_topic_title_length'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 15;
    return 15; // Discourse 默认值
  }

  /// 获取私信标题最小长度
  Future<int> getMinPmTitleLength() async {
    await _ensureLoaded();
    final value = _siteSettings?['min_personal_message_title_length'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 2;
    return 2; // Discourse 默认值
  }

  /// 获取首贴内容最小长度
  Future<int> getMinFirstPostLength() async {
    await _ensureLoaded();
    final value = _siteSettings?['min_first_post_length'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 20;
    return 20; // Discourse 默认值
  }

  /// 获取私信内容最小长度
  Future<int> getMinPmPostLength() async {
    await _ensureLoaded();
    final value = _siteSettings?['min_personal_message_post_length'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 10;
    return 10; // Discourse 默认值
  }

  /// 获取可用的回应表情列表
  Future<List<String>> getEnabledReactions() async {
    await _ensureLoaded();
    return _enabledReactions ?? ['heart', '+1', 'laughing', 'open_mouth'];
  }

  /// 获取 MessageBus 频道的初始 message ID
  /// 返回格式: {'/latest': 6855147, '/new': 104155, ...}
  Future<Map<String, dynamic>?> getTopicTrackingStateMeta() async {
    await _ensureLoaded();
    return _topicTrackingStateMeta;
  }

  /// 获取话题追踪状态列表（未读、新话题等）
  /// 用于初始化侧边栏的未读计数
  Future<List<Map<String, dynamic>>?> getTopicTrackingStates() async {
    await _ensureLoaded();
    return _topicTrackingStates;
  }

  /// 获取自定义 emoji 列表
  /// 返回格式: [{name: "emoji_name", url: "emoji_url"}, ...]
  Future<List<Map<String, dynamic>>?> getCustomEmoji() async {
    await _ensureLoaded();
    return _customEmoji;
  }

  /// 获取预加载的首页话题列表（仅首次加载时有效）
  /// 返回 TopicListResponse 或 null
  Future<TopicListResponse?> getInitialTopicList() async {
    await _ensureLoaded();
    if (_cachedTopicListResponse != null) {
      final response = _cachedTopicListResponse;
      _cachedTopicListResponse = null;
      _topicListData = null;
      _topicListResponseCompleter = null;
      return response;
    }
    if (_topicListData == null && _topicListResponseCompleter == null) return null;

    try {
      if (_cachedTopicListResponse == null && _topicListResponseCompleter != null) {
        await _topicListResponseCompleter!.future;
      }
      if (_cachedTopicListResponse == null) return null;
      final response = _cachedTopicListResponse;
      _cachedTopicListResponse = null;
      _topicListData = null;
      _topicListResponseCompleter = null;
      return response;
    } catch (e) {
      debugPrint('[PreloadedData] 解析 topic_list 失败: $e');
      _topicListData = null;
      _topicListResponseCompleter = null;
      return null;
    }
  }

  /// 检查是否有预加载的话题列表可用
  bool get hasInitialTopicList =>
      _cachedTopicListResponse != null ||
      _topicListData != null ||
      _topicListResponseCompleter != null;

  /// 同步获取预加载的话题列表（如果已加载）
  /// 返回 TopicListResponse 或 null
  /// 注意：此方法会消费数据，只能调用一次
  TopicListResponse? getInitialTopicListSync() {
    if (_cachedTopicListResponse == null) return null;
    final response = _cachedTopicListResponse;
    _cachedTopicListResponse = null;  // 消费后清除
    _topicListData = null;
    _topicListResponseCompleter = null;
    return response;
  }

  /// 强制刷新预加载数据
  Future<void> refresh() async {
    _loaded = false;
    _currentUser = null;
    _siteSettings = null;
    _site = null;
    _topicListData = null;
    _cachedTopicListResponse = null;
    _topicListResponseCompleter = null;
    _customEmoji = null;
    _topicTrackingStates = null;
    _enabledReactions = null;
    _topicTrackingStateMeta = null;
    await _loadPreloadedData();
  }

  /// 重置缓存（登出时调用）
  void reset() {
    _loaded = false;
    _currentUser = null;
    _siteSettings = null;
    _site = null;
    _topicListData = null;
    _cachedTopicListResponse = null;
    _topicListResponseCompleter = null;
    _customEmoji = null;
    _topicTrackingStates = null;
    _topicTrackingStateMeta = null;
    _enabledReactions = null;
  }

  /// 确保数据已加载
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    if (_loading && _loadingCompleter != null) {
      // 等待正在进行的加载完成（无忙等待）
      await _loadingCompleter!.future;
      return;
    }
    await _loadPreloadedData();
  }

  /// 加载预加载数据
  Future<void> _loadPreloadedData() async {
    if (_loading) return;
    _loading = true;
    _loadingCompleter = Completer<void>();

    try {
      // 发起 HTTP 请求获取数据
      debugPrint('[PreloadedData] 发起 HTTP 请求');
      final response = await _dio.get(
        AppConstants.baseUrl,
        options: Options(
          headers: {'Accept': 'text/html'},
          extra: {
            if (AppConstants.skipCsrfForHomeRequest) 'skipCsrf': true,
          },
        ),
      );

      final html = response.data as String;
      await _parsePreloadedDataFromHtml(html);
      _loaded = true;
      debugPrint('[PreloadedData] 数据加载成功');
    } catch (e) {
      debugPrint('[PreloadedData] 加载失败: $e');
    } finally {
      _loading = false;
      _loadingCompleter?.complete();
      _loadingCompleter = null;
    }
  }

  /// 从 HTML 中解析 data-preloaded 属性
  Future<void> _parsePreloadedDataFromHtml(String html) async {
    _extractCsrfTokenFromHtml(html);
    // 提取 data-preloaded 属性内容
    final match = RegExp(r'data-preloaded="([^"]*)"').firstMatch(html);
    if (match == null) {
      debugPrint('[PreloadedData] 未找到 data-preloaded 属性');
      return;
    }

    // 解码 HTML entities
    final decoded = match.group(1)!
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'");

    await _parsePreloadedDataString(decoded);
  }

  void _extractCsrfTokenFromHtml(String html) {
    final match = RegExp(
      "<meta[^>]+name=[\"']csrf-token[\"'][^>]+content=[\"']([^\"']+)[\"']",
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) return;
    final raw = match.group(1);
    if (raw == null || raw.isEmpty) return;
    final decoded = raw
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'");
    _cookieSync.setCsrfToken(decoded);
  }

  /// 解析预加载数据字符串
  Future<void> _parsePreloadedDataString(String dataString) async {
    // 解码 HTML entities（WebView 返回的数据可能也需要解码）
    final decoded = dataString
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'");

    try {
      // 外层是 JSON 对象，key 是数据类型，value 是 JSON 字符串
      final preloaded = await compute(_decodePreloadedJsonInIsolate, decoded);
      if (preloaded == null) {
        debugPrint('[PreloadedData] 预加载 JSON 解析为空');
        return;
      }

      // 解析 currentUser
      if (preloaded.containsKey('currentUser')) {
        final currentUserJson = preloaded['currentUser'] as String;
        _currentUser = jsonDecode(currentUserJson) as Map<String, dynamic>;
        debugPrint('[PreloadedData] currentUser 解析成功: id=${_currentUser?['id']}, '
            'unread_notifications=${_currentUser?['unread_notifications']}, '
            'all_unread=${_currentUser?['all_unread_notifications_count']}');
      } else {
        // 检查登录失效：有 token 但没有 currentUser
        _checkAuthInvalid();
      }

      // 解析 siteSettings
      if (preloaded.containsKey('siteSettings')) {
        final siteSettingsJson = preloaded['siteSettings'] as String;
        _siteSettings = jsonDecode(siteSettingsJson) as Map<String, dynamic>;

        // 提取 reactions 配置
        final reactionsStr = _siteSettings?['discourse_reactions_enabled_reactions'] as String?;
        if (reactionsStr != null && reactionsStr.isNotEmpty) {
          _enabledReactions = reactionsStr.split('|');
          debugPrint('[PreloadedData] reactions: $_enabledReactions');
        }
      }

      // 解析 site（包含 categories、top_tags 等）
      if (preloaded.containsKey('site')) {
        final siteJson = preloaded['site'] as String;
        _site = jsonDecode(siteJson) as Map<String, dynamic>;
        debugPrint('[PreloadedData] site 解析成功, categories=${(_site?['categories'] as List?)?.length ?? 0}');
      }

      // 解析 topicTrackingStateMeta（MessageBus 频道初始 ID）
      if (preloaded.containsKey('topicTrackingStateMeta')) {
        final metaJson = preloaded['topicTrackingStateMeta'] as String;
        _topicTrackingStateMeta = jsonDecode(metaJson) as Map<String, dynamic>;
        debugPrint('[PreloadedData] topicTrackingStateMeta: $_topicTrackingStateMeta');
      }

      // 解析 topicTrackingStates（话题追踪状态）
      if (preloaded.containsKey('topicTrackingStates')) {
        final statesJson = preloaded['topicTrackingStates'] as String;
        final statesList = jsonDecode(statesJson) as List;
        _topicTrackingStates = statesList.cast<Map<String, dynamic>>();
        debugPrint('[PreloadedData] topicTrackingStates: ${_topicTrackingStates?.length ?? 0} items');
      }

      // 解析 customEmoji（自定义 emoji）
      if (preloaded.containsKey('customEmoji')) {
        final emojiJson = preloaded['customEmoji'] as String;
        final emojiList = jsonDecode(emojiJson) as List;
        _customEmoji = emojiList.cast<Map<String, dynamic>>();
        debugPrint('[PreloadedData] customEmoji: ${_customEmoji?.length ?? 0} items');
      }

      // 解析首页话题列表（如果存在）
      // 注意：这个数据可能在不同的 key 下，需要检查多个位置
      _parseTopicListFromPreloaded(preloaded);

    } catch (e) {
      debugPrint('[PreloadedData] JSON 解析失败: $e');
    }
  }

  /// 从预加载数据中解析话题列表
  void _parseTopicListFromPreloaded(Map<String, dynamic> preloaded) {
    // 尝试多个可能的 key
    final possibleKeys = ['topicList', 'topic_list', 'latest'];

    for (final key in possibleKeys) {
      if (preloaded.containsKey(key)) {
        try {
          final value = preloaded[key];
          if (value is String) {
            _decodeTopicListAsync(value);
            return;
          } else if (value is Map) {
            _topicListData = value as Map<String, dynamic>;
          }

          if (_topicListData != null) {
            final topicsCount = (_topicListData?['topic_list']?['topics'] as List?)?.length ??
                               (_topicListData?['topics'] as List?)?.length ?? 0;
            debugPrint('[PreloadedData] topic_list 解析成功 (key=$key), topics=$topicsCount');
            _parseTopicListResponseAsync(_topicListData!);
            return;
          }
        } catch (e) {
          debugPrint('[PreloadedData] 解析 $key 失败: $e');
        }
      }
    }
  }

  /// 检查登录失效：有 token 但没有 currentUser
  Future<void> _checkAuthInvalid() async {
    try {
      final tToken = await CookieJarService().getTToken();
      if (tToken != null && tToken.isNotEmpty) {
        debugPrint('[PreloadedData] 检测到登录失效：有 token 但没有 currentUser');
        
        // 记录日志
        await AuthLogService().logAuthInvalid(
          source: 'preloaded_data',
          reason: '有 token 但没有 currentUser',
        );
        
        // WebView 二次验证
        final verifyResult = await AuthVerifyService().verifyLoginStatus();
        if (verifyResult == true) {
          debugPrint('[PreloadedData] WebView 验证成功，恢复登录');
          await refresh(); // 重新加载预加载数据
          return;
        }
        
        // 确认是真正的登出
        _onAuthInvalidCallback?.call();
      }
    } catch (e) {
      debugPrint('[PreloadedData] 检查登录失效失败: $e');
    }
  }

  void _decodeTopicListAsync(String rawJson) {
    _topicListResponseCompleter ??= Completer<TopicListResponse?>();
    () async {
      try {
        final decoded = await compute(_decodeTopicListInIsolate, rawJson);
        if (decoded == null) {
          _topicListResponseCompleter?.complete(null);
          return;
        }
        _topicListData = decoded;
        final topicsCount = (_topicListData?['topic_list']?['topics'] as List?)?.length ??
            (_topicListData?['topics'] as List?)?.length ??
            0;
        debugPrint('[PreloadedData] topic_list 解析成功 (async), topics=$topicsCount');
        _parseTopicListResponseAsync(decoded);
      } catch (e) {
        debugPrint('[PreloadedData] 异步解析 topic_list 失败: $e');
        _topicListResponseCompleter?.complete(null);
      }
    }();
  }

  void _parseTopicListResponseAsync(Map<String, dynamic> data) {
    _topicListResponseCompleter ??= Completer<TopicListResponse?>();
    Future(() {
      try {
        _cachedTopicListResponse = TopicListResponse.fromJson(data);
        debugPrint('[PreloadedData] TopicListResponse 异步缓存成功');
        _topicListResponseCompleter?.complete(_cachedTopicListResponse);
      } catch (e) {
        debugPrint('[PreloadedData] 异步解析 TopicListResponse 失败: $e');
        _topicListResponseCompleter?.complete(null);
      }
    });
  }
}

Map<String, dynamic>? _decodeTopicListInIsolate(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.cast<String, dynamic>();
  }
  return null;
}

Map<String, dynamic>? _decodePreloadedJsonInIsolate(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.cast<String, dynamic>();
  }
  return null;
}
