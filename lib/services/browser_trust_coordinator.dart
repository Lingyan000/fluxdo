import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../constants.dart';
import 'auth_session.dart';
import 'network/webview/site_webview_runtime.dart';
import 'network/webview/shared_browser_resource.dart';
import 'app_logger.dart';
import 'cf_challenge_logger.dart';
import 'cf_challenge_service.dart';
import 'cf_clearance_refresh_service.dart';
import 'discourse/discourse_service.dart';
import 'network/cookie/boundary_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'network/cookie/webview_cookie_priming.dart';
import 'network/webview/webview_adapter_settings_service.dart';
import 'preloaded_data_service.dart';
import 'webview_session_cookie_refresh_service.dart';

enum BrowserTrustPreloadPath { native, webView }

/// 启动预加载当前所处阶段，供启动页展示等待状态。
enum BrowserTrustPreloadStage {
  /// 通过应用网络栈加载首页数据
  native,

  /// 兼容模式通过共享 WebView 加载首页文档
  webView,

  /// WebView 通道超时/不可用，回退原生直连
  fallback,
}

/// 启动期共享 WebView 任务的协作式取消令牌。
@visibleForTesting
class BrowserTrustRunCancellation {
  bool _cancelled = false;
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
  }
}

/// 超时后取消后续工作，但仍等待原任务完成 finally 清理，避免留下孤儿 WebView。
@visibleForTesting
Future<T?> runBrowserTrustTaskWithSafeTimeout<T>({
  required Future<T> task,
  required Duration timeout,
  required BrowserTrustRunCancellation cancellation,
  Duration cleanupTimeout = const Duration(seconds: 30),
}) async {
  try {
    return await task.timeout(timeout);
  } on TimeoutException {
    cancellation.cancel();
    try {
      await task.timeout(cleanupTimeout);
    } on TimeoutException {
      // 协作式取消无法中断已经卡在原生 WebView2 调用里的 Future。排水也必须
      // 有上限，否则为了避免孤儿 WebView 反而会让整个启动链永久挂死。
      debugPrint(
        '[BrowserTrust] cancelled WebView task did not finish cleanup within '
        '${cleanupTimeout.inSeconds}s; continuing startup',
      );
    } catch (_) {
      // 原任务错误不覆盖“已超时”结果；正常情况下 finally 已完成清理。
    }
    return null;
  }
}

/// 一轮同步只有一个等待预算，迟到完成也不会改变已发布的超时结果。
@visibleForTesting
class BrowserTrustRequestGate {
  BrowserTrustRequestGate({
    required Duration timeout,
    required bool Function() onTimeout,
  }) {
    future = _ready.future.timeout(timeout, onTimeout: onTimeout);
  }

  final Completer<bool> _ready = Completer<bool>();
  late final Future<bool> future;
  bool get isCompleted => _ready.isCompleted;

  void complete(bool ready) {
    if (!_ready.isCompleted) _ready.complete(ready);
  }
}

/// 浏览器信任编排器。
///
/// 负责启动/恢复阶段的浏览器态准备，避免 WebView priming、session bootstrap、
/// cf_clearance 维护、预加载请求在 main / widget 中散落。
class BrowserTrustCoordinator {
  BrowserTrustCoordinator._();
  static final BrowserTrustCoordinator instance = BrowserTrustCoordinator._();

  static const Duration _requestClearanceMinTtl = Duration(seconds: 30);
  static const Duration _webViewPreloadTimeout = Duration(seconds: 25);
  static const Duration _domSnapshotTimeout = Duration(seconds: 12);
  static const Duration _backgroundPauseDelay = Duration(seconds: 8);
  static const Duration _requestGateTimeout = Duration(seconds: 6);
  static const Duration _diagnosticBackgroundPauseDelay = Duration(seconds: 60);

  final CookieJarService _jar = CookieJarService();
  final PreloadedDataService _preload = PreloadedDataService();

  Future<void>? _activePreload;

  /// 预加载进行中的阶段；空闲（未开始或已结束）时为 null。
  final ValueNotifier<BrowserTrustPreloadStage?> preloadStage =
      ValueNotifier<BrowserTrustPreloadStage?>(null);
  Future<bool>? _activeBrowserTrust;
  Future<bool>? _activeBrowserTrustGate;
  Timer? _backgroundPauseTimer;
  String? _pendingClearanceRefreshReason;

  /// 导航 context,供 bootstrap 被 CF 挡下时主动发起 CF 验证(showManualVerify)。
  BuildContext? _navigatorContext;

  /// 会话同步最近一次收到 CF 拒绝的时刻，供首批业务请求的信任检查使用。
  DateTime? _lastClearanceRejectedAt;
  static const Duration _clearanceRejectionTtl = Duration(minutes: 2);

  /// 最近是否被服务端以 CF 拒绝过(带自动过期清理)。
  bool get _clearanceRecentlyRejected {
    final at = _lastClearanceRejectedAt;
    if (at == null) return false;
    if (DateTime.now().difference(at) >= _clearanceRejectionTtl) {
      _lastClearanceRejectedAt = null;
      return false;
    }
    return true;
  }

  BrowserTrustPreloadPath? _lastPreloadPath;

  BrowserTrustPreloadPath? get lastPreloadPath => _lastPreloadPath;

  void setNavigatorContext(BuildContext context) {
    _navigatorContext = context;
    DiscourseService().setNavigatorContext(context);
    _preload.setNavigatorContext(context);
  }

  /// 启动期轻量准备：只做 cookie priming，不加载首页，不阻塞 runApp。
  void prepareStartup({String reason = 'startup'}) {
    unawaited(
      _primeWebViewCookies(reason: reason).catchError((Object e) {
        _log('startup priming failed: $e', level: 'warning');
      }),
    );
  }

  void pauseForBackground() {
    _backgroundPauseTimer?.cancel();
    final delay = CfChallengeLogger.isEnabled
        ? _diagnosticBackgroundPauseDelay
        : _backgroundPauseDelay;
    _log('schedule cf_clearance refresh pause: delay=${delay.inSeconds}s');
    _backgroundPauseTimer = Timer(delay, () {
      _backgroundPauseTimer = null;
      _log('execute delayed cf_clearance refresh pause');
      CfClearanceRefreshService().pause();
    });
  }

  /// 前台恢复：恢复 cf_clearance 维护，并在后台补一次浏览器 session bootstrap。
  void resumeFromBackground({String reason = 'resume', bool force = false}) {
    final hadPendingPause = _backgroundPauseTimer != null;
    _backgroundPauseTimer?.cancel();
    _backgroundPauseTimer = null;
    if (hadPendingPause) {
      _log('cancel scheduled cf_clearance refresh pause: reason=$reason');
    }
    CfClearanceRefreshService().resume();
    unawaited(
      ensureBrowserTrust(reason: reason, force: force).catchError((Object e) {
        _log('resume browser trust failed: $e', level: 'warning');
        return false;
      }),
    );
  }

  /// 首页默认通过应用网络栈请求。兼容模式使用共享 WebView 读取首页文档。
  Future<void> ensurePreloaded({String reason = 'unknown'}) {
    if (_preload.isLoaded) return Future.value();

    final active = _activePreload;
    if (active != null) {
      _log('reuse active preload: reason=$reason');
      return active;
    }

    // 先登记本轮请求，阶段通知触发的调用也能复用它。
    final preload = Completer<void>();
    _activePreload = preload.future;
    preload.complete(
      _ensurePreloadedInternal(reason: reason).whenComplete(() {
        _activePreload = null;
        preloadStage.value = null;
      }),
    );
    return preload.future;
  }

  Future<bool> ensureBrowserTrust({
    String reason = 'unknown',
    bool force = false,
  }) {
    if (!force) {
      final active = _activeBrowserTrust;
      if (active != null) return active;
    }

    final gateCompleter = BrowserTrustRequestGate(
      timeout: _requestGateTimeout,
      onTimeout: () {
        _log(
          'browser trust request gate expired reason=$reason',
          level: 'warning',
        );
        return false;
      },
    );
    late final Future<bool> gateFuture;
    gateFuture = gateCompleter.future.whenComplete(() {
      if (identical(_activeBrowserTrustGate, gateFuture)) {
        _activeBrowserTrustGate = null;
      }
    });

    late final Future<bool> future;
    future =
        _ensureBrowserTrustInternal(
          reason: reason,
          requestGate: gateCompleter,
          forceSessionSync: force,
        ).whenComplete(() {
          _completeRequestGate(gateCompleter, false);
          if (_pendingClearanceRefreshReason != null) {
            _flushPendingClearanceRefresh(reason: 'browser_trust_settled');
          }
          if (identical(_activeBrowserTrust, future)) {
            _activeBrowserTrust = null;
          }
        });
    _activeBrowserTrustGate = gateFuture;
    _activeBrowserTrust = future;
    return future;
  }

  /// 仅等待当前已经在跑的浏览器信任同步，不主动创建新的 WebView。
  ///
  /// 用于启动/恢复后的首波业务请求：UI 可以先进入首页，但这些请求如果
  /// 抢在 WebView session bootstrap / cf_clearance 同步之前发出，容易把
  /// 本来可恢复的状态打成 403。等待是有上限的，超时后仍放行。
  Future<bool?> waitForActiveBrowserTrust({
    String reason = 'unknown',
    Duration timeout = _requestGateTimeout,
  }) async {
    final active = _activeBrowserTrustGate;
    if (active == null) return null;

    try {
      _log('wait active browser trust gate begin reason=$reason');
      final ready = await active.timeout(timeout);
      _log('wait active browser trust gate end reason=$reason ready=$ready');
      return ready;
    } on TimeoutException {
      _log(
        'wait active browser trust gate timeout reason=$reason '
        'timeout=${timeout.inSeconds}s',
        level: 'warning',
      );
      return false;
    } catch (e) {
      _log(
        'wait active browser trust gate failed reason=$reason: $e',
        level: 'warning',
      );
      return false;
    }
  }

  void startClearanceRefresh({String reason = 'unknown'}) {
    if (_activeBrowserTrust != null) {
      _pendingClearanceRefreshReason = reason;
      _log(
        'defer cf_clearance refresh until browser trust settles: reason=$reason',
      );
      return;
    }
    _startClearanceRefreshNow(reason: reason);
  }

  void _startClearanceRefreshNow({required String reason}) {
    _log('start cf_clearance refresh: reason=$reason');
    CfClearanceRefreshService().start();
  }

  Future<void> _ensurePreloadedInternal({required String reason}) async {
    var fallbackFromUnavailableWebView = false;
    if (WebViewAdapterSettingsService.instance.effectiveEnabled) {
      // 兼容模式通过文档导航读取首页内嵌的预加载数据。
      preloadStage.value = BrowserTrustPreloadStage.webView;
      _log('preload path=startup_webview mode=compatibility reason=$reason');
      final cancellation = BrowserTrustRunCancellation();
      final hydrated = await runBrowserTrustTaskWithSafeTimeout<bool>(
        task: _hydratePreloadThroughWebView(
          reason: reason,
          cancellation: cancellation,
        ),
        timeout: _webViewPreloadTimeout,
        cancellation: cancellation,
      );
      if (hydrated == true) {
        _lastPreloadPath = BrowserTrustPreloadPath.webView;
        _log('startup WebView preload success reason=$reason');
        startClearanceRefresh(reason: '$reason:preload_webview');
        return;
      }
      _log(
        'startup WebView preload ${hydrated == null ? 'timed out' : 'unavailable'}, '
        'fallback native reason=$reason',
        level: 'warning',
      );
      preloadStage.value = BrowserTrustPreloadStage.fallback;
      fallbackFromUnavailableWebView = true;
    } else {
      preloadStage.value = BrowserTrustPreloadStage.native;
    }

    _lastPreloadPath = BrowserTrustPreloadPath.native;
    _log('preload path=native reason=$reason');
    await _preload.ensureLoaded(
      skipWebViewAdapter: fallbackFromUnavailableWebView,
    );
    _log('native preload success reason=$reason');
    _startBrowserTrustAfterNativePreload(reason: reason);
  }

  void _startBrowserTrustAfterNativePreload({required String reason}) {
    if (!_preload.isLoaded) return;
    if (_preload.currentUserSync == null) {
      _log('skip native preload browser trust settle: not logged in');
      // 对齐站点网页端：未登录态也按 sitekey 启动 Turnstile Pre-Clearance，
      // 让登录与后续匿名浏览提前拿到 cf_clearance。
      startClearanceRefresh(reason: '$reason:preload_anon');
      return;
    }

    unawaited(() async {
      try {
        final synced = await ensureBrowserTrust(
          reason: '$reason:native_preload_settle',
        );
        _log('native preload browser trust settled=$synced reason=$reason');
      } catch (e) {
        _log(
          'native preload browser trust settle failed: $e',
          level: 'warning',
        );
      }
    }());
  }

  Future<bool> _ensureBrowserTrustInternal({
    required String reason,
    BrowserTrustRequestGate? requestGate,
    required bool forceSessionSync,
  }) async {
    final stopwatch = Stopwatch()..start();
    _log('browser trust sync begin reason=$reason');
    try {
      final gateStartedAt = stopwatch.elapsedMilliseconds;
      _log('browser trust request gate priming begin reason=$reason');
      await _primeWebViewCookies(reason: reason);
      final requestTrusted = await _isRequestGateTrusted();
      _completeRequestGate(requestGate, requestTrusted);
      _log(
        'browser trust request gate ready reason=$reason '
        'trusted=$requestTrusted elapsedMs=${stopwatch.elapsedMilliseconds} '
        'gateElapsedMs=${stopwatch.elapsedMilliseconds - gateStartedAt}',
        level: requestTrusted ? 'info' : 'warning',
      );
    } catch (e) {
      _completeRequestGate(requestGate, false);
      rethrow;
    }

    final sessionStartedAt = stopwatch.elapsedMilliseconds;
    _log(
      'browser trust session bootstrap begin reason=$reason '
      'force=$forceSessionSync',
    );
    var bootstrap = await WebViewSessionCookieRefreshService.instance
        .ensureSynced(reason: reason, force: forceSessionSync);
    // bootstrap 被 CF(403/429)挡下:作废本地假阳性信任,复用/发起 CF 验证拿到
    // 新 cf_clearance 后 force 重跑一次,避免与 Dio 侧的 CF 自愈各自为政。
    if (bootstrap.cfBlocked) {
      bootstrap = await _recoverBootstrapFromCfBlock(
        reason: reason,
        blocked: bootstrap,
      );
    }
    final synced = bootstrap.ok;
    _log(
      'browser trust session bootstrap end reason=$reason '
      'synced=$synced cfBlocked=${bootstrap.cfBlocked} '
      'elapsedMs=${stopwatch.elapsedMilliseconds} '
      'sessionElapsedMs=${stopwatch.elapsedMilliseconds - sessionStartedAt}',
      level: synced ? 'info' : 'warning',
    );
    _log(
      'browser trust sync end reason=$reason synced=$synced '
      'elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
    _flushPendingClearanceRefresh(reason: 'preload_settled');
    return synced;
  }

  /// WebView session bootstrap 被 CF(403/429)挡下后的统一恢复:
  /// 作废本地假阳性信任 → 复用 Dio 侧正在进行的验证(没有则主动发起)→
  /// 成功后 force 重跑一次 bootstrap。只重试一次,避免与 CF 拉锯/死循环。
  Future<SessionBootstrapResult> _recoverBootstrapFromCfBlock({
    required String reason,
    required SessionBootstrapResult blocked,
  }) async {
    final cycleStartAt = DateTime.now();
    _lastClearanceRejectedAt = cycleStartAt;
    _log(
      'bootstrap blocked by CF status=${blocked.status} phase=${blocked.phase}; '
      'invalidate native trust, coordinate clearance reason=$reason',
      level: 'warning',
    );
    AppLogger.warning(
      'WebView bootstrap 被 CF 挡下(status=${blocked.status}),开始统一恢复',
      tag: 'BrowserTrust',
    );

    final cf = CfChallengeService();
    var gotClearance = false;

    final resolvedAt = cf.clearanceResolvedAt.value;
    if (resolvedAt != null && resolvedAt.isAfter(cycleStartAt)) {
      // Dio 侧在本周期内已经把 cf_clearance 重新拿到,直接重跑即可。
      gotClearance = true;
    } else if (cf.inProgressNotifier.value) {
      // Dio 侧(或其它入口)正在验证 → 等它广播 clearance 解决,不重复弹验证。
      gotClearance = await _awaitClearanceResolved(cf, after: cycleStartAt);
    } else if (cf.autoVerifyEnabled && !cf.isInCooldown) {
      // 没有进行中的验证 → coordinator 主动发起(verify 内部会复用任何期间出现
      // 的进行中验证)。bootstrap 不阻塞当前使用,完全静默:需要人工操作就放弃,
      // 由之后真正阻塞用户的请求再升级展示。
      final ok = await cf.verify(
        context: _navigatorContext,
        presentation: CfVerifyPresentation.hidden,
      );
      gotClearance = ok == true;
    }

    if (!gotClearance) {
      _log(
        'CF clearance not obtained, give up bootstrap retry reason=$reason',
        level: 'warning',
      );
      AppLogger.warning(
        'CF 未拿到新 clearance,放弃 bootstrap 重跑',
        tag: 'BrowserTrust',
      );
      return blocked;
    }

    _lastClearanceRejectedAt = null;
    // 验证结果会早于 Windows WebView2 Controller 的真实析构完成。
    // 等 CF teardown gate（内部含 1.2 秒冷却）后才能申请后台会话租约。
    await cf.waitForManualTeardown();
    _log('CF clearance obtained, force re-run bootstrap reason=$reason');
    final retry = await WebViewSessionCookieRefreshService.instance
        .ensureSynced(reason: '$reason:cf_recover', force: true);
    _log(
      'bootstrap re-run after CF: ok=${retry.ok} cfBlocked=${retry.cfBlocked} '
      'reason=$reason',
      level: retry.ok ? 'info' : 'warning',
    );
    AppLogger.warning(
      'CF 恢复后 bootstrap 重跑 ok=${retry.ok} cfBlocked=${retry.cfBlocked}',
      tag: 'BrowserTrust',
    );
    // 即使重跑仍被 CF 挡下也直接返回,不再递归(本周期只恢复一次)。
    return retry;
  }

  /// 等待 [CfChallengeService.clearanceResolvedAt] 出现晚于 [after] 的新值,
  /// 表示 cf_clearance 已被(Dio 侧或并发的手动验证)重新拿到。带超时兜底。
  Future<bool> _awaitClearanceResolved(
    CfChallengeService cf, {
    required DateTime after,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final current = cf.clearanceResolvedAt.value;
    if (current != null && current.isAfter(after)) return true;

    final completer = Completer<bool>();
    void listener() {
      final v = cf.clearanceResolvedAt.value;
      if (v != null && v.isAfter(after) && !completer.isCompleted) {
        completer.complete(true);
      }
    }

    cf.clearanceResolvedAt.addListener(listener);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      cf.clearanceResolvedAt.removeListener(listener);
    }
  }

  void _completeRequestGate(BrowserTrustRequestGate? gate, bool ready) {
    if (gate == null || gate.isCompleted) return;
    gate.complete(ready);
  }

  Future<void> _primeWebViewCookies({required String reason}) async {
    try {
      await WebViewCookiePriming.instance.prime(AppConstants.baseUrl);
    } catch (e) {
      _log(
        'WebView cookie priming failed: reason=$reason $e',
        level: 'warning',
      );
      rethrow;
    }
  }

  Future<bool> _hydratePreloadThroughWebView({
    required String reason,
    required BrowserTrustRunCancellation cancellation,
  }) async {
    final generation = AuthSession().generation;
    final cancelled = Future.any<void>([
      cancellation.whenCancelled,
      SiteWebViewRuntime.instance.interrupted,
      AuthSession().cancelToken.whenCancel.then<void>((_) {}),
    ]);
    BrowserResourceLease<SiteWebView>? lease;
    const scriptGroup = 'fluxdo_startup_snapshot';
    try {
      lease = await SiteWebViewRuntime.instance.acquire(
        exclusive: true,
        cancelled: cancelled,
      );
      if (cancellation.isCancelled || !lease.isCurrent) return false;
      await _primeWebViewCookies(reason: '$reason:webview_preload');
      if (cancellation.isCancelled || !lease.isCurrent) return false;
      final view = lease.value;
      final c = view.controller;
      await c.addUserScript(
        userScript: UserScript(
          groupName: scriptGroup,
          source: _preloadedSnapshotScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
        ),
      );
      await view.load(() => _navigateToHome(c));
      if (cancellation.isCancelled || !lease.isCurrent) return false;
      _log('startup WebView home loaded, syncing cookies reason=$reason');
      await _syncCookiesFromController(c, generation);
      if (cancellation.isCancelled || !lease.isCurrent) return false;

      final html = await _readPreloadedSnapshot(c, cancellation: cancellation);
      if (cancellation.isCancelled || !lease.isCurrent) return false;
      final hydrated =
          html != null &&
          html.isNotEmpty &&
          await _preload.hydrateFromHtml(html);
      if (cancellation.isCancelled || !lease.isCurrent) return false;
      _log(
        'startup WebView snapshot html=${html != null && html.isNotEmpty} hydrated=$hydrated reason=$reason',
        level: hydrated ? 'info' : 'warning',
      );

      final tToken = await _jar.getTToken();
      if (tToken != null && tToken.isNotEmpty) {
        if (cancellation.isCancelled || !lease.isCurrent) return false;
        _log('startup WebView session bootstrap begin reason=$reason');
        final bootstrapResult = await WebViewSessionCookieRefreshService
            .instance
            .runOnController(
              c,
              reason: '$reason:startup_webview',
              pluginCandidates: _preload.pluginCandidatesSync,
              isCancelled: () => cancellation.isCancelled || !lease!.isCurrent,
              cancellationSignal: cancelled,
            );
        if (cancellation.isCancelled || !lease.isCurrent) return false;
        final bootstrapped = bootstrapResult.ok;
        await _syncCookiesFromController(c, generation);
        if (cancellation.isCancelled || !lease.isCurrent) return false;
        final runtimeDetails = await _jar.getCookieDiagnosticsForRequest(
          Uri.parse(AppConstants.baseUrl),
          names: const {'_rt'},
        );
        final hasRuntimeCookie = runtimeDetails.any(
          (cookie) => (cookie['valueLength'] as int? ?? 0) > 0,
        );
        if (bootstrapped && hasRuntimeCookie) {
          WebViewSessionCookieRefreshService.instance.markSynced(
            reason: '$reason:startup_webview',
            tToken: await _jar.getTToken(),
            hasRuntimeCookie: hasRuntimeCookie,
          );
        }
        _log('startup WebView session bootstrap end reason=$reason');
      } else {
        _log('startup WebView session bootstrap skipped: no _t');
      }

      return hydrated;
    } catch (e) {
      _log('startup WebView preload failed: $e', level: 'warning');
      return false;
    } finally {
      if (lease != null) {
        try {
          await lease.value.controller.removeUserScriptsByGroupName(
            groupName: scriptGroup,
          );
          if (lease.isCurrent) await lease.value.resetDocument();
        } catch (_) {
          lease.invalidate();
        } finally {
          lease.release();
        }
      }
    }
  }

  Future<void> _navigateToHome(InAppWebViewController controller) async {
    await controller.loadUrl(
      urlRequest: URLRequest(
        url: WebUri(AppConstants.baseUrl),
        headers: const {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );
  }

  Future<String?> _readPreloadedSnapshot(
    InAppWebViewController controller, {
    required BrowserTrustRunCancellation cancellation,
  }) async {
    final deadline = DateTime.now().add(_domSnapshotTimeout);
    while (!cancellation.isCancelled && DateTime.now().isBefore(deadline)) {
      try {
        final raw = await controller.evaluateJavascript(
          source: 'window.__rawPreloaded || null',
        );
        if (cancellation.isCancelled) return null;
        final html = raw?.toString();
        if (html != null && html.isNotEmpty && html != 'null') {
          return html;
        }
      } catch (_) {}
      await Future.any<void>([
        Future<void>.delayed(const Duration(milliseconds: 250)),
        cancellation.whenCancelled,
      ]);
    }
    return null;
  }

  Future<void> _syncCookiesFromController(
    InAppWebViewController controller,
    int generation,
  ) async {
    await BoundarySyncService.instance.syncFromWebView(
      currentUrl: AppConstants.baseUrl,
      controller: controller,
      cookieNames: null,
      allowLowConfidenceSessionCookies: true,
      trusted: true,
      requestGeneration: generation,
    );
  }

  Future<bool> _isRequestGateTrusted() async {
    if (_clearanceRecentlyRejected) {
      _log(
        'request gate trust check: untrusted, clearance recently rejected by server',
        level: 'warning',
      );
      return false;
    }
    if (!_jar.isInitialized) {
      await _jar.initialize();
    }
    final clearance = await _jar.getCanonicalCookie('cf_clearance');
    if (clearance == null || clearance.value.isEmpty) {
      _log('request gate trust check: untrusted, no cf_clearance');
      return false;
    }
    if (!CookieJarService.matchesAppHost(clearance.domain)) {
      _log(
        'request gate trust check: untrusted, domain=${clearance.domain}',
        level: 'warning',
      );
      return false;
    }
    final expiresAt = clearance.expiresAt?.toLocal();
    if (expiresAt == null) {
      _log('request gate trust check: trusted, no expires');
      return true;
    }
    final ttl = expiresAt.difference(DateTime.now());
    final trusted = ttl >= _requestClearanceMinTtl;
    _log(
      'request gate trust check: trusted=$trusted ttl=${ttl.inSeconds}s '
      'expires=${expiresAt.toIso8601String()}',
      level: trusted ? 'info' : 'warning',
    );
    return trusted;
  }

  void _flushPendingClearanceRefresh({String reason = 'preload_settled'}) {
    final pendingReason = _pendingClearanceRefreshReason;
    _pendingClearanceRefreshReason = null;
    _startClearanceRefreshNow(
      reason: pendingReason == null ? reason : '$reason:$pendingReason',
    );
  }

  void _log(String message, {String level = 'info'}) {
    CfChallengeLogger.log('[BrowserTrust] $message', level: level);
  }

  String get _preloadedSnapshotScript => '''
(function() {
  if (window.__fluxdoPreloadedSnapshotInstalled) return;
  window.__fluxdoPreloadedSnapshotInstalled = true;

  function capture() {
    var el = document.querySelector('#data-preloaded, [data-preloaded]');
    if (!el) return false;
    var parts = [el.outerHTML];
    document.querySelectorAll('meta[name]').forEach(function(m) {
      parts.push(m.outerHTML);
    });
    var setup = document.getElementById('data-discourse-setup');
    if (setup) parts.push(setup.outerHTML);
    window.__rawPreloaded = parts.join('\\n');
    return true;
  }

  if (capture()) return;
  var observer = new MutationObserver(function() {
    if (capture()) observer.disconnect();
  });
  function observe() {
    var root = document.documentElement || document;
    observer.observe(root, { childList: true, subtree: true });
    capture();
  }
  if (document.documentElement) {
    observe();
  } else {
    document.addEventListener('DOMContentLoaded', observe, { once: true });
  }
})();
''';
}
