import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../pages/user_profile_page.dart';
import '../pages/webview_login_page.dart';
import '../pages/webview_page.dart';
import '../constants.dart';
import '../utils/discourse_url_parser.dart';
import 'discourse/discourse_service.dart';
import 'user_api_key_login_flow.dart';
import 'user_api_key_service.dart';

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

  /// 邮箱登录成功回调（用于 Onboarding 页面完成引导）
  VoidCallback? onEmailLoginSuccess;

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

  /// 处理外部或应用内链接，入口内会先校验可处理的 scheme 和 host
  void handleUri(Uri uri) {
    _handleLink(uri);
  }

  @visibleForTesting
  bool canHandleUri(Uri uri) => _canHandleUri(uri);

  /// 处理链接
  void _handleLink(Uri uri) {
    if (_navigatorContext == null) {
      debugPrint('DeepLinkService: 导航 context 未就绪');
      return;
    }

    final context = _navigatorContext!;
    final url = uri.toString();

    if (!_canHandleUri(uri)) {
      debugPrint('DeepLinkService: 未知链接类型 $url');
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

    debugPrint('DeepLinkService: 收到链接 $url');

    // 浏览器授权登录回调:discourse://auth_redirect?payload=...
    // (discourse:// 是站点 auth_redirect 默认白名单 scheme,App 已注册)
    if (UserApiKeyService().isAuthRedirect(uri)) {
      UserApiKeyLoginFlow.instance.handleCallback(uri);
      return;
    }

    // 自定义 scheme (fluxdo://...)
    if (uri.scheme == 'fluxdo') {
      _handleCustomScheme(context, uri);
      return;
    }

    // 尝试匹配用户链接 /u/username
    final userInfo = DiscourseUrlParser.parseUser(uri.path);
    if (userInfo != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UserProfilePage(username: userInfo.username),
        ),
      );
      return;
    }

    // 尝试匹配话题链接（带 ID）：/t/123、/t/123/5、/t/topic-slug/123 等
    final topicInfo = DiscourseUrlParser.parseTopic(uri.path);
    if (topicInfo != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TopicDetailPage(
            topicId: topicInfo.topicId,
            scrollToPostNumber: topicInfo.postNumber,
            autoSwitchToMasterDetail: true,
          ),
        ),
      );
      return;
    }

    // 尝试匹配话题链接（只有 slug）：/t/topic-slug
    final topicSlug = DiscourseUrlParser.parseTopicSlug(uri.path);
    if (topicSlug != null) {
      _handleTopicBySlug(context, topicSlug);
      return;
    }

    // 邮箱链接登录：/session/email-login/{token}
    if (uri.host == 'linux.do' &&
        uri.path.startsWith('/session/email-login/')) {
      _handleEmailLogin(context, url);
      return;
    }

    // 其他 linux.do 链接：使用内置浏览器
    if (uri.host == 'linux.do' || uri.host.endsWith('.linux.do')) {
      WebViewPage.open(context, url);
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
    final pathSegments = [
      if (uri.host.isNotEmpty) uri.host,
      ...uri.pathSegments,
    ];

    if (pathSegments.isEmpty) return;

    switch (pathSegments[0].toLowerCase()) {
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
                  autoSwitchToMasterDetail: true,
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

  /// 处理邮箱链接登录
  Future<void> _handleEmailLogin(BuildContext context, String url) async {
    debugPrint('DeepLinkService: 处理邮箱链接登录: $url');
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WebViewLoginPage(initialUrl: url)),
    );
    if (result == true) {
      onEmailLoginSuccess?.call();
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
              autoSwitchToMasterDetail: true,
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

  static bool _canHandleUri(Uri uri) {
    if (uri.scheme == 'fluxdo') return true;
    // 浏览器授权登录回调(仅 auth_redirect,不接管其他 discourse:// 链接)
    if (uri.scheme == 'discourse' && uri.host == 'auth_redirect') return true;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return _isLinuxDoHost(uri.host);
  }

  static bool _isLinuxDoHost(String host) {
    final normalizedHost = host.toLowerCase();
    return normalizedHost == 'linux.do' ||
        normalizedHost == 'www.linux.do' ||
        normalizedHost.endsWith('.linux.do');
  }
}
