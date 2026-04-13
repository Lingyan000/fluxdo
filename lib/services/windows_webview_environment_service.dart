import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 统一管理 Windows 平台的 WebView2 Environment。
///
/// 目标：
/// 1. 固定 userDataFolder，避免默认落在 exe 同级目录。
/// 2. 让 CookieManager / InAppWebView / HeadlessInAppWebView 使用同一环境。
/// 3. 支持通过 additionalBrowserArguments 设置代理。
class WindowsWebViewEnvironmentService {
  WindowsWebViewEnvironmentService._internal();

  static final WindowsWebViewEnvironmentService instance =
      WindowsWebViewEnvironmentService._internal();

  WebViewEnvironment? _environment;
  CookieManager? _cookieManager;
  Future<void>? _initializeFuture;
  String? _userDataFolder;
  String? _currentProxyUrl;

  bool get _isSupported => !kIsWeb && Platform.isWindows;

  WebViewEnvironment? get environment => _environment;

  bool get isEnvironmentReady => _environment != null;

  String? get userDataFolder => _userDataFolder;

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

  /// 设置代理并重建 WebView2 环境。
  /// 传 null 清除代理。
  Future<void> setProxy(String? proxyUrl) async {
    if (!_isSupported) return;
    if (_currentProxyUrl == proxyUrl && _environment != null) return;

    _currentProxyUrl = proxyUrl;
    await _disposeEnvironment();
    _initializeFuture = _createEnvironment();
    await _initializeFuture;
  }

  Future<void> _disposeEnvironment() async {
    _cookieManager = null;
    if (_environment != null) {
      try {
        await _environment!.dispose();
      } catch (e) {
        debugPrint('[WebViewEnv] dispose failed: $e');
      }
      _environment = null;
      _initializeFuture = null;
    }
  }

  Future<void> _createEnvironment() async {
    try {
      if (_userDataFolder == null) {
        final supportDirectory = await getApplicationSupportDirectory();
        _userDataFolder = path.join(supportDirectory.path, 'webview2');
        final userDataDirectory = Directory(_userDataFolder!);
        if (!await userDataDirectory.exists()) {
          await userDataDirectory.create(recursive: true);
        }
      }

      final proxyArg = _currentProxyUrl != null
          ? '--proxy-server=$_currentProxyUrl'
          : null;

      _environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: _userDataFolder,
          additionalBrowserArguments: proxyArg,
        ),
      );
      _cookieManager = CookieManager.instance(webViewEnvironment: _environment);

      debugPrint(
        '[WebViewEnv] Windows WebView2 environment initialized: '
        'userDataFolder=$_userDataFolder'
        '${proxyArg != null ? ', proxy=$_currentProxyUrl' : ''}',
      );
    } catch (e, stackTrace) {
      debugPrint('[WebViewEnv] Windows environment init failed: $e');
      debugPrintStack(
        label: '[WebViewEnv] initialize stack',
        stackTrace: stackTrace,
      );
      _environment = null;
      _cookieManager = null;
      _initializeFuture = null;
    }
  }
}
