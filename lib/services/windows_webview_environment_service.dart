import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 统一管理 Windows 平台的 WebView2 Environment。
///
/// 目标：
/// 1. 固定 userDataFolder，避免默认落在 exe 同级目录。
/// 2. 让 CookieManager / InAppWebView / HeadlessInAppWebView 使用同一环境。
/// 3. 支持通过 additionalBrowserArguments 设置代理。
///
/// WebView2 Environment 一旦创建，进程运行期间绝不销毁重建。插件原生层
/// 在仍有活跃 Controller 时 dispose Environment，可能永久堵死 Win32
/// 消息泵，表现为动画仍在播放但窗口无法点击、缩放或关闭。
class WindowsWebViewEnvironmentService {
  WindowsWebViewEnvironmentService._internal();

  static final WindowsWebViewEnvironmentService instance =
      WindowsWebViewEnvironmentService._internal();

  WebViewEnvironment? _environment;
  CookieManager? _cookieManager;
  Future<void>? _initializeFuture;
  String? _userDataFolder;
  String? _activeProxyUrl;
  String? _desiredProxyUrl;

  /// WebView2 Environment 的代理参数只能在创建时确定。运行中修改代理时，
  /// 由设置页持续提示用户重启，避免仅写日志后让用户误以为已经生效。
  final ValueNotifier<bool> proxyRestartRequiredNotifier = ValueNotifier(false);

  static const String _desiredProxyPrefKey =
      'windows_webview_desired_proxy_url';

  /// 本次启动的代理决策(NetworkSettingsService 起完本地代理后调用
  /// [setProxy] 时完成)。本地代理端口每次启动可能不同(上次的端口被
  /// TIME_WAIT / 残留会话占用时会随机漂移),Environment 一旦创建又不能
  /// 重建,拿着上次的旧端口创建会让整个会话的 WebView 全部断网。
  final Completer<void> _proxyDecision = Completer<void>();

  /// 代理决策的最长等待。超时兜底用上次持久化的期望值,避免代理启动
  /// 失败时卡死 Environment 创建。
  ///
  /// 8s 曾经不够用:本次调用排在 main.dart 启动链路里 rhttp 初始化
  /// 之后,而 rhttp 自己就留了最多 5s 超时预算,后面还有好几个服务
  /// 初始化——真机复现 8s 内等不到本次会话的真实代理端口,回退用了
  /// 上次持久化的旧端口(端口早已随 TIME_WAIT 漂移到别处),导致
  /// WebView2 在这次会话里全程连着一个不存在的代理，验证怎么也过不去。
  /// 放宽到 15s，盖过 rhttp 5s 预算 + 本地代理实际启动耗时的合理上限。
  static const _proxyDecisionTimeout = Duration(seconds: 15);

  bool get _isSupported => !kIsWeb && Platform.isWindows;

  WebViewEnvironment? get environment => _environment;

  String? get userDataFolder => _userDataFolder;
  String? get activeProxyUrl => _activeProxyUrl;
  String? get desiredProxyUrl => _desiredProxyUrl;
  bool get proxyRestartRequired => _activeProxyUrl != _desiredProxyUrl;
  int? get activeLocalProxyPort => parseLocalProxyPort(_activeProxyUrl);

  @visibleForTesting
  static int? parseLocalProxyPort(String? proxyUrl) {
    final uri = proxyUrl == null ? null : Uri.tryParse(proxyUrl);
    if (uri == null || uri.scheme != 'http' || !uri.hasPort) return null;
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
      return null;
    }
    return uri.port;
  }

  static bool shouldRetainLocalProxy({
    required bool clearApplied,
    required int? activeEnvironmentPort,
    required int? runningProxyPort,
  }) {
    return !clearApplied &&
        activeEnvironmentPort != null &&
        activeEnvironmentPort == runningProxyPort;
  }

  void _syncProxyRestartRequired() {
    final value = proxyRestartRequired;
    if (proxyRestartRequiredNotifier.value != value) {
      proxyRestartRequiredNotifier.value = value;
    }
  }

  CookieManager get cookieManager {
    if (_isSupported && _environment != null) {
      return _cookieManager ??= CookieManager.instance(
        webViewEnvironment: _environment,
      );
    }
    return CookieManager.instance();
  }

  Future<void> initialize() {
    if (!_isSupported || _environment != null) {
      return Future.value();
    }
    return _initializeFuture ??= _createEnvironment();
  }

  /// 登记期望代理。Environment 已创建时不在运行期重建，变更将在下次
  /// 启动时生效。返回 true 表示当前 Environment 已经使用该代理。
  Future<bool> setProxy(String? proxyUrl) async {
    if (!_isSupported) return true;
    _desiredProxyUrl = proxyUrl;
    final prefs = await SharedPreferences.getInstance();
    if (proxyUrl == null) {
      await prefs.remove(_desiredProxyPrefKey);
    } else {
      await prefs.setString(_desiredProxyPrefKey, proxyUrl);
    }

    // 放行等待中的 Environment 创建(见 _proxyDecision 注释)。
    if (!_proxyDecision.isCompleted) {
      _proxyDecision.complete();
    }

    // 尚未开始创建时，可以直接让首次 Environment 使用最新期望值。
    if (_environment == null && _initializeFuture == null) {
      await initialize();
    } else if (_initializeFuture != null) {
      // 创建可能正在等待本次决策,等它完成再判断是否已生效。
      await _initializeFuture;
    }
    final applied = _environment != null && _activeProxyUrl == proxyUrl;
    _syncProxyRestartRequired();
    if (!applied) {
      debugPrint(
        '[WebViewEnv] proxy change deferred until restart: '
        'active=${_activeProxyUrl ?? 'direct'}, '
        'desired=${proxyUrl ?? 'direct'}',
      );
    }
    return applied;
  }

  Future<void> _createEnvironment() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _desiredProxyUrl ??= prefs.getString(_desiredProxyPrefKey);

      // 上次会话在用本地代理 → 本次大概率也会起代理,但端口可能变化。
      // 等 setProxy 带来本次的实际地址再创建;超时则退回持久化的旧值。
      if (_desiredProxyUrl != null && !_proxyDecision.isCompleted) {
        try {
          await _proxyDecision.future.timeout(_proxyDecisionTimeout);
        } on TimeoutException {
          debugPrint(
            '[WebViewEnv] 等待代理决策超时，使用上次持久化的代理地址: '
            '$_desiredProxyUrl',
          );
        }
      }
      if (_userDataFolder == null) {
        final supportDirectory = await getApplicationSupportDirectory();
        _userDataFolder = path.join(supportDirectory.path, 'webview2');
        final userDataDirectory = Directory(_userDataFolder!);
        if (!await userDataDirectory.exists()) {
          await userDataDirectory.create(recursive: true);
        }
      }

      // 动态 SVG 等帖子内容会频繁创建/销毁 CompositionController。WebView2
      // 默认会为这些 data 页面保留大量独立 renderer，实机曾累计到 20+
      // 个存活进程并拖慢系统消息泵。限制的是 renderer 数量，不影响浏览器、
      // GPU、网络服务等基础子进程；6 个也足够登录/CF 与帖子内容并行。
      final browserArguments = <String>['--renderer-process-limit=6'];
      if (_desiredProxyUrl != null) {
        browserArguments.add('--proxy-server=$_desiredProxyUrl');
      }
      final additionalBrowserArguments = browserArguments.join(' ');

      _environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: _userDataFolder,
          additionalBrowserArguments: additionalBrowserArguments,
        ),
      );
      _activeProxyUrl = _desiredProxyUrl;
      _syncProxyRestartRequired();
      _cookieManager = CookieManager.instance(webViewEnvironment: _environment);

      debugPrint(
        '[WebViewEnv] Windows WebView2 environment initialized: '
        'userDataFolder=$_userDataFolder'
        '${_desiredProxyUrl != null ? ', proxy=$_activeProxyUrl' : ''}, '
        'rendererLimit=6',
      );
    } catch (e, stackTrace) {
      debugPrint('[WebViewEnv] Windows environment init failed: $e');
      debugPrintStack(
        label: '[WebViewEnv] initialize stack',
        stackTrace: stackTrace,
      );
      _environment = null;
      _cookieManager = null;
      _activeProxyUrl = null;
      _syncProxyRestartRequired();
      _initializeFuture = null;
    }
  }
}
