import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../constants.dart';
import '../utils/frame_jank_monitor.dart';
import 'app_logger.dart';
import 'cf_challenge_logger.dart';
import 'cf_challenge_service.dart';
import 'cf_clearance_refresh_service.dart';
import 'discourse/discourse_service.dart';
import 'network/cookie/boundary_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'network/cookie/webview_cookie_priming.dart';
import 'preloaded_data_service.dart';
import 'webview_session_cookie_refresh_service.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';

enum BrowserTrustPreloadPath { native, webView }

/// 浏览器信任编排器。
///
/// 负责启动/恢复阶段的浏览器态准备，避免 WebView priming、session bootstrap、
/// cf_clearance 维护、预加载请求在 main / widget 中散落。
class BrowserTrustCoordinator {
  BrowserTrustCoordinator._();
  static final BrowserTrustCoordinator instance = BrowserTrustCoordinator._();

  static const Duration _trustedClearanceMinTtl = Duration(minutes: 10);
  static const Duration _requestClearanceMinTtl = Duration(seconds: 30);
  static const Duration _webViewPreloadTimeout = Duration(seconds: 25);
  static const Duration _domSnapshotTimeout = Duration(seconds: 12);
  static const Duration _originLoadTimeout = Duration(seconds: 8);
  static const Duration _backgroundPauseDelay = Duration(seconds: 8);
  static const Duration _requestGateTimeout = Duration(seconds: 6);
  static const Duration _diagnosticBackgroundPauseDelay = Duration(seconds: 60);

  final CookieJarService _jar = CookieJarService();
  final PreloadedDataService _preload = PreloadedDataService();

  Future<void>? _activePreload;
  Future<bool>? _activeBrowserTrust;
  Future<bool>? _activeBrowserTrustGate;
  Timer? _backgroundPauseTimer;
  String? _pendingClearanceRefreshReason;

  /// 导航 context,供 bootstrap 被 CF 挡下时主动发起 CF 验证(showManualVerify)。
  BuildContext? _navigatorContext;

  /// 服务端最近一次以 CF(403/429)拒绝 cf_clearance 的时刻。在此窗口内,即使本地
  /// cf_clearance 的 TTL 仍足够,也视为不可信——避免冷启动盲信本地 clearance 再撞墙。
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

  /// 确保预加载完成。可信时走 native Dio；不可信时只在启动期临时 WebView 中
  /// 加载一次首页并复用 HTML hydrate。
  Future<void> ensurePreloaded({String reason = 'unknown'}) {
    if (_preload.isLoaded) return Future.value();

    final active = _activePreload;
    if (active != null) {
      _log('reuse active preload: reason=$reason');
      return active;
    }

    late final Future<void> future;
    future = _ensurePreloadedInternal(reason: reason).whenComplete(() {
      if (identical(_activePreload, future)) {
        _activePreload = null;
      }
    });
    _activePreload = future;
    return future;
  }

  Future<bool> ensureBrowserTrust({
    String reason = 'unknown',
    bool force = false,
  }) {
    if (!force) {
      final active = _activeBrowserTrust;
      if (active != null) return active;
    }

    final gateCompleter = Completer<bool>();
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
            _startClearanceRefreshIfLoggedIn(reason: 'browser_trust_settled');
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
    final nativeTrusted = await _isNativePreloadTrusted();
    if (nativeTrusted) {
      _lastPreloadPath = BrowserTrustPreloadPath.native;
      _log('preload path=native reason=$reason');
      try {
        await _preload.ensureLoaded();
        _log('native preload success reason=$reason');
        _startBrowserTrustAfterNativePreload(reason: reason);
        return;
      } catch (e) {
        _log(
          'trusted native preload failed, switching to startup WebView: $e',
          level: 'warning',
        );
      }
    }

    _log('preload path=startup_webview reason=$reason');
    var hydrated = false;
    try {
      hydrated = await _hydratePreloadThroughWebView(
        reason: reason,
      ).timeout(_webViewPreloadTimeout);
    } on TimeoutException {
      _log('startup WebView preload timeout', level: 'warning');
    }
    if (hydrated) {
      _lastPreloadPath = BrowserTrustPreloadPath.webView;
      _log('startup WebView preload success reason=$reason');
      _startClearanceRefreshIfLoggedIn();
      return;
    }

    _lastPreloadPath = BrowserTrustPreloadPath.native;
    _log(
      'startup WebView preload unavailable, fallback native reason=$reason',
      level: 'warning',
    );
    await _preload.ensureLoaded();
    _log('fallback native preload success reason=$reason');
    _startBrowserTrustAfterNativePreload(reason: reason);
  }

  void _startBrowserTrustAfterNativePreload({required String reason}) {
    if (!_preload.isLoaded) return;
    if (_preload.currentUserSync == null) {
      _log('skip native preload browser trust settle: not logged in');
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
    Completer<bool>? requestGate,
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
    _startClearanceRefreshIfLoggedIn();
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
      // 没有进行中的验证 → coordinator 主动发起(showManualVerify 内部会复用任何
      // 期间出现的进行中验证)。
      final ok = await cf.showManualVerify(_navigatorContext, true);
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

  void _completeRequestGate(Completer<bool>? gate, bool ready) {
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

  Future<bool> _hydratePreloadThroughWebView({required String reason}) async {
    await _primeWebViewCookies(reason: '$reason:webview_preload');
    _log('startup WebView create reason=$reason');

    var loadCompleter = Completer<void>();
    HeadlessInAppWebView? webView;

    webView = HeadlessInAppWebView(
      webViewEnvironment: io.Platform.isWindows
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialSettings: WebViewSettings.headless,
      initialUserScripts: _startupPreloadScripts(),
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      onWebViewCreated: (createdController) {
        WebViewSettings.applyWindowsHeadlessMemoryTarget(createdController);
        WebViewSettings.registerJsErrorReporter(createdController);
      },
      onLoadStop: (_, _) {
        if (!loadCompleter.isCompleted) {
          loadCompleter.complete();
        }
      },
      onReceivedError: (_, request, error) {
        _log(
          'startup WebView error: url=${request.url}, ${error.description}',
          level: 'warning',
        );
      },
    );

    try {
      // WebView 创建/销毁占用平台主线程,与掉帧时间轴对齐归因
      FrameJankMonitor.logEvent('WEBVIEW', 'BrowserTrust run(): $reason');
      await webView.run();
      final c = webView.webViewController;
      if (c == null) return false;

      if (io.Platform.isWindows) {
        await c.loadUrl(
          urlRequest: URLRequest(url: WebUri(_windowsBootstrapUrl)),
        );
        try {
          await loadCompleter.future.timeout(_originLoadTimeout);
        } on TimeoutException {
          debugPrint('[BrowserTrust] Windows origin bootstrap timeout');
        }
        await _writeStartupShell(c);
      } else {
        await c.loadData(
          data: _startupShellHtml,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }

      loadCompleter = Completer<void>();
      await _navigateToHome(c);
      await _waitForLoad(loadCompleter);
      _log('startup WebView home loaded, syncing cookies reason=$reason');
      await _syncCookiesFromController(c);

      final html = await _readPreloadedSnapshot(c);
      final hydrated =
          html != null &&
          html.isNotEmpty &&
          await _preload.hydrateFromHtml(html);
      _log(
        'startup WebView snapshot html=${html != null && html.isNotEmpty} hydrated=$hydrated reason=$reason',
        level: hydrated ? 'info' : 'warning',
      );

      final tToken = await _jar.getTToken();
      if (tToken != null && tToken.isNotEmpty) {
        _log('startup WebView session bootstrap begin reason=$reason');
        final bootstrapResult = await WebViewSessionCookieRefreshService
            .instance
            .runOnController(
              c,
              reason: '$reason:startup_webview',
              pluginCandidates: _preload.pluginCandidatesSync,
            );
        final bootstrapped = bootstrapResult.ok;
        await _syncCookiesFromController(c);
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
      try {
        await webView.dispose();
      } catch (e) {
        _log('dispose startup WebView failed: $e', level: 'warning');
      }
      FrameJankMonitor.logEvent('WEBVIEW', 'BrowserTrust dispose');
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

  Future<void> _waitForLoad(Completer<void> loadCompleter) async {
    try {
      await loadCompleter.future.timeout(_originLoadTimeout);
    } on TimeoutException {
      _log('startup WebView load timeout, continue', level: 'warning');
    }
  }

  Future<String?> _readPreloadedSnapshot(
    InAppWebViewController controller,
  ) async {
    final deadline = DateTime.now().add(_domSnapshotTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final raw = await controller.evaluateJavascript(
          source: 'window.__rawPreloaded || null',
        );
        final html = raw?.toString();
        if (html != null && html.isNotEmpty && html != 'null') {
          return html;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<void> _syncCookiesFromController(
    InAppWebViewController controller,
  ) async {
    await BoundarySyncService.instance.syncFromWebView(
      currentUrl: AppConstants.baseUrl,
      controller: controller,
      cookieNames: null,
      allowLowConfidenceSessionCookies: true,
      trusted: true,
    );
  }

  Future<bool> _isNativePreloadTrusted() async {
    if (_clearanceRecentlyRejected) {
      _log(
        'native trust check: untrusted, clearance recently rejected by server',
        level: 'warning',
      );
      return false;
    }
    if (!_jar.isInitialized) {
      await _jar.initialize();
    }
    final clearance = await _jar.getCanonicalCookie('cf_clearance');
    if (clearance == null || clearance.value.isEmpty) {
      _log('native trust check: untrusted, no cf_clearance');
      return false;
    }
    if (!CookieJarService.matchesAppHost(clearance.domain)) {
      _log(
        'native trust check: untrusted, domain=${clearance.domain}',
        level: 'warning',
      );
      return false;
    }
    final expiresAt = clearance.expiresAt?.toLocal();
    if (expiresAt == null) {
      _log('native trust check: trusted, no expires');
      return true;
    }
    final ttl = expiresAt.difference(DateTime.now());
    final trusted = ttl >= _trustedClearanceMinTtl;
    _log(
      'native trust check: trusted=$trusted ttl=${ttl.inSeconds}s expires=${expiresAt.toIso8601String()}',
    );
    return trusted;
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

  void _startClearanceRefreshIfLoggedIn({String reason = 'preload_logged_in'}) {
    if (_preload.currentUserSync != null) {
      final pendingReason = _pendingClearanceRefreshReason;
      _pendingClearanceRefreshReason = null;
      _startClearanceRefreshNow(
        reason: pendingReason == null ? reason : '$reason:$pendingReason',
      );
    } else {
      _log('skip cf_clearance refresh: not logged in');
    }
  }

  void _log(String message, {String level = 'info'}) {
    CfChallengeLogger.log('[BrowserTrust] $message', level: level);
  }

  UnmodifiableListView<UserScript> _startupPreloadScripts() {
    return UnmodifiableListView([
      ...WebViewSettings.compatPolyfillScripts,
      UserScript(
        source: _preloadedSnapshotScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
    ]);
  }

  Future<void> _writeStartupShell(InAppWebViewController controller) async {
    final html = jsonEncode(_startupShellHtml);
    await controller.evaluateJavascript(
      source:
          '''
document.open();
document.write($html);
document.close();
''',
    );
  }

  String get _windowsBootstrapUrl => '${AppConstants.baseUrl}/robots.txt';

  String get _startupShellHtml =>
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body></body></html>';

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
