import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
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

  /// CF 验证状态变化通知（true=进行中, false=空闲）。
  /// 拦截器 / ScreenTrack 等订阅它来在 CF 期间冻结业务流量与数据采集。
  final ValueNotifier<bool> inProgressNotifier = ValueNotifier<bool>(false);

  /// CF 挑战被成功解决、新 cf_clearance 已落 CookieJar 的时刻广播。
  /// [BrowserTrustCoordinator] 订阅它:WebView session bootstrap 因 CF 失败后,
  /// 等待 Dio 侧(或主动发起的)验证完成,再 force 重跑 bootstrap,避免两条线各自为政。
  final ValueNotifier<DateTime?> clearanceResolvedAt = ValueNotifier<DateTime?>(
    null,
  );

  void _setVerifying(bool value) {
    if (_isVerifying == value) return;
    _isVerifying = value;
    inProgressNotifier.value = value;
  }

  /// 是否在拦截到 CF 盾时自动弹出验证 UI（默认 true）
  /// 关闭后 [CfChallengeInterceptor] 命中 CF 盾时会静默 reject，
  /// 交给 ErrorView 提供"手动验证"入口。由 PreferencesNotifier 同步维护。
  bool autoVerifyEnabled = true;

  final _verifyCompleter = <Completer<bool>>[];
  BuildContext? _context;
  static DateTime? _lastToastAt;
  Future<bool>? _activeSessionCompatPrompt;
  bool _sessionCompatPromptDeclined = false;
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

  /// 原生链路在完成验证后仍被 CF 拒绝时，询问用户是否仅在本次会话
  /// 使用浏览器网络栈。并发失败请求共享同一个弹窗结果。
  Future<bool> confirmSessionCompatibilityMode() {
    if (_sessionCompatPromptDeclined) return Future.value(false);
    final active = _activeSessionCompatPrompt;
    if (active != null) return active;

    late final Future<bool> future;
    future = _confirmSessionCompatibilityModeInternal().whenComplete(() {
      if (identical(_activeSessionCompatPrompt, future)) {
        _activeSessionCompatPrompt = null;
      }
    });
    _activeSessionCompatPrompt = future;
    return future;
  }

  Future<bool> _confirmSessionCompatibilityModeInternal() async {
    BuildContext? context = _context;
    if (context == null || !context.mounted) {
      context = navigatorKey.currentContext;
    }
    if (context == null || !context.mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(S.current.cf_sessionCompatTitle),
        content: Text(S.current.cf_sessionCompatMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(S.current.cf_sessionCompatEnable),
          ),
        ],
      ),
    );
    final confirmed = result == true;
    if (!confirmed) {
      // 用户本次会话已经明确拒绝，不在后续 CF 失败时反复打扰。
      _sessionCompatPromptDeclined = true;
    }
    return confirmed;
  }

  void resetSessionCompatibilityDecision() {
    _sessionCompatPromptDeclined = false;
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

  /// 综合响应头 + 响应体判断 dio Response 是否是 CF 验证响应。
  ///
  /// CF 根据请求的 Accept header 决定 challenge 响应格式:
  /// - 浏览器请求 (Accept: text/html) → 返 text/html "Just a moment..." 页面
  /// - API 请求 (Accept: application/json, text/plain) → 返 text/plain 简短挑战
  /// 但**两者都带 `cf-mitigated: challenge` header**, 这是 CF 官方权威信号。
  ///
  /// 状态码可能是 403 也可能是 429:
  /// - 普通 CF 盾(WAF / bot fight 等)→ 403 + cf-mitigated: challenge
  /// - 速率限制规则 action 配 managed_challenge / js_challenge / challenge → 429 + cf-mitigated: challenge
  /// 两种情况都应该交由 CfChallengeInterceptor 走验证流程,不能当成普通 403/429 处理。
  ///
  /// 历史上这里曾把 content-type 必须 text/html 作为前置条件,导致 dio 这种
  /// 默认 `Accept: application/json, text/plain, */*` 的客户端拿到 text/plain
  /// 时被漏掉, CfChallengeInterceptor 不弹手动验证。
  static bool isCfChallengeResponse(Response? response) {
    if (response == null) return false;
    final headers = response.headers;

    // 1. 必须来自 Cloudflare
    final server = headers.value('server') ?? '';
    if (!server.toLowerCase().contains('cloudflare')) return false;

    // 2. cf-mitigated: challenge — CF 官方权威信号, 不依赖 content-type
    final cfMitigated = headers.value('cf-mitigated') ?? '';
    if (cfMitigated.contains('challenge')) return true;

    // 3. fallback: 老版本 CF 或某些路径不带 cf-mitigated, 用 body 兜底,
    //    但 body 兜底只对 text/html 走 — 避免误判 Discourse 自己的 plaintext 403。
    final contentType = headers.value('content-type') ?? '';
    if (!contentType.contains('text/html')) return false;

    return isCfChallenge(response.data);
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

  /// 检测页面 HTML 是否是源站返回的 404 / 非挑战内容
  /// 用于在 onReceivedHttpError 不可靠的平台上识别 Discourse 404 等非挑战页面
  static bool isOriginNotFound(String html) {
    if (html.isEmpty) return false;
    final lower = html.toLowerCase();
    // 仅保留稳定的 Discourse 自身特征，避免论坛名含 "404" 等场景误判
    return lower.contains('page-not-found') ||
        lower.contains('discourse-no-results') ||
        lower.contains('"errortype":"notfound"') ||
        lower.contains('404-body') ||
        lower.contains('exist or is private') ||
        lower.contains('page you requested');
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

    _setVerifying(true);

    // ignore: use_build_context_synchronously
    final overlayState =
        Overlay.maybeOf(ctx, rootOverlay: true) ??
        navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      debugPrint('[CfChallenge] No overlay available for manual verify');
      CfChallengeLogger.log('[VERIFY] No overlay available');
      _setVerifying(false);
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
      _setVerifying(false);
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
      _setVerifying(false);
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
      // 广播:一次 CF 挑战被成功解决,新 cf_clearance 已落 jar。
      clearanceResolvedAt.value = DateTime.now();
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
  bool _hasSeenChallenge = false;
  bool _hideOriginFallbackPage = false;
  bool _checkingOriginFallback = false;
  bool _originFallbackNeedsAction = false;
  bool _finishingFromVerifyResponse = false;
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
  static const _noChallengeCheckDelay = Duration(milliseconds: 1200);
  static const _revealStateWatchInterval = Duration(milliseconds: 150);
  static const _loadStopFallbackDelay = Duration(milliseconds: 1200);
  static const _pageReadyFallbackDelay = Duration(seconds: 4);
  static const _completionProbeTimeout = Duration(seconds: 8);
  static const _noChallengeProbeTimeout = Duration(milliseconds: 1800);

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
  ///
  /// [freshClearance] challenge 确认的 fresh cf_clearance 值；传入后只接受该值
  /// 写入 jar（排除 WebView 残留旧变体），并以 trusted 升 version 盖过旧值。
  Future<void> _syncLiveCookiesToCookieJar({String? freshClearance}) async {
    await BoundarySyncService.instance.syncFromWebView(
      currentUrl: widget.verifyUrl,
      controller: _controller,
      cookieNames: const {'cf_clearance'},
      trusted: true,
      acceptValues: freshClearance != null && freshClearance.isNotEmpty
          ? {'cf_clearance': freshClearance}
          : null,
    );
  }

  // ---------------------------------------------------------------------------
  // JS 注入：拦截 XHR/fetch 对 cdn-cgi/challenge-platform 的响应
  // 当 challenge-platform 请求完成时，通过 JS Handler 通知 Flutter 侧
  // Flutter 侧用 CookieManager（可读 HttpOnly cookie）检查 cf_clearance
  // ---------------------------------------------------------------------------

  /// 注入 XHR/fetch 拦截 + 页面内 DOM 遮罩脚本
  ///
  /// 两层防线，确保跳转期间一帧 404 都不露：
  /// 1. JS 层：在 `beforeunload` / `pagehide` 的同一个 tick 里，立即往 DOM 里塞一个
  ///    `position:fixed;z-index:max` 的全屏 div，挡住当前页面剩余的渲染。
  /// 2. Flutter 层：通过 `onChallengeNavigation` Handler 通知 Dart 端 setState，
  ///    在 PlatformView 完成新页面渲染前用 Flutter 遮罩盖住。
  Future<void> _injectChallengeInterceptor(
    InAppWebViewController controller,
  ) async {
    final maskColorHex = _resolveMaskColorHex();
    await controller.evaluateJavascript(
      source:
          '''
(function() {
  if (window._cfInterceptorInstalled) return;
  window._cfInterceptorInstalled = true;
  window.__fluxdoCfMaskColor = '$maskColorHex';

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

  // 页面内 DOM 遮罩：CF 跳走的瞬间立刻挡住，不依赖 Flutter rebuild
  function showCfMask() {
    var root = document.body || document.documentElement;
    if (!root) return;
    var mask = document.getElementById('__fluxdoCfMask');
    if (mask) {
      mask.style.display = 'block';
      return;
    }
    mask = document.createElement('div');
    mask.id = '__fluxdoCfMask';
    mask.style.cssText = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;background:' +
      (window.__fluxdoCfMaskColor || '#ffffff') +
      '!important;z-index:2147483647!important;pointer-events:auto!important;';
    root.appendChild(mask);
  }
  window.__fluxdoShowCfMask = showCfMask;

  // 仅监听真正的"页面即将卸载"事件。
  // 不要 hook history.pushState/replaceState：CF Turnstile 验证过程中
  // 会用 history API 更新 URL 但不真正导航，hook 会在验证未完成时误触发 fallback。
  function notifyNav(reason) {
    showCfMask();
    try {
      window.flutter_inappwebview.callHandler('onChallengeNavigation', reason);
    } catch(e) {}
  }
  window.addEventListener('beforeunload', function(){ notifyNav('beforeunload'); });
  window.addEventListener('pagehide', function(){ notifyNav('pagehide'); });
})();
''',
    );
  }

  /// 取当前主题的 surface 色作为页面内 mask 颜色，深色模式下不会闪白
  String _resolveMaskColorHex() {
    if (!mounted) return '#ffffff';
    final color = Theme.of(context).colorScheme.surface;
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  UnmodifiableListView<UserScript> _initialChallengeScripts() {
    final maskColorHex = _resolveMaskColorHex();
    return UnmodifiableListView([
      UserScript(
        source: _documentStartMaskScript(maskColorHex),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
      ...WebViewSettings.compatPolyfillScripts,
    ]);
  }

  String _documentStartMaskScript(String maskColorHex) {
    return '''
(function() {
  if (window.__fluxdoCfDocumentMaskInstalled) return;
  window.__fluxdoCfDocumentMaskInstalled = true;
  window.__fluxdoCfMaskColor = '$maskColorHex';

  function root() {
    return document.body || document.documentElement;
  }

  function ensureMask() {
    var r = root();
    if (!r) return null;
    var mask = document.getElementById('__fluxdoCfMask');
    if (!mask) {
      mask = document.createElement('div');
      mask.id = '__fluxdoCfMask';
      mask.style.cssText = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;background:' +
        (window.__fluxdoCfMaskColor || '#ffffff') +
        '!important;z-index:2147483647!important;pointer-events:auto!important;';
      r.appendChild(mask);
    }
    return mask;
  }

  window.__fluxdoCfMaskSuppressed = false;

  window.__fluxdoShowCfMask = function(force) {
    if (window.__fluxdoCfMaskSuppressed && !force) return;
    window.__fluxdoCfMaskSuppressed = false;
    var mask = ensureMask();
    if (mask) mask.style.display = 'block';
  };

  window.__fluxdoHideCfMask = function() {
    window.__fluxdoCfMaskSuppressed = true;
    var mask = document.getElementById('__fluxdoCfMask');
    if (mask) mask.style.display = 'none';
  };

  function notifyNav(reason) {
    window.__fluxdoShowCfMask(true);
    try {
      window.flutter_inappwebview.callHandler('onChallengeNavigation', reason);
    } catch(e) {}
  }

  function looksLikeOrigin404() {
    try {
      var html = document.documentElement ? document.documentElement.innerHTML : '';
      var title = document.title || '';
      var haystack = (html + ' ' + title).toLowerCase();
      return haystack.indexOf('page-not-found') !== -1 ||
        haystack.indexOf('discourse-no-results') !== -1 ||
        haystack.indexOf('"errortype":"notfound"') !== -1 ||
        haystack.indexOf('404-body') !== -1 ||
        haystack.indexOf('exist or is private') !== -1 ||
        haystack.indexOf('page you requested') !== -1 ||
        title.indexOf('404') !== -1;
    } catch(e) {
      return false;
    }
  }

  var origin404Notified = false;
  function probeOrigin404() {
    if (origin404Notified || !looksLikeOrigin404()) return;
    origin404Notified = true;
    notifyNav('origin-404-dom');
  }

  function installOrigin404Observer() {
    probeOrigin404();
    try {
      var observer = new MutationObserver(probeOrigin404);
      observer.observe(document.documentElement || document, {
        childList: true,
        subtree: true,
        characterData: true
      });
    } catch(e) {}
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      window.__fluxdoShowCfMask(false);
      installOrigin404Observer();
    }, { once: true });
  } else {
    window.__fluxdoShowCfMask();
    installOrigin404Observer();
  }
  window.addEventListener('beforeunload', function(){ notifyNav('beforeunload'); });
  window.addEventListener('pagehide', function(){ notifyNav('pagehide'); });
})();
''';
  }

  /// challenge-platform 响应到达时的回调
  ///
  /// 不再主动 reveal WebView：reveal 完全交给 _startChallengeRevealProbe，
  /// 避免「完成响应到达 → reveal → 紧接着 CF 跳转回 /challenge 加载源站 404」
  /// 期间 404 闪现。此处只负责 cf_clearance 探测与 finish(true)。
  Future<void> _onChallengeComplete(List<dynamic> args) async {
    if (_hasPopped) return;
    final url = args.isNotEmpty ? args[0] : '';
    final status = args.length > 1 ? args[1] : 0;
    debugPrint('[CfChallenge] challenge-platform 响应: url=$url, status=$status');
    CfChallengeLogger.log(
      '[VERIFY] Challenge response: url=$url, status=$status',
    );

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
      await _syncLiveCookiesToCookieJar(freshClearance: cookieValue);
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

  /// 页面 unload/pagehide/history 变化时回调
  ///
  /// CF 验证完成后会跳到源 URL（/challenge → 404）。在 Android 上 `onLoadStart`
  /// 对部分 location.replace 跳转触发时机晚于 PlatformView 渲染，导致 404 闪现。
  /// 借助 JS 在跳走的最早时刻通知 Flutter，立即重置 reveal 状态、覆盖 WebView。
  Future<void> _onChallengeNavigation(List<dynamic> args) async {
    if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
    final reason = args.isNotEmpty ? args.first.toString() : 'unknown';
    if (!_challengeWebViewVisible && _hideOriginFallbackPage) {
      // 已经覆盖中，不必重复触发 fallback 流程
      return;
    }
    debugPrint('[CfChallenge] JS 导航事件 ($reason)，立刻覆盖 WebView');
    CfChallengeLogger.log('[VERIFY] JS navigation: $reason');
    await _handleVerifyOriginFallback(
      _loadGeneration,
      reason: 'js navigation: $reason',
      completionLikely: true,
    );
  }

  // ---------------------------------------------------------------------------
  // 超时计时器（兜底机制）
  // ---------------------------------------------------------------------------

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _checkCount = 0;
    _hasTimedOut = false;
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _finishingFromVerifyResponse) {
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
  /// 如果页面加载完成后没有盾，立刻走 fallback 流程，避免源站 404 露出
  void _scheduleNoChallengeCheck(InAppWebViewController controller) {
    _noChallengeCheckTimer?.cancel();
    final generation = _loadGeneration;
    _noChallengeCheckTimer = Timer(_noChallengeCheckDelay, () async {
      if (_hasPopped ||
          !mounted ||
          _finishingFromVerifyResponse ||
          generation != _loadGeneration) {
        return;
      }

      try {
        final hasChallenge = await _hasVisibleChallenge(controller);
        if (_hasPopped ||
            _finishingFromVerifyResponse ||
            generation != _loadGeneration) {
          return;
        }
        if (hasChallenge) {
          _revealChallengeWebView();
          return; // 页面有盾，等待正常验证流程
        }

        // 页面无盾：统一交给 fallback 处理（先轮询 cf_clearance，无果再给重试）
        await _handleVerifyOriginFallback(
          generation,
          reason:
              'no challenge after ${_noChallengeCheckDelay.inMilliseconds}ms',
          completionLikely: _hasSeenChallenge,
        );
      } catch (e) {
        debugPrint('[CfChallenge] 检测 challenge 状态异常: $e');
      }
    });
  }

  /// 处理「页面没有 CF 挑战」的统一入口
  ///
  /// 触发场景：源站 404 / onReceivedHttpError / reveal 后页面退化 / noChallengeCheck 命中。
  /// 行为：立刻覆盖 WebView 显示「正在完成验证…」overlay，短期轮询 cf_clearance；
  /// 拿到新 cf_clearance 则 finish(true)，否则前台显示「重试/退出」操作，后台直接 finish(false)。
  Future<void> _handleVerifyOriginFallback(
    int generation, {
    String? reason,
    bool completionLikely = false,
  }) async {
    if (_hasPopped || _finishingFromVerifyResponse) return;
    _coverWebViewForOriginFallback();
    if (_checkingOriginFallback) return;

    _checkingOriginFallback = true;
    final isCompletionProbe = completionLikely || _hasSeenChallenge;
    // 取消其余探测路径：状态已经收敛到 fallback，避免重复 evaluateJavascript
    _challengeRevealProbeGeneration++;
    _noChallengeCheckTimer?.cancel();
    if (reason != null) {
      debugPrint('[CfChallenge] fallback triggered: $reason');
    }

    try {
      final startedAt = DateTime.now();
      var attempt = 0;
      while (DateTime.now().difference(startedAt) <
          (isCompletionProbe
              ? _completionProbeTimeout
              : _noChallengeProbeTimeout)) {
        if (_hasPopped || _finishingFromVerifyResponse) return;
        if (!isCompletionProbe && generation != _loadGeneration) return;
        final cookieValue = await _readCookieValue('cf_clearance');
        if (_isFreshClearance(cookieValue)) {
          debugPrint(
            '[CfChallenge] fallback/completion 期间检测到新 cf_clearance，自动完成',
          );
          CfChallengeLogger.logVerifyResult(
            success: true,
            reason: reason ?? 'fresh cf_clearance during completion probe',
          );
          await _syncLiveCookiesToCookieJar(freshClearance: cookieValue);
          _timeoutTimer?.cancel();
          if (mounted) _finish(true);
          return;
        }
        attempt++;
        await Future.delayed(
          attempt < 12
              ? const Duration(milliseconds: 150)
              : const Duration(milliseconds: 400),
        );
      }

      debugPrint('[CfChallenge] fallback/completion 结束仍无新 cf_clearance');
      CfChallengeLogger.logVerifyResult(
        success: false,
        reason: reason ?? 'no fresh cf_clearance after completion probe',
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
      debugPrint('[CfChallenge] 处理 fallback 异常: $e');
    } finally {
      _checkingOriginFallback = false;
      if (mounted &&
          !_hasPopped &&
          (isCompletionProbe || generation == _loadGeneration)) {
        setState(() {});
      }
    }
  }

  void _coverWebViewForOriginFallback() {
    if (!mounted || _hasPopped) return;
    if (!_challengeWebViewVisible &&
        _hideOriginFallbackPage &&
        !_originFallbackNeedsAction &&
        !_needsManualAttention &&
        !_isLoading) {
      return;
    }
    setState(() {
      _challengeWebViewVisible = false;
      _hideOriginFallbackPage = true;
      _originFallbackNeedsAction = false;
      _needsManualAttention = false;
      _isLoading = false;
    });
  }

  /// 轮询检测 cf_clearance 变化（兜底 JS 回调被重定向吞掉的场景）
  bool _polling = false;
  Future<void> _pollCfClearance() async {
    if (_hasPopped || _finishingFromVerifyResponse || _polling) return;
    _polling = true;
    try {
      final cookieValue = await _readCookieValue('cf_clearance');
      if (_hasPopped || _finishingFromVerifyResponse) return;
      if (!_isFreshClearance(cookieValue)) return;

      debugPrint(
        '[CfChallenge] ✓ 轮询检测到新 cf_clearance (${cookieValue!.length} chars)',
      );
      CfChallengeLogger.logVerifyResult(
        success: true,
        reason: 'polling detected new cf_clearance',
      );
      await _syncLiveCookiesToCookieJar(freshClearance: cookieValue);
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
    _hasSeenChallenge = false;
    _hideOriginFallbackPage = false;
    _checkingOriginFallback = false;
    _originFallbackNeedsAction = false;
    _finishingFromVerifyResponse = false;
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

  bool _isBareVerifyUrl(WebUri? url) {
    if (!_isVerifyUrl(url)) return false;
    final actual = Uri.tryParse(url.toString());
    if (actual == null) return false;
    return actual.query.isEmpty;
  }

  Future<NavigationActionPolicy> _shouldOverrideVerifyNavigation(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (navigationAction.isForMainFrame == true &&
        _hasSeenChallenge &&
        _isBareVerifyUrl(url)) {
      debugPrint('[CfChallenge] 验证完成后准备加载 /challenge，提前覆盖并等待状态码');
      CfChallengeLogger.log(
        '[VERIFY] Post-challenge navigation to ${url?.toString() ?? ''}',
      );
      _coverWebViewForOriginFallback();
      unawaited(
        _handleVerifyOriginFallback(
          _loadGeneration,
          reason: 'post-challenge /challenge navigation pending status',
          completionLikely: true,
        ),
      );
    }

    return NavigationActionPolicy.ALLOW;
  }

  bool _isVerifyOriginFallback(
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    if (response.statusCode != 404) return false;
    if (request.isForMainFrame != true) return false;
    return _isVerifyUrl(request.url);
  }

  bool _isCfMitigatedChallengeHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return false;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'cf-mitigated' &&
          entry.value.toLowerCase().contains('challenge')) {
        return true;
      }
    }
    return false;
  }

  bool _isVerifyPassedResponse(
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    if (request.isForMainFrame != true) return false;
    if (!_isBareVerifyUrl(request.url)) return false;
    if (_isCfMitigatedChallengeHeaders(response.headers)) return false;

    // /challenge 是站点专用的 CF 验证入口：
    // 未通过时 Cloudflare 接管并返回 challenge；通过后请求会落到源站，
    // 源站没有这个业务页面，所以 404 本身就是“已通过 CF”的完成信号。
    return response.statusCode == 404;
  }

  bool _isVerifyPassedNavigationResponse(NavigationResponse response) {
    final urlResponse = response.response;
    if (response.isForMainFrame != true || urlResponse == null) return false;
    if (!_isBareVerifyUrl(urlResponse.url)) return false;
    if (_isCfMitigatedChallengeHeaders(urlResponse.headers)) return false;

    return urlResponse.statusCode == 404;
  }

  Future<NavigationResponseAction> _handleVerifyNavigationResponse(
    InAppWebViewController controller,
    NavigationResponse navigationResponse,
  ) async {
    final response = navigationResponse.response;
    if (navigationResponse.isForMainFrame == true &&
        _isVerifyUrl(response?.url)) {
      CfChallengeLogger.log(
        '[VERIFY] Main frame /challenge navigation response: '
        'status=${response?.statusCode}, '
        'headers=${response?.headers}',
      );
    }

    if (_isVerifyPassedNavigationResponse(navigationResponse)) {
      await _finishVerifiedFromNetworkStatus(
        reason: 'main frame /challenge navigation response returned source 404',
        headers: response?.headers,
      );
      return NavigationResponseAction.CANCEL;
    }

    return NavigationResponseAction.ALLOW;
  }

  Future<void> _finishVerifiedFromNetworkStatus({
    required String reason,
    Map<String, String>? headers,
  }) async {
    if (_hasPopped || _finishingFromVerifyResponse) return;
    _finishingFromVerifyResponse = true;
    _coverWebViewForOriginFallback();
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _challengeRevealProbeGeneration++;
    _revealStateWatchGeneration++;

    debugPrint('[CfChallenge] $reason，按网络状态判定验证完成');
    CfChallengeLogger.logVerifyResult(success: true, reason: reason);
    if (headers != null) {
      CfChallengeLogger.log('[VERIFY] Passed response headers: $headers');
    }

    unawaited(_syncVerifiedCookiesBestEffort());
    if (mounted && !_hasPopped) _finish(true);
  }

  Future<void> _syncVerifiedCookiesBestEffort() async {
    try {
      final freshClearance = await _readCookieValue('cf_clearance');
      await _syncLiveCookiesToCookieJar(
        freshClearance: _isFreshClearance(freshClearance)
            ? freshClearance
            : null,
      );
    } catch (e) {
      debugPrint('[CfChallenge] 按网络状态完成时后台同步 cookie 失败: $e');
    }
  }

  Future<bool> _hasVisibleChallenge(InAppWebViewController controller) async {
    final html = await controller.evaluateJavascript(
      source:
          'document.documentElement ? document.documentElement.innerHTML : ""',
    );
    if (html == null) return false;
    return CfChallengeService.hasActiveCfChallenge(html.toString());
  }

  int _revealStateWatchGeneration = 0;

  void _revealChallengeWebView() {
    if (_hasPopped ||
        !mounted ||
        _finishingFromVerifyResponse ||
        _challengeWebViewVisible) {
      return;
    }
    _hasSeenChallenge = true;
    unawaited(
      _controller
              ?.evaluateJavascript(source: 'window.__fluxdoHideCfMask?.();')
              .catchError((Object e) {
                debugPrint('[CfChallenge] 隐藏 DOM mask 失败: $e');
              }) ??
          Future<void>.value(),
    );
    setState(() {
      _challengeWebViewVisible = true;
      _hideOriginFallbackPage = false;
      _originFallbackNeedsAction = false;
    });
    _startRevealedStateWatcher();
  }

  /// reveal 后持续监测：若页面内容退化为非挑战（典型为源站 404），立即重新覆盖
  ///
  /// 触发场景：CF 在 reveal 期间内联跳走（替换 location 而未触发 onLoadStart）、
  /// SPA 路由切换、或 onReceivedHttpError 在当前平台未触发但页面已渲染源站 404。
  void _startRevealedStateWatcher() {
    final watcherGeneration = ++_revealStateWatchGeneration;
    final loadGeneration = _loadGeneration;
    unawaited(() async {
      while (true) {
        await Future.delayed(_revealStateWatchInterval);
        if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
        if (watcherGeneration != _revealStateWatchGeneration) return;
        if (loadGeneration != _loadGeneration) return;
        if (!_challengeWebViewVisible) return;
        // 超时后不再做主动监测，留给已有超时 UI / 用户操作
        if (_hasTimedOut) return;

        final controller = _controller;
        if (controller == null) continue;

        try {
          final html = await controller.evaluateJavascript(
            source:
                'document.documentElement ? document.documentElement.innerHTML : ""',
          );
          if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
          if (watcherGeneration != _revealStateWatchGeneration) return;
          if (loadGeneration != _loadGeneration) return;
          if (html == null) continue;

          final htmlStr = html.toString();
          if (CfChallengeService.hasActiveCfChallenge(htmlStr)) continue;

          // 页面无挑战。要么是 CF 已完成跳走，要么是源站 404 渲染出来。
          // 统一交给 fallback 流程：先轮询 cf_clearance，没拿到再给用户重试入口。
          debugPrint('[CfChallenge] reveal 后检测到页面无挑战，主动覆盖并探测 cf_clearance');
          unawaited(
            _handleVerifyOriginFallback(
              loadGeneration,
              reason: 'reveal watcher: page lost CF challenge markers',
              completionLikely: true,
            ),
          );
          return;
        } catch (e) {
          debugPrint('[CfChallenge] reveal watcher 检测异常: $e');
        }
      }
    }());
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
            _finishingFromVerifyResponse ||
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
      icon = Symbols.error_rounded;
      title = context.l10n.cf_verifyTimedOutTitle;
      message = context.l10n.cf_verifyTimedOutMessage;
    } else if (_needsManualAttention) {
      backgroundColor = colorScheme.secondaryContainer;
      foregroundColor = colorScheme.onSecondaryContainer;
      icon = Symbols.touch_app_rounded;
      title = context.l10n.cf_manualVerifyBannerTitle;
      message = context.l10n.cf_manualVerifyBannerMessage;
    } else {
      backgroundColor = colorScheme.tertiaryContainer;
      foregroundColor = colorScheme.onTertiaryContainer;
      icon = Symbols.hourglass_bottom_rounded;
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
                          fontWeight: FontWeight.w500,
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
    final _FallbackState state;
    if (_originFallbackNeedsAction) {
      state = _FallbackState.noChallenge;
    } else if (_checkingOriginFallback) {
      state = _FallbackState.completing;
    } else {
      state = _FallbackState.opening;
    }

    return _ChallengeFallbackOverlay(
      state: state,
      onRetry: _refresh,
      onExit: _confirmExit,
    );
  }

  void _handlePageReady(InAppWebViewController controller, {String? reason}) {
    if (_hasMarkedPageReady || _hasPopped || _finishingFromVerifyResponse) {
      return;
    }
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
    // 同步立刻探一次内容：识别明确的源站 404 / 非挑战页面时直接覆盖，
    // 避免等到 _noChallengeCheckDelay 才决断，挤压可能的 404 露出窗口
    unawaited(_probeContentImmediately(controller, generation));
  }

  /// 页面就绪后立刻探一次内容
  ///
  /// 命中明确的源站 404 → 直接走 fallback 覆盖；命中 CF 挑战 → reveal；
  /// 介于两者之间（白屏/加载中）就交给 reveal probe + noChallengeCheck 兜底。
  Future<void> _probeContentImmediately(
    InAppWebViewController controller,
    int generation,
  ) async {
    if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
    if (generation != _loadGeneration) return;
    try {
      final html = await controller.evaluateJavascript(
        source:
            'document.documentElement ? document.documentElement.innerHTML : ""',
      );
      if (_hasPopped ||
          !mounted ||
          _finishingFromVerifyResponse ||
          generation != _loadGeneration) {
        return;
      }
      if (html == null) return;
      final htmlStr = html.toString();
      if (CfChallengeService.hasActiveCfChallenge(htmlStr)) {
        _revealChallengeWebView();
        return;
      }
      if (CfChallengeService.isOriginNotFound(htmlStr)) {
        await _handleVerifyOriginFallback(
          generation,
          reason: 'immediate probe: origin 404 markers',
          completionLikely: _hasSeenChallenge,
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] 即时内容探测异常: $e');
    }
  }

  void _schedulePageReadyFallback(InAppWebViewController controller) {
    if ((!io.Platform.isWindows && !io.Platform.isLinux) ||
        _hasMarkedPageReady) {
      return;
    }
    _pageReadyFallbackTimer?.cancel();
    _pageReadyFallbackTimer = Timer(_pageReadyFallbackDelay, () {
      _pageReadyFallbackTimer = null;
      if (_hasMarkedPageReady || _hasPopped || _finishingFromVerifyResponse) {
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
      if (_hasMarkedPageReady ||
          _hasPopped ||
          _finishingFromVerifyResponse ||
          _progress < 0.95) {
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
            useShouldOverrideUrlLoading: true,
            useOnNavigationResponse: true,
          ),
          initialUserScripts: _initialChallengeScripts(),
          shouldOverrideUrlLoading: _shouldOverrideVerifyNavigation,
          onNavigationResponse: _handleVerifyNavigationResponse,
          onReceivedServerTrustAuthRequest: (_, challenge) =>
              WebViewSettings.handleServerTrustAuthRequest(challenge),
          onWebViewCreated: (controller) {
            _controller = controller;
            WebViewSettings.registerJsErrorReporter(controller);
            // 注册 JS Handler，challenge-platform 响应到达时触发
            controller.addJavaScriptHandler(
              handlerName: 'onChallengeComplete',
              callback: _onChallengeComplete,
            );
            // 注册 JS Handler，CF 验证完成后即将跳走时触发，立刻覆盖避免 404 露出
            controller.addJavaScriptHandler(
              handlerName: 'onChallengeNavigation',
              callback: _onChallengeNavigation,
            );
          },
          onLoadStart: (controller, url) {
            if (_hasPopped || _finishingFromVerifyResponse) return;
            final isCompletionNavigation = _hasSeenChallenge;
            _loadGeneration++;
            _challengeRevealProbeGeneration++;
            _loadStopFallbackTimer?.cancel();
            _pageReadyFallbackTimer?.cancel();
            _hasMarkedPageReady = false;
            _hasTimedOut = false;
            _needsManualAttention = false;
            _challengeWebViewVisible = false;
            _hideOriginFallbackPage = isCompletionNavigation;
            if (!isCompletionNavigation) {
              _checkingOriginFallback = false;
            }
            _originFallbackNeedsAction = false;
            _schedulePageReadyFallback(controller);
            setState(() {
              _isLoading = true;
              _progress = 0;
            });
            if (isCompletionNavigation) {
              unawaited(
                _handleVerifyOriginFallback(
                  _loadGeneration,
                  reason: 'loadStart after challenge: ${url?.toString() ?? ''}',
                  completionLikely: true,
                ),
              );
            }
          },
          onPageCommitVisible: (controller, url) {
            if (_finishingFromVerifyResponse) return;
            _handlePageReady(controller, reason: 'onPageCommitVisible');
          },
          onProgressChanged: (controller, progress) {
            if (_finishingFromVerifyResponse) return;
            _progress = progress / 100;
            _scheduleLoadStopFallback(controller, progress);
            if (showUi) {
              setState(() {});
            }
          },
          onLoadStop: (controller, url) {
            if (_finishingFromVerifyResponse) return;
            WebViewSettings.injectScrollFix(controller);
            _handlePageReady(controller, reason: 'onLoadStop');
          },
          onReceivedError: (controller, request, error) {
            if (_finishingFromVerifyResponse) return;

            final uri = Uri.tryParse(request.url.toString());
            final isMainFrame = request.isForMainFrame == true;
            CfChallengeLogger.log(
              '[VERIFY] WebView load error: '
              'mainFrame=$isMainFrame '
              'host=${uri?.host ?? '-'} path=${uri?.path ?? '-'} '
              'type=${error.type} description=${error.description}',
              level: isMainFrame ? 'warning' : 'info',
              fields: {
                'isMainFrame': isMainFrame,
                'host': uri?.host,
                'path': uri?.path,
                'errorType': error.type.toString(),
                'description': error.description,
              },
            );

            // WebView 会把脚本、图片、CF challenge-platform 等子资源错误也
            // 上报到这里。子资源连接被刷新流程关闭时，主验证页通常仍可正常
            // 使用；不要因此结束加载态或向用户显示整页加载失败。
            if (!isMainFrame) return;

            _pageReadyFallbackTimer?.cancel();
            if (mounted) {
              setState(() => _isLoading = false);
            }
            if (showUi) {
              _showError(context.l10n.cf_loadFailed(error.description));
            }
          },
          onReceivedHttpError: (controller, request, errorResponse) {
            if (_hasPopped || _finishingFromVerifyResponse) return;
            if (request.isForMainFrame == true && _isVerifyUrl(request.url)) {
              CfChallengeLogger.log(
                '[VERIFY] Main frame /challenge HTTP response: '
                'status=${errorResponse.statusCode}, '
                'headers=${errorResponse.headers}',
              );
            }
            if (_isVerifyPassedResponse(request, errorResponse)) {
              unawaited(
                _finishVerifiedFromNetworkStatus(
                  reason: 'main frame /challenge returned source 404',
                  headers: errorResponse.headers,
                ),
              );
              return;
            }
            if (_isVerifyOriginFallback(request, errorResponse)) {
              unawaited(
                _handleVerifyOriginFallback(
                  _loadGeneration,
                  reason: 'main frame /challenge returned 404',
                  completionLikely: _hasSeenChallenge,
                ),
              );
            }
          },
        ),
        getController: () => _controller,
      ),
    );
  }

  Widget _buildPanelHeader(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final iconColor = colorScheme.onSurfaceVariant;

    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Symbols.close_rounded, size: 20),
              color: iconColor,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: context.l10n.common_exit,
              onPressed: showExitConfirmation,
            ),
            const SizedBox(width: 4),
            Icon(Symbols.shield_rounded, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                context.l10n.cf_securityVerifyTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                  letterSpacing: 0.1,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Symbols.refresh_rounded, size: 20),
              color: iconColor,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: context.l10n.common_refresh,
              onPressed: _refresh,
            ),
            IconButton(
              icon: const Icon(Symbols.help_rounded, size: 20),
              color: iconColor,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
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
      elevation: 0,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildPanelHeader(theme),
          SizedBox(
            height: 2,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _isLoading
                  ? LinearProgressIndicator(
                      key: const ValueKey('loading'),
                      value: _progress > 0 ? _progress : null,
                      minHeight: 2,
                      backgroundColor: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      color: colorScheme.primary.withValues(alpha: 0.75),
                    )
                  : SizedBox.shrink(
                      key: const ValueKey('idle'),
                      child: ColoredBox(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final coverWebView = _shouldCoverWebView;
                final webViewWidth = math.max(1.0, constraints.maxWidth);
                final webViewHeight = math.max(1.0, constraints.maxHeight);
                final screenWidth = MediaQuery.sizeOf(context).width;
                final hiddenLeft = -(screenWidth + webViewWidth + 64);

                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: coverWebView ? hiddenLeft : 0,
                      top: 0,
                      width: webViewWidth,
                      height: webViewHeight,
                      child: IgnorePointer(
                        ignoring: coverWebView,
                        child: _buildChallengeWebView(showUi: true),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !coverWebView,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: coverWebView ? 1 : 0,
                          curve: Curves.easeOut,
                          child: _buildOriginFallbackOverlay(theme),
                        ),
                      ),
                    ),
                    if (!coverWebView && _shouldShowStatusBanner)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: _buildStatusBanner(theme),
                      ),
                  ],
                );
              },
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
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: theme.brightness == Brightness.dark
                                          ? 0.45
                                          : 0.12,
                                    ),
                                    blurRadius: 32,
                                    offset: const Offset(0, 12),
                                  ),
                                ],
                                border: Border.all(
                                  color: colorScheme.outlineVariant.withValues(
                                    alpha: 0.35,
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

  Size _resolveBackgroundWebViewSize(BuildContext context) {
    final media = MediaQuery.of(context);
    final safeWidth = math.max(
      1.0,
      media.size.width - media.padding.horizontal,
    );
    final safeHeight = math.max(
      1.0,
      media.size.height - media.padding.vertical,
    );
    final isCompact = safeWidth < 640;
    final horizontalMargin = isCompact ? 12.0 : 24.0;
    final verticalMargin = isCompact ? 12.0 : 24.0;
    final panelWidth = math.max(
      1.0,
      math.min(720.0, safeWidth - horizontalMargin * 2),
    );
    final availableHeight = math.max(360.0, safeHeight - verticalMargin * 2);
    final targetHeight = isCompact
        ? availableHeight * 0.88
        : math.min(720.0, availableHeight);
    final minHeight = math.min(460.0, availableHeight);
    final panelHeight = math.max(minHeight, targetHeight);
    const chromeHeight = 46.0; // header 44 + progress bar 2
    return Size(panelWidth, math.max(1.0, panelHeight - chromeHeight));
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showUi = !_isBackground;
    final backgroundWebViewSize = showUi
        ? Size.zero
        : _resolveBackgroundWebViewSize(context);

    return Stack(
      children: [
        if (showUi)
          Positioned.fill(child: _buildContextualVerifyLayer(theme))
        else
          Positioned(
            left: -backgroundWebViewSize.width - 64,
            top: -backgroundWebViewSize.height - 64,
            width: backgroundWebViewSize.width,
            height: backgroundWebViewSize.height,
            child: _buildChallengeWebView(showUi: false),
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

        // 悬浮验证胶囊：默认收起，点击展开，再次点击进入前台
        if (_isBackground)
          DraggableFloatingPill(
            initialTop: 100,
            onTap: _promoteToForeground,
            child: Text(S.current.cf_backgroundVerifying),
          ),
      ],
    );
  }
}

/// Fallback overlay 的三种状态
enum _FallbackState {
  /// 正在打开验证页（默认初始态、加载中）
  opening,

  /// 验证响应已到达，正在做最后的 cookie 同步
  completing,

  /// 没有需要完成的验证（极少出现，留给用户重试或退出）
  noChallenge,
}

/// 验证遮罩层
///
/// CF 官方风：左上角小 logo + 中心三点波纹 + 底部署名。
/// 负责盖住 WebView 在加载/完成/无挑战时可能闪现的源站 404。
class _ChallengeFallbackOverlay extends StatefulWidget {
  const _ChallengeFallbackOverlay({
    required this.state,
    required this.onRetry,
    required this.onExit,
  });

  final _FallbackState state;
  final VoidCallback onRetry;
  final VoidCallback onExit;

  @override
  State<_ChallengeFallbackOverlay> createState() =>
      _ChallengeFallbackOverlayState();
}

class _ChallengeFallbackOverlayState extends State<_ChallengeFallbackOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _dotsController;

  @override
  void initState() {
    super.initState();
    _dotsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _dotsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final state = widget.state;

    return ColoredBox(
      color: colorScheme.surface,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Stack(
          children: [
            // 中心：动画 + 文案（panel 头部已有「安全验证」title，这里不重复）
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(state),
                      child: _buildCenter(theme, colorScheme, state),
                    ),
                  ),
                ),
              ),
            ),

            // 底部：Powered by Cloudflare
            Align(
              alignment: Alignment.bottomCenter,
              child: Text(
                'Powered by Cloudflare',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenter(
    ThemeData theme,
    ColorScheme colorScheme,
    _FallbackState state,
  ) {
    final l10n = context.l10n;

    if (state == _FallbackState.noChallenge) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.primary.withValues(alpha: 0.12),
            ),
            alignment: Alignment.center,
            child: Icon(
              Symbols.verified_user_rounded,
              size: 28,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            l10n.cf_noChallengeTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.cf_noChallengeMessage,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                onPressed: widget.onRetry,
                icon: const Icon(Symbols.refresh_rounded, size: 18),
                label: Text(l10n.cf_retryVerificationAction),
              ),
              TextButton(
                onPressed: widget.onExit,
                child: Text(l10n.common_exit),
              ),
            ],
          ),
        ],
      );
    }

    // opening / completing
    final isCompleting = state == _FallbackState.completing;
    final title = isCompleting
        ? l10n.cf_verifyCompletingTitle
        : l10n.cf_verifyOpeningTitle;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 24,
          child: _BouncingDots(
            controller: _dotsController,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurface,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );
  }
}

/// 三点波纹：每个点按相位轮流"亮起 + 略放大"
class _BouncingDots extends StatelessWidget {
  const _BouncingDots({required this.controller, required this.color});

  final AnimationController controller;
  final Color color;

  Widget _dot(double phaseOffset) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final local = (controller.value + phaseOffset) % 1.0;
        // sin(πx) 在 [0,1] 上是 0→1→0 的平滑波形
        final wave = math.sin(local * math.pi);
        final scale = 0.75 + 0.35 * wave;
        final alpha = 0.3 + 0.7 * wave;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: alpha),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _dot(0.0),
        const SizedBox(width: 10),
        _dot(-0.16),
        const SizedBox(width: 10),
        _dot(-0.32),
      ],
    );
  }
}
