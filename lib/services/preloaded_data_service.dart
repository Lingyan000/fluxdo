import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import '../constants.dart';
import '../models/topic.dart';
import '../models/category.dart';
import 'network/discourse_dio.dart';
import 'network/cookie/csrf_token_service.dart';
import 'cf_challenge_service.dart';
import 'cf_clearance_refresh_service.dart';

/// 预加载数据服务
/// 从首页 HTML 的 data-preloaded 属性中提取数据，避免额外 API 请求
class PreloadedDataService {
  static final PreloadedDataService _instance =
      PreloadedDataService._internal();
  factory PreloadedDataService() => _instance;

  final Dio _dio;
  final CsrfTokenService _cookieSync = CsrfTokenService();
  final CfChallengeService _cfChallenge = CfChallengeService();

  // 缓存的预加载数据
  Map<String, dynamic>? _currentUser;
  Map<String, dynamic>? _siteSettings;
  Map<String, dynamic>? _site; // 站点信息（包含 categories）
  Map<String, dynamic>? _topicTrackingStateMeta;
  Map<String, dynamic>? _topicListData; // 首页话题列表原始数据
  TopicListResponse? _cachedTopicListResponse; // 缓存的已解析话题列表
  Completer<TopicListResponse?>? _topicListResponseCompleter;
  List<Map<String, dynamic>>? _customEmoji; // 自定义 emoji
  List<Map<String, dynamic>>? _topicTrackingStates; // 话题追踪状态
  List<String>? _enabledReactions;
  String? _sharedSessionKey; // MessageBus 跨域认证 key
  String? _longPollingBaseUrl; // MessageBus 独立域名
  String _baseUri = ''; // Discourse 子路径前缀（如 /forum）
  String? _cdnUrl; // CDN 域名（从 data-discourse-setup 提取）
  String? _s3CdnUrl; // S3 CDN 域名（如 https://cdn3.linux.do）
  String? _s3BaseUrl; // S3 基础 URL（如 //linuxdo-uploads.s3.linux.do）
  bool _hasDiscourseSetup = false; // 是否提取到 data-discourse-setup 标签
  bool _loaded = false;
  bool _loading = false;

  PreloadedDataService._internal()
    : _dio = DiscourseDio.create(
        defaultHeaders: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      );

  /// 是否已加载数据
  bool get isLoaded => _loaded;
  Map<String, dynamic>? get currentUserSync => _currentUser;
  Map<String, dynamic>? get siteSettingsSync => _siteSettings;
  List<Map<String, dynamic>>? get topicTrackingStatesSync =>
      _topicTrackingStates;

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

  /// 获取系统用户头像模板
  /// 用于通知列表中没有 acting_user 时的默认头像
  Future<String?> getSystemUserAvatarTemplate() async {
    await _ensureLoaded();
    return _site?['system_user_avatar_template'] as String?;
  }

  /// 同步获取分类 ID 集合（预加载数据已加载后可用，用于 Tab 过滤）
  Set<int>? get categoryIdsSync {
    if (_site == null) return null;
    try {
      final categoriesJson = _site!['categories'] as List?;
      if (categoriesJson != null) {
        return categoriesJson
            .map(
              (c) =>
                  int.tryParse(
                    (c as Map<String, dynamic>)['id']?.toString() ?? '0',
                  ) ??
                  0,
            )
            .where((id) => id != 0)
            .toSet();
      }
    } catch (_) {}
    return null;
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
      return topTags
          .map((t) {
            if (t is Map<String, dynamic>) {
              return t['name'] as String? ?? '';
            }
            return t.toString();
          })
          .where((name) => name.isNotEmpty)
          .toList();
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

  /// 获取回复内容最小长度
  Future<int> getMinPostLength() async {
    await _ensureLoaded();
    final value = _siteSettings?['min_post_length'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 8;
    return 8; // Discourse 默认值
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

  /// 检查站点是否开启了 AI 语义搜索
  Future<bool> isAiSemanticSearchEnabled() async {
    await _ensureLoaded();
    return _siteSettings?['ai_embeddings_semantic_search_enabled'] == true;
  }

  /// 获取可用的回应表情列表
  Future<List<String>> getEnabledReactions() async {
    await _ensureLoaded();
    return _enabledReactions ?? ['heart', '+1', 'laughing', 'open_mouth'];
  }

  /// 获取 MessageBus 跨域认证 key（仅独立域名时有值）
  String? get sharedSessionKey => _sharedSessionKey;

  /// 获取 MessageBus 长轮询 base URL（独立域名，如 https://ping.linux.do）
  String? get longPollingBaseUrl => _longPollingBaseUrl;

  /// 获取 Discourse 子路径前缀（如 /forum，根部署时为空字符串）
  String get baseUri => _baseUri;

  /// 获取 CDN URL（如 https://cdn.linux.do）
  String? get cdnUrl => _cdnUrl;

  /// 获取 S3 CDN URL（如 https://cdn3.linux.do）
  String? get s3CdnUrl => _s3CdnUrl;

  /// 获取 S3 基础 URL（如 //linuxdo-uploads.s3.linux.do）
  String? get s3BaseUrl => _s3BaseUrl;

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

  /// 获取自定义 emoji 列表（同步访问，需确保已调用 ensureLoaded）
  /// 返回格式: [{name: "emoji_name", url: "emoji_url"}, ...]
  List<Map<String, dynamic>>? get customEmoji => _customEmoji;

  /// 获取自定义 emoji 列表（异步版本，自动确保数据已加载）
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
    if (_topicListData == null && _topicListResponseCompleter == null) {
      return null;
    }

    try {
      if (_cachedTopicListResponse == null &&
          _topicListResponseCompleter != null) {
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
    _cachedTopicListResponse = null; // 消费后清除
    _topicListData = null;
    _topicListResponseCompleter = null;
    return response;
  }

  /// 强制刷新预加载数据
  Future<void> refresh() async {
    _clearCachedData();
    await _loadPreloadedData();
  }

  /// 直接从已有 HTML 快照恢复预加载数据。
  ///
  /// 适用于登录 WebView 已经拿到完整页面的场景，避免重复请求首页。
  /// 返回是否成功解析到 data-preloaded。
  Future<bool> hydrateFromHtml(String html) async {
    _clearCachedData();
    final parsed = await _parsePreloadedDataFromHtml(html);
    if (!parsed) {
      debugPrint('[PreloadedData] HTML 快照不包含可用的 data-preloaded');
      return false;
    }

    if (!_hasReusableBootstrapData()) {
      debugPrint(
        '[PreloadedData] HTML 快照缺少完整引导数据: '
        'hasSetup=$_hasDiscourseSetup, '
        'hasCurrentUser=${_currentUser != null}, '
        'hasSiteSettings=${_siteSettings != null}, '
        'hasSite=${_site != null}',
      );
      _clearCachedData();
      return false;
    }

    _loaded = true;
    if (_currentUser != null) {
      CfClearanceRefreshService().start();
    }
    debugPrint('[PreloadedData] 已从 HTML 快照恢复数据');
    return true;
  }

  void _clearCachedData() {
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
    _hasDiscourseSetup = false;
    // 以下为站点级基础设施数据，不随用户登录状态变化。
    // 下次 HTML 解析时会自然更新，refresh 窗口期内保留可避免
    // UrlHelper CDN 降级和 MessageBus 连接中断。
    // _cdnUrl, _s3CdnUrl, _s3BaseUrl, _baseUri
    // _longPollingBaseUrl, _sharedSessionKey
  }

  /// 重置缓存（登出时调用）
  void reset() {
    _clearCachedData();
    _baseUri = '';
    _cdnUrl = null;
    _s3CdnUrl = null;
    _s3BaseUrl = null;
    _sharedSessionKey = null;
    _longPollingBaseUrl = null;
  }

  /// 确保数据已加载
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    if (_loading) {
      // 等待正在进行的加载完成
      while (_loading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (_loaded) return; // 上次成功了才跳过
    }
    await _loadPreloadedData();
  }

  /// 加载预加载数据
  Future<void> _loadPreloadedData() async {
    if (_loading) return;
    _loading = true;

    try {
      // 发起 HTTP 请求获取数据
      debugPrint('[PreloadedData] 发起 HTTP 请求');
      final response = await _dio.get(
        AppConstants.baseUrl,
        options: Options(
          headers: {'Accept': 'text/html'},
          extra: {if (AppConstants.skipCsrfForHomeRequest) 'skipCsrf': true},
        ),
      );

      final html = response.data as String;
      await _parsePreloadedDataFromHtml(html);
      debugPrint('[PreloadedData] 数据加载成功');
      _loaded = true;
      // 预热完成，sitekey 已提取；仅在已登录时启动 cf_clearance 自动续期，
      // 避免未登录状态下的 CF 刷新请求干扰 auth 判断
      if (_currentUser != null) {
        CfClearanceRefreshService().start();
      }
    } catch (e) {
      debugPrint('[PreloadedData] 加载失败: $e');
      rethrow;
    } finally {
      _loading = false;
    }
  }

  /// 从 HTML 中解析 data-preloaded 属性
  Future<bool> _parsePreloadedDataFromHtml(String html) async {
    _extractCsrfTokenFromHtml(html);
    _extractSharedSessionKeyFromHtml(html);
    _extractTurnstileSitekeyFromHtml(html);
    _extractBaseUriFromHtml(html);
    _extractCdnUrlFromHtml(html);
    // 提取 data-preloaded 属性内容
    final match = RegExp(r'data-preloaded="([^"]*)"').firstMatch(html);
    if (match == null) {
      debugPrint('[PreloadedData] 未找到 data-preloaded 属性');
      return false;
    }

    // HTML entity 解码已移入 Isolate 中统一处理
    return _parsePreloadedDataString(match.group(1)!);
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

  /// 从 HTML 中提取 shared_session_key（MessageBus 跨域认证）
  void _extractSharedSessionKeyFromHtml(String html) {
    final match = RegExp(
      "<meta[^>]+name=[\"']shared_session_key[\"'][^>]+content=[\"']([^\"']+)[\"']",
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) return;
    final raw = match.group(1);
    if (raw == null || raw.isEmpty) return;
    _sharedSessionKey = raw
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'");
    debugPrint('[PreloadedData] sharedSessionKey 提取成功');
  }

  /// 从 HTML 中提取 Turnstile sitekey（cf_clearance 自动续期用）
  void _extractTurnstileSitekeyFromHtml(String html) {
    final match = RegExp(r'data-sitekey="([0-9a-zA-Zx_-]+)"').firstMatch(html);
    if (match == null) return;
    final sitekey = match.group(1);
    if (sitekey != null && sitekey.isNotEmpty) {
      CfClearanceRefreshService().updateSitekey(sitekey);
    }
  }

  /// 从 HTML 中提取 CDN 配置（data-discourse-setup meta 标签）
  void _extractCdnUrlFromHtml(String html) {
    // 找到 data-discourse-setup 标签的完整内容
    final tagMatch = RegExp(
      r'''id=["']data-discourse-setup["'][^>]*>''',
      caseSensitive: false,
    ).firstMatch(html);
    if (tagMatch == null) return;
    _hasDiscourseSetup = true;
    final tag = tagMatch.group(0)!;

    String? extractAttr(String attrName) {
      final m = RegExp('''data-$attrName=["']([^"']+)["']''').firstMatch(tag);
      if (m == null) return null;
      final v = m.group(1);
      if (v == null || v.isEmpty) return null;
      return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
    }

    _cdnUrl = extractAttr('cdn');
    _s3CdnUrl = extractAttr('s3-cdn');
    _s3BaseUrl = extractAttr('s3-base-url');

    if (_cdnUrl != null) {
      debugPrint('[PreloadedData] cdnUrl: $_cdnUrl');
    }
    if (_s3CdnUrl != null) {
      debugPrint(
        '[PreloadedData] s3CdnUrl: $_s3CdnUrl, s3BaseUrl: $_s3BaseUrl',
      );
    }
  }

  bool _hasReusableBootstrapData() {
    return _hasDiscourseSetup &&
        _currentUser != null &&
        _siteSettings != null &&
        _site != null;
  }

  /// 从 HTML 中提取 discourse-base-uri（子路径部署前缀）
  void _extractBaseUriFromHtml(String html) {
    final match = RegExp(
      "<meta[^>]+name=[\"']discourse-base-uri[\"'][^>]+content=[\"']([^\"']*)[\"']",
      caseSensitive: false,
    ).firstMatch(html);

    final raw = match?.group(1) ?? '';
    if (raw.isEmpty || raw == '/') {
      _baseUri = '';
      return;
    }

    final normalized = raw.startsWith('/') ? raw : '/$raw';
    _baseUri = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    debugPrint('[PreloadedData] baseUri: $_baseUri');
  }

  /// 解析预加载数据字符串
  Future<bool> _parsePreloadedDataString(String dataString) async {
    try {
      // 在 Isolate 中完成 HTML entity 解码 + 外层/内层 JSON 解码
      final preloaded = await compute(
        _decodePreloadedJsonInIsolate,
        dataString,
      );
      if (preloaded == null) {
        debugPrint('[PreloadedData] 预加载 JSON 解析为空');
        return false;
      }

      // 解析 currentUser（已在 Isolate 中完成 jsonDecode）
      if (preloaded.containsKey('currentUser')) {
        _currentUser = preloaded['currentUser'] as Map<String, dynamic>;
        debugPrint(
          '[PreloadedData] currentUser 解析成功: id=${_currentUser?['id']}, '
          'unread_notifications=${_currentUser?['unread_notifications']}, '
          'all_unread=${_currentUser?['all_unread_notifications_count']}',
        );
      }

      // 解析 siteSettings
      if (preloaded.containsKey('siteSettings')) {
        _siteSettings = preloaded['siteSettings'] as Map<String, dynamic>;

        // 提取 reactions 配置
        final reactionsStr =
            _siteSettings?['discourse_reactions_enabled_reactions'] as String?;
        if (reactionsStr != null && reactionsStr.isNotEmpty) {
          _enabledReactions = reactionsStr.split('|');
          debugPrint('[PreloadedData] reactions: $_enabledReactions');
        }

        // 提取 MessageBus 长轮询独立域名
        final pollingUrl = _siteSettings?['long_polling_base_url'] as String?;
        if (pollingUrl != null && pollingUrl.isNotEmpty && pollingUrl != '/') {
          _longPollingBaseUrl = pollingUrl.endsWith('/')
              ? pollingUrl.substring(0, pollingUrl.length - 1)
              : pollingUrl;
          debugPrint(
            '[PreloadedData] longPollingBaseUrl: $_longPollingBaseUrl',
          );
        }
      }

      // 解析 site（包含 categories、top_tags 等）
      if (preloaded.containsKey('site')) {
        _site = preloaded['site'] as Map<String, dynamic>;
        debugPrint(
          '[PreloadedData] site 解析成功, categories=${(_site?['categories'] as List?)?.length ?? 0}',
        );
      }

      // 解析 topicTrackingStateMeta（MessageBus 频道初始 ID）
      if (preloaded.containsKey('topicTrackingStateMeta')) {
        _topicTrackingStateMeta =
            preloaded['topicTrackingStateMeta'] as Map<String, dynamic>;
        debugPrint(
          '[PreloadedData] topicTrackingStateMeta: $_topicTrackingStateMeta',
        );
      }

      // 解析 topicTrackingStates（话题追踪状态）
      if (preloaded.containsKey('topicTrackingStates')) {
        _topicTrackingStates = (preloaded['topicTrackingStates'] as List)
            .cast<Map<String, dynamic>>();
        debugPrint(
          '[PreloadedData] topicTrackingStates: ${_topicTrackingStates?.length ?? 0} items',
        );
      }

      // 解析 customEmoji（自定义 emoji）
      if (preloaded.containsKey('customEmoji')) {
        _customEmoji = (preloaded['customEmoji'] as List)
            .cast<Map<String, dynamic>>();
        debugPrint(
          '[PreloadedData] customEmoji: ${_customEmoji?.length ?? 0} items',
        );
      }

      // 解析首页话题列表（如果存在）
      // 注意：这个数据可能在不同的 key 下，需要检查多个位置
      _parseTopicListFromPreloaded(preloaded);
      return true;
    } catch (e) {
      debugPrint('[PreloadedData] JSON 解析失败: $e');
      return false;
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
            final topicsCount =
                (_topicListData?['topic_list']?['topics'] as List?)?.length ??
                (_topicListData?['topics'] as List?)?.length ??
                0;
            debugPrint(
              '[PreloadedData] topic_list 解析成功 (key=$key), topics=$topicsCount',
            );
            _parseTopicListResponseAsync(_topicListData!);
            return;
          }
        } catch (e) {
          debugPrint('[PreloadedData] 解析 $key 失败: $e');
        }
      }
    }
  }

  void _decodeTopicListAsync(String rawJson) {
    _topicListResponseCompleter ??= Completer<TopicListResponse?>();
    compute(_decodeTopicListInIsolate, rawJson)
        .then((decoded) {
          if (decoded == null) {
            _topicListResponseCompleter?.complete(null);
            return;
          }
          _topicListData = decoded;
          final topicsCount =
              (_topicListData?['topic_list']?['topics'] as List?)?.length ??
              (_topicListData?['topics'] as List?)?.length ??
              0;
          debugPrint(
            '[PreloadedData] topic_list 解析成功 (async), topics=$topicsCount',
          );
          _parseTopicListResponseAsync(decoded);
        })
        .catchError((e) {
          debugPrint('[PreloadedData] 异步解析 topic_list 失败: $e');
          _topicListResponseCompleter?.complete(null);
        });
  }

  void _parseTopicListResponseAsync(Map<String, dynamic> data) {
    _topicListResponseCompleter ??= Completer<TopicListResponse?>();
    compute(_parseTopicListInIsolate, data)
        .then((result) {
          _cachedTopicListResponse = result;
          debugPrint('[PreloadedData] TopicListResponse 异步缓存成功');
          _topicListResponseCompleter?.complete(result);
        })
        .catchError((e) {
          debugPrint('[PreloadedData] 异步解析 TopicListResponse 失败: $e');
          _topicListResponseCompleter?.complete(null);
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
  // HTML entity 解码
  final unescaped = rawJson
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#39;', "'");

  final decoded = jsonDecode(unescaped);
  final Map<String, dynamic> result;
  if (decoded is Map<String, dynamic>) {
    result = decoded;
  } else if (decoded is Map) {
    result = decoded.cast<String, dynamic>();
  } else {
    return null;
  }

  // 内层 value 也是 JSON 字符串，一并在 Isolate 中解码
  // 避免回到主线程后多次 jsonDecode 阻塞 UI
  for (final key in result.keys.toList()) {
    final value = result[key];
    if (value is String) {
      try {
        result[key] = jsonDecode(value);
      } catch (_) {
        // 非 JSON 字符串，保持原值
      }
    }
  }

  return result;
}

TopicListResponse _parseTopicListInIsolate(Map<String, dynamic> json) =>
    TopicListResponse.fromJson(json);
