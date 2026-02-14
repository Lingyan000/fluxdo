import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../pages/user_profile_page.dart';
import '../pages/webview_page.dart';
import '../constants.dart';
import 'discourse/discourse_service.dart';

/// Deep Link 服务
/// 处理从外部链接打开应用的场景
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService _instance = DeepLinkService._();
  static DeepLinkService get instance => _instance;

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  BuildContext? _navigatorContext;
  bool _initialized = false;

  /// 防重复：记录最近处理的链接和时间
  Uri? _lastHandledUri;
  DateTime? _lastHandledTime;

  /// 话题链接正则（带 ID）
  /// 支持格式：
  /// - /t/topic-slug/123
  /// - /t/topic-slug/123/5 (指定帖子编号)
  /// - /t/topic/123 (topic 是固定占位符)
  static final _topicWithIdRegex = RegExp(
    r'/t/([^/]+)/(\d+)(?:/(\d+))?',
    caseSensitive: false,
  );

  /// 话题链接正则（直接 ID）
  /// 支持格式：
  /// - /t/123 (直接跟 ID，没有 slug)
  static final _topicIdOnlyRegex = RegExp(
    r'/t/(\d+)(?:/(\d+))?(?:[/?#]|$)',
    caseSensitive: false,
  );

  /// 话题链接正则（只有 slug）
  /// 支持格式：
  /// - /t/topic-slug (只有 slug，需要通过 API 查询)
  static final _topicSlugOnlyRegex = RegExp(
    r'/t/([^/\d][^/?#]*)$',
    caseSensitive: false,
  );

  /// 用户链接正则
  /// 支持格式：
  /// - https://linux.do/u/username
  static final _userRegex = RegExp(
    r'/u/([^/?#]+)',
    caseSensitive: false,
  );

  /// 初始化服务
  /// 在主页面初始化后调用
  void initialize(BuildContext context) {
    _navigatorContext = context;

    if (_initialized) return;
    _initialized = true;

    // 处理应用冷启动时的链接
    _handleInitialLink();

    // 监听后续链接
    _linkSubscription = _appLinks.uriLinkStream.listen(_handleLink);
  }

  /// 更新导航 context
  void updateContext(BuildContext context) {
    _navigatorContext = context;
  }

  /// 处理初始链接（冷启动）
  Future<void> _handleInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        // 延迟处理，确保导航 context 已就绪
        await Future.delayed(const Duration(milliseconds: 500));
        _handleLink(uri);
      }
    } catch (e) {
      debugPrint('DeepLinkService: 获取初始链接失败: $e');
    }
  }

  /// 处理链接
  void _handleLink(Uri uri) {
    if (_navigatorContext == null) {
      debugPrint('DeepLinkService: 导航 context 未就绪');
      return;
    }

    // 防重复：1秒内相同链接不重复处理
    final now = DateTime.now();
    if (_lastHandledUri == uri &&
        _lastHandledTime != null &&
        now.difference(_lastHandledTime!).inSeconds < 1) {
      debugPrint('DeepLinkService: 忽略重复链接 $uri');
      return;
    }
    _lastHandledUri = uri;
    _lastHandledTime = now;

    final context = _navigatorContext!;
    final url = uri.toString();

    debugPrint('DeepLinkService: 收到链接 $url');

    // 尝试匹配用户链接 /u/username
    final userMatch = _userRegex.firstMatch(uri.path);
    if (userMatch != null) {
      final username = userMatch.group(1);
      if (username != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => UserProfilePage(username: username),
          ),
        );
        return;
      }
    }

    // 尝试匹配话题链接（直接 ID）：/t/123 或 /t/123/5
    final topicIdOnlyMatch = _topicIdOnlyRegex.firstMatch(uri.path);
    if (topicIdOnlyMatch != null) {
      final topicId = int.tryParse(topicIdOnlyMatch.group(1) ?? '');
      final postNumber = int.tryParse(topicIdOnlyMatch.group(2) ?? '');

      if (topicId != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: topicId,
              scrollToPostNumber: postNumber,
            ),
          ),
        );
        return;
      }
    }

    // 尝试匹配话题链接（带 ID）：/t/topic-slug/123 或 /t/topic-slug/123/5
    final topicWithIdMatch = _topicWithIdRegex.firstMatch(uri.path);
    if (topicWithIdMatch != null) {
      final topicId = int.tryParse(topicWithIdMatch.group(2) ?? '');
      final postNumber = int.tryParse(topicWithIdMatch.group(3) ?? '');

      if (topicId != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: topicId,
              scrollToPostNumber: postNumber,
            ),
          ),
        );
        return;
      }
    }

    // 尝试匹配话题链接（只有 slug）：/t/topic-slug
    final topicSlugMatch = _topicSlugOnlyRegex.firstMatch(uri.path);
    if (topicSlugMatch != null) {
      final slug = topicSlugMatch.group(1);
      if (slug != null) {
        // 通过 slug 获取话题详情，提取真实的 topic ID
        _handleTopicBySlug(context, slug);
        return;
      }
    }

    // 其他站点链接：使用内置浏览器
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    if (uri.host == baseHost || uri.host.endsWith('.$baseHost')) {
      WebViewPage.open(context, url);
      return;
    }

    // 自定义 scheme (fluxdo://...)
    if (uri.scheme == 'fluxdo') {
      _handleCustomScheme(context, uri);
      return;
    }

    debugPrint('DeepLinkService: 未知链接类型 $url');
  }

  /// 处理自定义 scheme
  /// 支持格式：
  /// - fluxdo://topic/123
  /// - fluxdo://topic/123/5 (指定楼层)
  /// - fluxdo://user/username
  void _handleCustomScheme(BuildContext context, Uri uri) {
    final pathSegments = uri.pathSegments;

    if (pathSegments.isEmpty) return;

    switch (pathSegments[0]) {
      case 'topic':
        if (pathSegments.length >= 2) {
          final topicId = int.tryParse(pathSegments[1]);
          final postNumber = pathSegments.length >= 3
              ? int.tryParse(pathSegments[2])
              : null;

          if (topicId != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TopicDetailPage(
                  topicId: topicId,
                  scrollToPostNumber: postNumber,
                ),
              ),
            );
          }
        }
        break;

      case 'user':
      case 'u':
        if (pathSegments.length >= 2) {
          final username = pathSegments[1];
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => UserProfilePage(username: username),
            ),
          );
        }
        break;

      default:
        // 未知路径，打开网页版
        final webUrl = '${AppConstants.baseUrl}/${pathSegments.join('/')}';
        WebViewPage.open(context, webUrl);
    }
  }

  /// 通过 slug 获取话题并打开
  Future<void> _handleTopicBySlug(BuildContext context, String slug) async {
    try {
      debugPrint('DeepLinkService: 通过 slug 获取话题: $slug');
      final service = DiscourseService();
      final detail = await service.getTopicDetailBySlug(slug);

      if (context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: detail.id,
              initialTitle: detail.title,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('DeepLinkService: 通过 slug 获取话题失败: $e');
      // 失败时使用 WebView 打开
      if (context.mounted) {
        WebViewPage.open(context, '${AppConstants.baseUrl}/t/$slug');
      }
    }
  }

  /// 释放资源
  void dispose() {
    _linkSubscription?.cancel();
    _linkSubscription = null;
    _navigatorContext = null;
    _initialized = false;
    _lastHandledUri = null;
    _lastHandledTime = null;
  }
}
