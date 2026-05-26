import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants.dart';
import 'network/cookie/boundary_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'local_notification_service.dart'; // 用于获取全局 navigatorKey
import 'cf_challenge_logger.dart';
import 'cf_clearance_refresh_service.dart';
import 'toast_service.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';
import '../l10n/s.dart';
import '../providers/preferences_provider.dart';
import '../utils/blur_config.dart';
import '../widgets/draggable_floating_pill.dart';

CookieManager get _cfCookieManager =>
    WindowsWebViewEnvironmentService.instance.cookieManager;

/// CF 验证服务
/// 处理 Cloudflare Turnstile 验证（仅手动模式）
class CfChallengeService {
  static final CfChallengeService _instance = CfChallengeService._internal();
  factory CfChallengeService() => _instance;
  CfChallengeService._internal();

  bool _isVerifying = false;

  /// CF 验证是否正在进行中（用于外部判断是否应忽略路由变化）
  bool get isVerifying => _isVerifying;

  final _verifyCompleter = <Completer<bool>>[];
  BuildContext? _context;
  static DateTime? _lastToastAt;
  Completer<BuildContext>? _contextReadyCompleter;
  VoidCallback? _activePromoteToForeground;
  bool _pendingPromoteToForeground = false;

  /// 冷却机制：连续失败 N 次后进入冷却期
  DateTime? _cooldownUntil;
  int _consecutiveFailures = 0;
  static const _cooldownDuration = Duration(seconds: 30);
  static const _maxFailuresBeforeCooldown = 3;
  static const _toastCooldown = Duration(seconds: 2);

  /// 检查是否在冷却期
  bool get isInCooldown {
    if (_cooldownUntil == null) return false;
    if (DateTime.now().isAfter(_cooldownUntil!)) {
      _cooldownUntil = null;
      return false;
    }
    return true;
  }

  /// 重置冷却期和失败计数（验证成功后调用）
  void resetCooldown() {
    _cooldownUntil = null;
    _consecutiveFailures = 0;
    CfChallengeLogger.logCooldown(entering: false);
  }

  /// 记录一次验证失败，连续达到上限后进入冷却期
  void startCooldown() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxFailuresBeforeCooldown) {
      _cooldownUntil = DateTime.now().add(_cooldownDuration);
      debugPrint(
        '[CfChallenge] 连续失败 $_consecutiveFailures 次，进入 ${_cooldownDuration.inSeconds}s 冷却期',
      );
      CfChallengeLogger.logCooldown(entering: true, until: _cooldownUntil);
    } else {
      debugPrint(
        '[CfChallenge] 验证失败 $_consecutiveFailures/$_maxFailuresBeforeCooldown，允许重试',
      );
    }
  }

  static void showGlobalMessage(String message, {bool isError = true}) {
    final now = DateTime.now();
    if (_lastToastAt != null &&
        now.difference(_lastToastAt!) < _toastCooldown) {
      return;
    }
    _lastToastAt = now;
    if (isError) {
      ToastService.showError(message);
    } else {
      ToastService.showInfo(message);
    }
  }

  void setContext(BuildContext context) {
    _context = context;
    if (context.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      if (!_contextReadyCompleter!.isCompleted) {
        _contextReadyCompleter!.complete(context);
      }
    }
  }

  /// 检测是否是 CF 验证页面（用于 403 响应体判断）
  static bool isCfChallenge(dynamic responseData) {
    if (responseData == null) return false;
    final str = responseData.toString();
    // cf_chl_opt 是 CF 验证页面的可靠标记（challenge options JS 变量）
    if (str.contains('cf_chl_opt')) return true;
    // challenge-platform 路径需配合 cloudflare 标记，避免误匹配
    if (str.contains('challenge-platform') && str.contains('cloudflare')) {
      return true;
    }
    // "Just a moment" 需配合 CF 特征，避免误匹配用户内容
    if (str.contains('Just a moment') &&
        (str.contains('cloudflare') || str.contains('cf-challenge'))) {
      return true;
    }
    return false;
  }

  /// 检测页面 HTML 中是否有活跃的 CF 验证盾
  /// 用于判断已加载的页面是否仍在展示验证挑战
  static bool hasActiveCfChallenge(String html) {
    return html.contains('cf-turnstile') ||
        html.contains('challenge-running') ||
        html.contains('challenge-stage') ||
        html.contains('cf_chl_opt');
  }

  /// 显示手动验证页面
  /// 返回值：true=验证成功, false=验证失败, null=冷却期内暂不可用或无 context
  /// [forceForeground] 是否强制前台显示（默认为 true）
  Future<bool?> showManualVerify([
    BuildContext? context,
    bool forceForeground = true,
  ]) async {
    // 检查冷却期
    if (isInCooldown) {
      debugPrint('[CfChallenge] In cooldown, skipping manual verify');
      CfChallengeLogger.log('[VERIFY] Skipped: in cooldown');
      return null;
    }

    final verifyUrl = '${AppConstants.baseUrl}/challenge';
    CfChallengeLogger.logVerifyStart(verifyUrl);
    unawaited(
      CfChallengeLogger.logAccessIps(url: verifyUrl, context: 'verify_start'),
    );

    // 尝试获取 context：传入的 > 已设置的 > 全局 navigatorKey
    BuildContext? ctx = context ?? _context;
    if (ctx == null || !ctx.mounted) {
      // 使用全局 navigatorKey 作为备用
      final navState = navigatorKey.currentState;
      if (navState != null && navState.context.mounted) {
        ctx = navState.context;
        debugPrint('[CfChallenge] Using global navigatorKey context');
      }
    }

    // 启动时可能还没有可用的 context，等到 context 可用后立即弹出
    if (ctx == null || !ctx.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      debugPrint('[CfChallenge] Waiting for context to be ready...');
      ctx = await _contextReadyCompleter!.future;
    }
    if (!ctx.mounted) {
      debugPrint('[CfChallenge] Context no longer mounted');
      return null;
    }

    // 如果已经在验证中 (Overlay 存在)
    if (_isVerifying) {
      if (forceForeground) {
        final promote = _activePromoteToForeground;
        if (promote == null) {
          _pendingPromoteToForeground = true;
        } else {
          promote();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _activePromoteToForeground?.call();
        });
      }

      final completer = Completer<bool>();
      _verifyCompleter.add(completer);
      return completer.future;
    }

    _isVerifying = true;

    // ignore: use_build_context_synchronously
    final overlayState =
        Overlay.maybeOf(ctx, rootOverlay: true) ??
        navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      debugPrint('[CfChallenge] No overlay available for manual verify');
      CfChallengeLogger.log('[VERIFY] No overlay available');
      _isVerifying = false;
      _pendingPromoteToForeground = false;
      return null;
    }

    // 停止自动续期服务，避免与手动验证冲突
    CfClearanceRefreshService().stop();

    // 备份旧 cf_clearance，验证失败时恢复（避免误删仍有效的值）
    final cookieJarService = CookieJarService();
    final backupCfClearance = await cookieJarService.getCfClearanceCookie();

    // Dio 请求已经 403，说明当前 cf_clearance 可能失效了。
    // 必须确保 WebView 中也没有旧的 cf_clearance，否则 CF 直接放行不显示盾。
    await cookieJarService.deleteCookie('cf_clearance');
    await cookieJarService.deleteWebViewCookie('cf_clearance');
    if (!overlayState.mounted) {
      debugPrint('[CfChallenge] Overlay no longer mounted');
      CfChallengeLogger.log('[VERIFY] Overlay not mounted');
      _isVerifying = false;
      _pendingPromoteToForeground = false;
      return null;
    }

    final resultCompleter = Completer<bool>();
    late final OverlayEntry entry;
    // 引用当前的拦截 Route，用于 cleanup
    ModalRoute? interceptorRoute;

    // Page Key 用于触发内部弹窗
    final pageKey = GlobalKey<_CfChallengePageState>();
    _activePromoteToForeground = () {
      pageKey.currentState?._promoteToForeground();
    };
    if (_pendingPromoteToForeground) {
      _pendingPromoteToForeground = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _activePromoteToForeground?.call();
      });
    }

    // 清理资源
    void cleanup() {
      if (entry.mounted) {
        entry.remove();
      }
      if (interceptorRoute?.isActive ?? false) {
        interceptorRoute?.navigator?.removeRoute(interceptorRoute!);
      }
      _activePromoteToForeground = null;
      _pendingPromoteToForeground = false;
      _isVerifying = false;
    }

    void finish(bool success) {
      if (!resultCompleter.isCompleted) {
        resultCompleter.complete(success);
      }
      cleanup();
    }

    // 创建 OverlayEntry
    // 我们需要传递一个 promoteCallback 给 Page，让 Page 能调用 Service 来 push route
    void onPromoteToForeground(BuildContext pageContext) {
      if (interceptorRoute != null && interceptorRoute!.isActive) {
        return; // 已经有 Route 了
      }

      // Push 透明 Route 用于拦截返回键
      interceptorRoute = PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (context, _, _) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) async {
              if (didPop) return;
              if (!_isVerifying) return;

              // 触发内部弹窗 via GlobalKey
              pageKey.currentState?.showExitConfirmation();
            },
            // 使用 IgnorePointer 让点击事件穿透到下层的 Overlay (WebView)
            child: const IgnorePointer(child: SizedBox.expand()),
          );
        },
      );

      Navigator.of(pageContext).push(interceptorRoute!).then((_) {
        // Route 被 pop
      });
    }

    entry = OverlayEntry(
      builder: (context) => CfChallengePage(
        key: pageKey,
        verifyUrl: verifyUrl,
        startInBackground: !forceForeground,
        onResult: finish,
        onPromoteRequest: () => onPromoteToForeground(context),
        oldCfClearanceValue: backupCfClearance != null
            ? CookieValueCodec.decode(backupCfClearance.value)
            : null,
      ),
    );
    overlayState.insert(entry);

    // 如果初始就是前台，立即执行 promote
    if (forceForeground) {
      // Post frame callback to ensure overlay is mounted and context is valid
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 注意：这里的 ctx 是 Service 传入的 ctx，可能不是 Overlay 的 context
        // 但 Navigator.of(ctx) 应该能找到正确的 Navigator
        // 我们最好使用 OverlayEntry builder 里的 context，但这里访问不到。
        // 使用 ctx 应该是安全的。
        onPromoteToForeground(ctx!);
      });
    }

    final result = await resultCompleter.future;

    // 通知所有等待者
    for (final c in _verifyCompleter) {
      if (!c.isCompleted) c.complete(result);
    }
    _verifyCompleter.clear();

    // 验证成功后重置冷却期
    if (result == true) {
      resetCooldown();
      CfChallengeLogger.logVerifyResult(
        success: true,
        reason: 'user completed',
      );
      // 手动验证成功后重新启动自动续期
      CfClearanceRefreshService().start();
    } else {
      // 验证失败，恢复备份的 cf_clearance（避免丢失可能仍有效的值）
      if (backupCfClearance != null) {
        await cookieJarService.restoreCfClearance(backupCfClearance);
        debugPrint('[CfChallenge] 验证失败，已恢复备份 cf_clearance');
      }
      // 验证失败，启动冷却期
      startCooldown();
      debugPrint(
        '[CfChallenge] Verification failed, cooldown until $_cooldownUntil',
      );
      CfChallengeLogger.logVerifyResult(
        success: false,
        reason: 'user cancelled or timeout',
      );
    }

    return result;
  }

  /// 用户主动触发的验证入口：允许绕过冷却期。
  Future<bool?> showManualVerifyNow([
    BuildContext? context,
    bool forceForeground = true,
  ]) {
    resetCooldown();
    return showManualVerify(context, forceForeground);
  }
}

/// CF 验证页面
class CfChallengePage extends StatefulWidget {
  const CfChallengePage({
    super.key,
    required this.verifyUrl,
    this.startInBackground = false,
    this.onResult,
    this.onPromoteRequest,
    this.oldCfClearanceValue,
  });

  final String verifyUrl;

  /// 先后台尝试验证，超时后再切到前台
  final bool startInBackground;
  final ValueChanged<bool>? onResult;
  final VoidCallback? onPromoteRequest;

  /// showManualVerify 在删除前备份的旧 cf_clearance 值（已解码）
  /// 用于可靠过滤 Windows 上 WebView 中未完全删除的残留旧值
  final String? oldCfClearanceValue;

  @override
  State<CfChallengePage> createState() => _CfChallengePageState();
}

class _CfChallengePageState extends State<CfChallengePage> {
  InAppWebViewController? _controller;
  final _webViewKey = GlobalKey();
  bool _isLoading = true;
  double _progress = 0;
  bool _hasMarkedPageReady = false;
  bool _hasPopped = false; // 防止重复 pop
  late bool _isBackground;
  late bool _needsManualAttention;
  bool _challengeWebViewVisible = false;
  bool _hideOriginFallbackPage = false;
  bool _checkingOriginFallback = false;
  bool _originFallbackNeedsAction = false;
  int _loadGeneration = 0;
  int _challengeRevealProbeGeneration = 0;
  bool _hasTimedOut = false;
  int _checkCount = 0;
  Timer? _timeoutTimer;
  Timer? _noChallengeCheckTimer;
  Timer? _loadStopFallbackTimer;
  Timer? _pageReadyFallbackTimer;
  static const _backgroundMaxCheckCount = 10;
  static const _foregroundMaxCheckCount = 60;
  static const _noChallengeCheckDelay = Duration(seconds: 5);
  static const _loadStopFallbackDelay = Duration(milliseconds: 1200);
  static const _pageReadyFallbackDelay = Duration(seconds: 4);

  /// 验证页面加载时 WebView 中的 cf_clearance 快照
  /// 用于区分「旧值残留」和「验证后新设的值」
  String? _initialCfClearance;

  int get _activeMaxCheckCount =>
      _isBackground ? _backgroundMaxCheckCount : _foregroundMaxCheckCount;

  @override
  void initState() {
    super.initState();
    _isBackground = widget.startInBackground;
    _needsManualAttention = false;
    _snapshotInitialClearance();
  }

  /// 记录验证开始时的旧 cf_clearance 值
  /// 优先使用 showManualVerify 传入的备份值（可靠），WebView 读取作为补充
  /// 解决 Windows 上 initState 时 controller 为 null 导致 _initialCfClearance
  /// 为 null，进而无法过滤残留旧值、误判为验证成功的问题
  Future<void> _snapshotInitialClearance() async {
    // 优先使用从 showManualVerify 传入的备份旧值（最可靠）
    if (widget.oldCfClearanceValue != null &&
        widget.oldCfClearanceValue!.isNotEmpty) {
      _initialCfClearance = widget.oldCfClearanceValue;
      debugPrint(
        '[CfChallenge] 使用备份的旧 cf_clearance 作为初始快照 '
        '(${_initialCfClearance!.length} chars)',
      );
      return;
    }

    // 兜底：从 WebView 读取（可能不可靠，但聊胜于无）
    try {
      final cookieValue = await _readCookieValue('cf_clearance');
      _initialCfClearance = cookieValue;
      if (_initialCfClearance != null && _initialCfClearance!.isNotEmpty) {
        debugPrint(
          '[CfChallenge] ⚠️ 验证页加载时 WebView 仍存在旧 cf_clearance '
          '(${_initialCfClearance!.length} chars)，将忽略该值',
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] 快照 cf_clearance 失败: $e');
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// 读取 cookie 值：先尝试 CookieManager，Windows 上 fallback 到 DevTools
  Future<String?> _readCookieValue(String name) async {
    try {
      final cookie = await _cfCookieManager.getCookie(
        url: WebUri(AppConstants.baseUrl),
        name: name,
      );
      if (cookie != null && cookie.value.isNotEmpty) {
        return cookie.value;
      }
    } catch (e) {
      debugPrint('[CfChallenge] CookieManager 读取 $name 失败: $e');
    }

    // Windows：通过当前页面 controller 读取实时 cookie，再回退到 CookieJar
    if (io.Platform.isWindows && _controller != null) {
      final liveValue = await CookieJarService().readCookieValueFromController(
        _controller!,
        name,
        currentUrl: widget.verifyUrl,
      );
      if (liveValue != null && liveValue.isNotEmpty) {
        return liveValue;
      }
      return CookieJarService().getCookieValue(name);
    }

    if (io.Platform.isWindows) {
      return CookieJarService().getCookieValue(name);
    }

    // Linux WPE: getCookie() 内部已调 getCookies(url) 做 URL 过滤，
    // 若 URL 匹配有问题，改用 getAllCookies() 绕过 URL 过滤
    if (io.Platform.isLinux) {
      try {
        final allCookies = await _cfCookieManager.getAllCookies();
        for (final c in allCookies) {
          if (c.name == name && c.value.isNotEmpty) {
            return c.value;
          }
        }
      } catch (e) {
        debugPrint(
          '[CfChallenge] Linux getAllCookies fallback 读取 $name 失败: $e',
        );
      }
    }

    return null;
  }

  /// 将关键 cookie 从 WebView 同步到 CookieJar
  Future<void> _syncLiveCookiesToCookieJar() async {
    await BoundarySyncService.instance.syncFromWebView(
      currentUrl: widget.verifyUrl,
      controller: _controller,
      cookieNames: const {'cf_clearance'},
    );
  }

  // ---------------------------------------------------------------------------
  // JS 注入：拦截 XHR/fetch 对 cdn-cgi/challenge-platform 的响应
  // 当 challenge-platform 请求完成时，通过 JS Handler 通知 Flutter 侧
  // Flutter 侧用 CookieManager（可读 HttpOnly cookie）检查 cf_clearance
  // ---------------------------------------------------------------------------

  /// 注入 XHR/fetch 拦截脚本
  Future<void> _injectChallengeInterceptor(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source: '''
(function() {
  if (window._cfInterceptorInstalled) return;
  window._cfInterceptorInstalled = true;

  var CP = 'cdn-cgi/challenge-platform';

  // 拦截 XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this._cfUrl = url;
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function() {
    var self = this;
    if (self._cfUrl && self._cfUrl.indexOf(CP) !== -1) {
      self.addEventListener('load', function() {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', self._cfUrl, self.status);
        } catch(e) {}
      });
    }
    return origSend.apply(this, arguments);
  };

  // 拦截 fetch
  var origFetch = window.fetch;
  window.fetch = function(input, init) {
    var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
    return origFetch.apply(this, arguments).then(function(resp) {
      if (url.indexOf(CP) !== -1) {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', url, resp.status);
        } catch(e) {}
      }
      return resp;
    });
  };
})();
''',
    );
  }

  /// challenge-platform 响应到达时的回调
  Future<void> _onChallengeComplete(List<dynamic> args) async {
    if (_hasPopped) return;
    final url = args.isNotEmpty ? args[0] : '';
    final status = args.length > 1 ? args[1] : 0;
    debugPrint('[CfChallenge] challenge-platform 响应: url=$url, status=$status');
    CfChallengeLogger.log(
      '[VERIFY] Challenge response: url=$url, status=$status',
    );
    _revealChallengeWebView();

    try {
      final cookieValue = await _readCookieValue('cf_clearance');

      if (cookieValue == null || cookieValue.isEmpty) {
        debugPrint('[CfChallenge] 未检测到 cf_clearance，等待后续响应');
        return;
      }

      // 关键：对比初始快照，过滤掉未被清除干净的旧值
      if (!_isFreshClearance(cookieValue)) {
        debugPrint('[CfChallenge] cf_clearance 与初始值相同（旧值残留），忽略');
        return;
      }

      // cf_clearance 是新值，但需要确认页面已真正通过验证
      // challenge-platform 在验证过程中有多次请求（脚本加载、初始化、提交等），
      // 只有最终完成时页面才不再包含验证标记
      final html = await _controller?.evaluateJavascript(
        source: 'document.body ? document.body.innerHTML : ""',
      );
      if (html != null && CfChallengeService.hasActiveCfChallenge(html)) {
        debugPrint('[CfChallenge] 检测到新 cf_clearance 但页面仍在验证中，继续等待');
        return;
      }

      debugPrint(
        '[CfChallenge] ✓ 验证完成：新 cf_clearance (${cookieValue.length} chars) 且页面已通过',
      );
      CfChallengeLogger.logVerifyResult(
        success: true,
        reason: 'new cf_clearance detected and page passed challenge',
      );
      await _syncLiveCookiesToCookieJar();
      // 验证 cf_clearance 是否真正写入了 CookieJar
      final synced = await CookieJarService().getCfClearance();
      if (synced != null && synced.isNotEmpty) {
        debugPrint(
          '[CfChallenge] cf_clearance 已同步到 CookieJar (${synced.length} chars)',
        );
      } else {
        debugPrint(
          '[CfChallenge] ⚠️ syncFromWebView 后 CookieJar 中未找到 cf_clearance',
        );
      }
      _timeoutTimer?.cancel();
      if (mounted) _finish(true);
    } catch (e) {
      debugPrint('[CfChallenge] cookie 检查异常: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 超时计时器（兜底机制）
  // ---------------------------------------------------------------------------

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _checkCount = 0;
    _hasTimedOut = false;
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _checkCount++;
      if (!_isBackground && !_hasTimedOut) setState(() {}); // 更新计数显示

      // 兜底轮询：验证通过后页面重定向会销毁 JS 上下文，
      // 导致 onChallengeComplete 回调丢失（macOS 上尤为明显），
      // 每秒主动检查 cf_clearance 变化来弥补
      _pollCfClearance();

      if (_checkCount > _activeMaxCheckCount) {
        if (_isBackground) {
          CfChallengeLogger.log(
            '[VERIFY] Background timeout after $_activeMaxCheckCount seconds, prompting manual verify',
          );
          _promoteToForeground(dueToTimeout: true);
          return;
        }
        if (!_hasTimedOut) {
          CfChallengeLogger.logVerifyResult(
            success: false,
            reason: 'timeout after $_activeMaxCheckCount seconds',
          );
          if (mounted) {
            setState(() {
              _hasTimedOut = true;
              _needsManualAttention = true;
            });
            _showInfo(S.current.cf_verifyTimeout);
          }
        }
        return;
      }
    });
  }

  /// 延迟检测页面是否存在 CF 验证盾
  /// 如果页面加载完成后没有盾，快速退出避免死等超时导致循环
  void _scheduleNoChallengeCheck(InAppWebViewController controller) {
    _noChallengeCheckTimer?.cancel();
    final generation = _loadGeneration;
    _noChallengeCheckTimer = Timer(_noChallengeCheckDelay, () async {
      if (_hasPopped || !mounted || generation != _loadGeneration) return;

      try {
        final hasChallenge = await _hasVisibleChallenge(controller);
        if (_hasPopped || generation != _loadGeneration) return;
        if (hasChallenge) {
          _revealChallengeWebView();
          return; // 页面有盾，等待正常验证流程
        }

        // 页面没有盾，检查是否已有新的 cf_clearance（CF 可能自动放行了）
        final cookieValue = await _readCookieValue('cf_clearance');
        if (_hasPopped || generation != _loadGeneration) return;

        if (_isFreshClearance(cookieValue)) {
          debugPrint('[CfChallenge] 页面无盾但检测到新 cf_clearance，自动完成');
          CfChallengeLogger.logVerifyResult(
            success: true,
            reason: 'no challenge but new cf_clearance detected',
          );
          await _syncLiveCookiesToCookieJar();
          _timeoutTimer?.cancel();
          if (mounted) _finish(true);
        } else {
          // 没有盾也没有新 cookie，非 CF 验证场景，不露出源站 404。
          debugPrint('[CfChallenge] 页面无盾且无新 cf_clearance，快速退出');
          CfChallengeLogger.logVerifyResult(
            success: false,
            reason:
                'no challenge detected after ${_noChallengeCheckDelay.inSeconds}s',
          );
          _timeoutTimer?.cancel();
          if (_isBackground) {
            if (mounted) _finish(false);
          } else if (mounted) {
            setState(() {
              _challengeWebViewVisible = false;
              _hideOriginFallbackPage = true;
              _originFallbackNeedsAction = true;
              _needsManualAttention = false;
              _isLoading = false;
            });
          }
        }
      } catch (e) {
        debugPrint('[CfChallenge] 检测 challenge 状态异常: $e');
      }
    });
  }

  Future<void> _handleVerifyOriginFallback(int generation) async {
    if (_hasPopped || _checkingOriginFallback) return;

    _checkingOriginFallback = true;
    if (mounted) {
      setState(() {
        _challengeWebViewVisible = false;
        _hideOriginFallbackPage = true;
        _originFallbackNeedsAction = false;
        _isLoading = false;
      });
    }

    try {
      for (var i = 0; i < 6; i++) {
        if (_hasPopped || generation != _loadGeneration) return;
        final cookieValue = await _readCookieValue('cf_clearance');
        if (_isFreshClearance(cookieValue)) {
          debugPrint('[CfChallenge] /challenge 返回 404，但检测到新 cf_clearance，自动完成');
          CfChallengeLogger.logVerifyResult(
            success: true,
            reason: 'origin /challenge 404 after fresh cf_clearance',
          );
          await _syncLiveCookiesToCookieJar();
          _timeoutTimer?.cancel();
          if (mounted) _finish(true);
          return;
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }

      debugPrint('[CfChallenge] /challenge 返回 404，且未检测到新 cf_clearance');
      CfChallengeLogger.logVerifyResult(
        success: false,
        reason: 'origin /challenge 404 without fresh cf_clearance',
      );
      if (_isBackground) {
        _timeoutTimer?.cancel();
        if (mounted) _finish(false);
        return;
      }
      if (mounted && !_hasPopped) {
        setState(() {
          _originFallbackNeedsAction = true;
          _needsManualAttention = false;
        });
      }
    } catch (e) {
      debugPrint('[CfChallenge] 处理 /challenge 404 fallback 异常: $e');
    } finally {
      _checkingOriginFallback = false;
      if (mounted && !_hasPopped && generation == _loadGeneration) {
        setState(() {});
      }
    }
  }

  /// 轮询检测 cf_clearance 变化（兜底 JS 回调被重定向吞掉的场景）
  bool _polling = false;
  Future<void> _pollCfClearance() async {
    if (_hasPopped || _polling) return;
    _polling = true;
    try {
      final cookieValue = await _readCookieValue('cf_clearance');
      if (_hasPopped) return;
      if (!_isFreshClearance(cookieValue)) return;

      debugPrint(
        '[CfChallenge] ✓ 轮询检测到新 cf_clearance (${cookieValue!.length} chars)',
      );
      CfChallengeLogger.logVerifyResult(
        success: true,
        reason: 'polling detected new cf_clearance',
      );
      await _syncLiveCookiesToCookieJar();
      _timeoutTimer?.cancel();
      if (mounted) _finish(true);
    } catch (e) {
      debugPrint('[CfChallenge] 轮询检查异常: $e');
    } finally {
      _polling = false;
    }
  }

  // ---------------------------------------------------------------------------
  // UI 操作
  // ---------------------------------------------------------------------------

  bool _showExitDialog = false;
  bool _showHelpDialog = false;

  Future<void> showExitConfirmation() async {
    if (!mounted) return;
    setState(() {
      _showExitDialog = true;
    });
  }

  void _dismissExitConfirmation() {
    if (!mounted) return;
    setState(() {
      _showExitDialog = false;
    });
  }

  void _confirmExit() {
    if (!mounted) return;
    _finish(false);
  }

  void _refresh() {
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _challengeRevealProbeGeneration++;
    _hasMarkedPageReady = false;
    _checkCount = 0;
    _hasTimedOut = false;
    _needsManualAttention = true;
    _challengeWebViewVisible = false;
    _hideOriginFallbackPage = false;
    _checkingOriginFallback = false;
    _originFallbackNeedsAction = false;
    setState(() {
      _isLoading = true;
      _progress = 0;
    });
    _controller?.reload();
  }

  void _promoteToForeground({bool dueToTimeout = false}) {
    if (!_isBackground) return;
    setState(() {
      _isBackground = false;
      _needsManualAttention = true;
      _hasTimedOut = false;
      _checkCount = 0;
    });
    widget.onPromoteRequest?.call();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showInfo(
        dueToTimeout
            ? S.current.cf_autoVerifyTimeout
            : S.current.cf_manualVerifyBannerMessage,
      );
    });
  }

  void _finish(bool success) {
    if (_hasPopped) return;
    _hasPopped = true;
    _timeoutTimer?.cancel();
    final handler = widget.onResult;
    if (handler != null) {
      handler(success);
    } else {
      Navigator.of(context).pop(success);
    }
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ToastService.showInfo(message);
  }

  void _showHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = true;
    });
  }

  void _dismissHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = false;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ToastService.showError(message);
  }

  bool get _shouldCoverWebView =>
      !_challengeWebViewVisible || _hideOriginFallbackPage;

  bool _isFreshClearance(String? cookieValue) {
    if (cookieValue == null || cookieValue.isEmpty) return false;
    if (_initialCfClearance != null &&
        _initialCfClearance!.isNotEmpty &&
        cookieValue == _initialCfClearance) {
      return false;
    }
    return true;
  }

  bool _isVerifyUrl(WebUri? url) {
    if (url == null) return false;
    final actual = Uri.tryParse(url.toString());
    final expected = Uri.tryParse(widget.verifyUrl);
    if (actual == null || expected == null) return false;
    return actual.scheme == expected.scheme &&
        actual.host == expected.host &&
        actual.path == expected.path;
  }

  bool _isVerifyOriginFallback(
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    if (response.statusCode != 404) return false;
    if (request.isForMainFrame != true) return false;
    return _isVerifyUrl(request.url);
  }

  Future<bool> _hasVisibleChallenge(InAppWebViewController controller) async {
    final html = await controller.evaluateJavascript(
      source:
          'document.documentElement ? document.documentElement.innerHTML : ""',
    );
    if (html == null) return false;
    return CfChallengeService.hasActiveCfChallenge(html.toString());
  }

  void _revealChallengeWebView() {
    if (_hasPopped || !mounted || _challengeWebViewVisible) return;
    setState(() {
      _challengeWebViewVisible = true;
      _hideOriginFallbackPage = false;
      _originFallbackNeedsAction = false;
    });
  }

  void _startChallengeRevealProbe(
    InAppWebViewController controller,
    int generation,
  ) {
    final probeGeneration = ++_challengeRevealProbeGeneration;
    unawaited(() async {
      for (var i = 0; i < 20; i++) {
        if (_hasPopped ||
            !mounted ||
            generation != _loadGeneration ||
            probeGeneration != _challengeRevealProbeGeneration) {
          return;
        }

        try {
          if (await _hasVisibleChallenge(controller)) {
            _revealChallengeWebView();
            return;
          }
        } catch (e) {
          debugPrint('[CfChallenge] 检测验证页可见状态异常: $e');
        }

        await Future.delayed(const Duration(milliseconds: 250));
      }
    }());
  }

  bool get _shouldShowStatusBanner =>
      _hasTimedOut ||
      _needsManualAttention ||
      (_checkCount > _activeMaxCheckCount - 10 &&
          _checkCount <= _activeMaxCheckCount);

  Widget _buildStatusBanner(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    late final Color backgroundColor;
    late final Color foregroundColor;
    late final IconData icon;
    late final String title;
    late final String message;

    if (_hasTimedOut) {
      backgroundColor = colorScheme.errorContainer;
      foregroundColor = colorScheme.onErrorContainer;
      icon = Icons.error_outline;
      title = context.l10n.cf_verifyTimedOutTitle;
      message = context.l10n.cf_verifyTimedOutMessage;
    } else if (_needsManualAttention) {
      backgroundColor = colorScheme.secondaryContainer;
      foregroundColor = colorScheme.onSecondaryContainer;
      icon = Icons.touch_app_outlined;
      title = context.l10n.cf_manualVerifyBannerTitle;
      message = context.l10n.cf_manualVerifyBannerMessage;
    } else {
      backgroundColor = colorScheme.tertiaryContainer;
      foregroundColor = colorScheme.onTertiaryContainer;
      icon = Icons.hourglass_bottom;
      title = context.l10n.cf_manualVerifyBannerTitle;
      message = context.l10n.cf_verifyLonger(
        _activeMaxCheckCount - _checkCount,
      );
    }

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: foregroundColor, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: foregroundColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foregroundColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_hasTimedOut) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    onPressed: _refresh,
                    child: Text(context.l10n.cf_retryVerify),
                  ),
                  TextButton(
                    onPressed: _confirmExit,
                    child: Text(context.l10n.common_exit),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOriginFallbackOverlay(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final isAction = _originFallbackNeedsAction;
    final isCompleting = _checkingOriginFallback;
    final title = isAction
        ? context.l10n.cf_noChallengeTitle
        : isCompleting
        ? context.l10n.cf_verifyCompletingTitle
        : context.l10n.cf_verifyOpeningTitle;
    final message = isAction
        ? context.l10n.cf_noChallengeMessage
        : isCompleting
        ? context.l10n.cf_verifyCompletingMessage
        : context.l10n.cf_verifyOpeningMessage;

    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isAction)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.6),
                  )
                else
                  Icon(
                    Icons.verified_user_outlined,
                    size: 32,
                    color: colorScheme.primary,
                  ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isAction) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(context.l10n.cf_retryVerificationAction),
                      ),
                      TextButton(
                        onPressed: _confirmExit,
                        child: Text(context.l10n.common_exit),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handlePageReady(InAppWebViewController controller, {String? reason}) {
    if (_hasMarkedPageReady || _hasPopped) return;
    _hasMarkedPageReady = true;
    final generation = _loadGeneration;
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();

    if (mounted && _isLoading) {
      setState(() => _isLoading = false);
    }

    if (reason != null) {
      debugPrint('[CfChallenge] 页面进入可验证状态: $reason');
    }

    _injectChallengeInterceptor(controller);
    _startTimeout();
    _startChallengeRevealProbe(controller, generation);
    _scheduleNoChallengeCheck(controller);
  }

  void _schedulePageReadyFallback(InAppWebViewController controller) {
    if ((!io.Platform.isWindows && !io.Platform.isLinux) ||
        _hasMarkedPageReady) {
      return;
    }
    _pageReadyFallbackTimer?.cancel();
    _pageReadyFallbackTimer = Timer(_pageReadyFallbackDelay, () {
      _pageReadyFallbackTimer = null;
      if (_hasMarkedPageReady || _hasPopped) {
        return;
      }
      _handlePageReady(controller, reason: 'timed fallback');
    });
  }

  void _scheduleLoadStopFallback(
    InAppWebViewController controller,
    int progress,
  ) {
    if ((!io.Platform.isWindows && !io.Platform.isLinux) ||
        _hasMarkedPageReady ||
        progress < 95) {
      return;
    }
    _loadStopFallbackTimer ??= Timer(_loadStopFallbackDelay, () {
      _loadStopFallbackTimer = null;
      if (_hasMarkedPageReady || _hasPopped || _progress < 0.95) {
        return;
      }
      _handlePageReady(controller, reason: 'progress fallback');
    });
  }

  Widget _buildChallengeWebView({required bool showUi}) {
    return IgnorePointer(
      ignoring: _isBackground,
      child: WebViewSettings.wrapWithScrollFix(
        InAppWebView(
          key: _webViewKey,
          webViewEnvironment:
              WindowsWebViewEnvironmentService.instance.environment,
          initialUrlRequest: URLRequest(url: WebUri(widget.verifyUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            userAgent: AppConstants.webViewUserAgentOverride,
            mediaPlaybackRequiresUserGesture: false,
          ),
          onReceivedServerTrustAuthRequest: (_, challenge) =>
              WebViewSettings.handleServerTrustAuthRequest(challenge),
          onWebViewCreated: (controller) {
            _controller = controller;
            // 注册 JS Handler，challenge-platform 响应到达时触发
            controller.addJavaScriptHandler(
              handlerName: 'onChallengeComplete',
              callback: _onChallengeComplete,
            );
          },
          onLoadStart: (controller, url) {
            _loadGeneration++;
            _challengeRevealProbeGeneration++;
            _loadStopFallbackTimer?.cancel();
            _pageReadyFallbackTimer?.cancel();
            _hasMarkedPageReady = false;
            _hasTimedOut = false;
            _needsManualAttention = false;
            _challengeWebViewVisible = false;
            _hideOriginFallbackPage = false;
            _checkingOriginFallback = false;
            _originFallbackNeedsAction = false;
            _schedulePageReadyFallback(controller);
            setState(() {
              _isLoading = true;
              _progress = 0;
            });
          },
          onPageCommitVisible: (controller, url) {
            _handlePageReady(controller, reason: 'onPageCommitVisible');
          },
          onProgressChanged: (controller, progress) {
            _progress = progress / 100;
            _scheduleLoadStopFallback(controller, progress);
            if (showUi) {
              setState(() {});
            }
          },
          onLoadStop: (controller, url) {
            WebViewSettings.injectScrollFix(controller);
            _handlePageReady(controller, reason: 'onLoadStop');
          },
          onReceivedError: (controller, request, error) {
            _pageReadyFallbackTimer?.cancel();
            if (mounted) {
              setState(() => _isLoading = false);
            }
            if (showUi) {
              _showError(context.l10n.cf_loadFailed(error.description));
            }
          },
          onReceivedHttpError: (controller, request, errorResponse) {
            if (_isVerifyOriginFallback(request, errorResponse)) {
              unawaited(_handleVerifyOriginFallback(_loadGeneration));
            }
          },
        ),
        getController: () => _controller,
      ),
    );
  }

  Widget _buildPanelHeader(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: context.l10n.common_exit,
              onPressed: showExitConfirmation,
            ),
            Expanded(
              child: Text(
                context.l10n.cf_securityVerifyTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: context.l10n.common_refresh,
              onPressed: _refresh,
            ),
            IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: context.l10n.common_help,
              onPressed: _showHelp,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerifyPanel(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.surface,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildPanelHeader(theme),
          SizedBox(
            height: 2,
            child: _isLoading
                ? LinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  )
                : ColoredBox(color: colorScheme.outlineVariant),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Offstage(
                    offstage: _shouldCoverWebView,
                    child: _buildChallengeWebView(showUi: true),
                  ),
                ),
                if (_shouldCoverWebView)
                  Positioned.fill(child: _buildOriginFallbackOverlay(theme))
                else if (_shouldShowStatusBanner)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: _buildStatusBanner(theme),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextualBarrier(ThemeData theme, bool dialogBlur) {
    final barrierColor = dialogBlur
        ? blurBarrierColor(theme.brightness)
        : Colors.black.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.42 : 0.24,
          );
    final barrier = ModalBarrier(dismissible: false, color: barrierColor);

    if (!dialogBlur) return barrier;

    return BackdropFilter(filter: createBlurFilter(blurSigma), child: barrier);
  }

  Widget _buildContextualVerifyLayer(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return Consumer(
      builder: (context, ref, _) {
        final dialogBlur = ref.watch(
          preferencesProvider.select((prefs) => prefs.dialogBlur),
        );

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildContextualBarrier(theme, dialogBlur),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 640;
                    final horizontalMargin = isCompact ? 12.0 : 24.0;
                    final verticalMargin = isCompact ? 12.0 : 24.0;
                    final availableHeight = math.max(
                      360.0,
                      constraints.maxHeight - verticalMargin * 2,
                    );
                    final targetHeight = isCompact
                        ? availableHeight * 0.88
                        : math.min(720.0, availableHeight);
                    final minHeight = math.min(460.0, availableHeight);
                    final panelHeight = math.max(minHeight, targetHeight);

                    return Align(
                      alignment: isCompact
                          ? Alignment.bottomCenter
                          : Alignment.center,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalMargin,
                          verticalMargin,
                          horizontalMargin,
                          verticalMargin,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: SizedBox(
                            width: double.infinity,
                            height: panelHeight,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.16),
                                    blurRadius: 24,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                                border: Border.all(
                                  color: colorScheme.outlineVariant.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                              child: _buildVerifyPanel(theme),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showUi = !_isBackground;

    return Stack(
      children: [
        if (showUi)
          Positioned.fill(child: _buildContextualVerifyLayer(theme))
        else
          Positioned.fill(
            child: Offstage(
              offstage: true,
              child: _buildChallengeWebView(showUi: false),
            ),
          ),

        // 内部弹窗层
        if (_showExitDialog)
          Stack(
            children: [
              GestureDetector(
                onTap: _dismissExitConfirmation,
                child: Container(
                  color: Colors.black54,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              Center(
                child: AlertDialog(
                  title: Text(context.l10n.cf_abandonVerifyTitle),
                  content: Text(context.l10n.cf_abandonVerifyMessage),
                  actions: [
                    TextButton(
                      onPressed: _dismissExitConfirmation,
                      child: Text(context.l10n.cf_continueVerify),
                    ),
                    TextButton(
                      onPressed: _confirmExit,
                      child: Text(
                        context.l10n.common_exit,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

        if (_showHelpDialog)
          Stack(
            children: [
              GestureDetector(
                onTap: _dismissHelp,
                child: Container(
                  color: Colors.black54,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              Center(
                child: AlertDialog(
                  title: Text(context.l10n.cf_helpTitle),
                  content: Text(context.l10n.cf_helpContent),
                  actions: [
                    TextButton(
                      onPressed: _dismissHelp,
                      child: Text(context.l10n.common_gotIt),
                    ),
                  ],
                ),
              ),
            ],
          ),

        // 悬浮验证胶囊
        if (_isBackground)
          DraggableFloatingPill(
            initialTop: 100,
            initiallyExpanded: true,
            tapToExpand: false,
            onTap: _promoteToForeground,
            child: Text(S.current.cf_backgroundVerifying),
          ),
      ],
    );
  }
}
