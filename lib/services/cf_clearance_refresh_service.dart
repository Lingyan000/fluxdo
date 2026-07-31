import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../constants.dart';
import '../utils/frame_jank_monitor.dart';
import '../utils/scroll_busy_signal.dart';
import 'cf_challenge_logger.dart';
import 'network/cookie/boundary_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'network/cookie/webview_cookie_priming.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';

/// cf_clearance 自动续期服务。
///
/// 只维护一个轻量 Headless WebView，加载同源 Turnstile widget，让
/// Cloudflare 的 challenge-platform / rc 请求继续由 WebView 浏览器栈自己发送。
/// Dart 侧不代理、不重放 CF 请求，只在边界时机把 WebView 中新的
/// `.linux.do` cf_clearance 同步回 CookieJar。
class CfClearanceRefreshService {
  static final CfClearanceRefreshService _instance =
      CfClearanceRefreshService._internal();
  factory CfClearanceRefreshService() => _instance;
  CfClearanceRefreshService._internal();

  static const String _cookieName = 'cf_clearance';
  static const int _maxConsecutiveFailures = 3;
  static const Duration _initialTimeout = Duration(seconds: 45);

  /// cookie 兜底轮询间隔。同步的**主路径是事件驱动**(load_stop /
  /// turnstile_token / expired / error 信号即时触发 _syncAndCheckCookies),
  /// 轮询只兜"信号丢失"的漏。每次轮询是一趟平台主线程往返
  /// (CookieManager IPC),45s 一次 + health 每分钟又一次时,滚动中撞上
  /// 的概率不低(vsyncOverhead 型掉帧的来源之一);拉宽到 2 分钟后
  /// 8 分钟 stale 窗口内仍有 4 次检查机会,行为不变、平台线程流量 -75%。
  static const Duration _cookiePollInterval = Duration(minutes: 2);
  static const Duration _healthCheckInterval = Duration(minutes: 1);
  static const Duration _staleRefreshWindow = Duration(minutes: 8);
  static const Duration _restartDelay = Duration(seconds: 5);
  static const Duration _disposeGracePeriod = Duration(milliseconds: 150);

  /// 缓存的 sitekey（来自预热 HTML、登录 HTML 或 CF 403 响应体）。
  String? _sitekey;

  /// 持久 HeadlessWebView（保持 Turnstile widget 存活）。
  HeadlessInAppWebView? _headlessWebView;

  /// 当前 HeadlessWebView 对应的 controller。
  InAppWebViewController? _webViewController;

  bool _isRunning = false;
  bool _isDisposing = false;
  bool _shouldBeRunning = false;
  bool _isForeground = true;
  bool _pausedByLifecycle = false;
  bool _isSyncingCookies = false;

  /// 正在进行中的销毁 Future：供并发的 [stop] 调用等同一次销毁完成，
  /// 而不是各自提前返回、让调用方误以为 WebView 已经销毁干净。
  Future<void>? _disposingFuture;

  int _generation = 0;
  int _consecutiveFailures = 0;

  String? _lastCookieValue;
  DateTime? _lastCookieExpiresAt;
  DateTime? _runningStartedAt;
  DateTime? _lastSignalAt;
  DateTime? _lastCookieAdvanceAt;

  Timer? _initialTimer;
  Timer? _cookiePollTimer;
  Timer? _healthTimer;
  Timer? _delayedRestartTimer;
  Timer? _delayedStopTimer;

  /// 滚动挂起状态机(仅 Android):500ms 检查一次滚动繁忙信号,
  /// 见 [_updateScrollPause]
  Timer? _scrollPauseTicker;
  bool _webViewPausedForScroll = false;

  /// 获取当前缓存的 sitekey。
  String? get sitekey => _sitekey;

  void setForeground(bool foreground) {
    _isForeground = foreground;
  }

  /// 更新 sitekey（由 PreloadedDataService 或 CfChallengeInterceptor 调用）。
  void updateSitekey(String sitekey) {
    if (sitekey.isEmpty) return;
    final changed = _sitekey != sitekey;
    _sitekey = sitekey;
    if (changed) {
      CfChallengeLogger.log(
        '[CfRefresh] sitekey 已更新: ${sitekey.substring(0, 8)}...',
      );
      if (_shouldBeRunning && !_isRunning && !_isDisposing) {
        _startWebView();
      }
    }
  }

  /// 从 HTML 中提取并更新 sitekey。
  void extractAndUpdateSitekey(String html) {
    final match = RegExp(r'data-sitekey="([0-9a-zA-Zx_-]+)"').firstMatch(html);
    if (match == null) return;
    final sitekey = match.group(1);
    if (sitekey != null && sitekey.isNotEmpty) {
      updateSitekey(sitekey);
    }
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 启动服务：创建持久轻量 WebView，加载 Turnstile。
  ///
  /// 这个方法不阻塞启动链路；没有 sitekey 或没有现存 cf_clearance 时不会
  /// 主动拉起验证页，交给正常请求的 CF challenge 流程处理。
  void start() {
    // Windows 的常驻 Turnstile WebView 会让 Flutter 合成线程持续退化，
    // 最终卡死；按需 CF 验证仍由 CfChallengeService 负责。
    //
    // (2026-07-23 曾短暂解除过这个禁用，理由是 pause/resume 改为复用同一个
    // WebView、不再逐次销毁重建，"实测卡顿明显缓解"；但实机复现常驻 WebView
    // 在验证页反复收到 beforeunload/pagehide 导航事件、每次都被 fallback
    // 强行覆盖，导致连接被中途打断（"Indicates that the connection was
    // stopped"）、验证页卡死转圈——跟当初禁用它时描述的是同一类不稳定，
    // 复用 WebView 并没有根治，只是换了个故障形态。重新禁用。)
    if (io.Platform.isWindows) return;

    _shouldBeRunning = true;
    _pausedByLifecycle = false;
    if (_isRunning && !_isDisposing) return;
    if (!_isForeground) {
      CfChallengeLogger.log('[CfRefresh] 当前处于后台，延后启动');
      return;
    }

    _generation++;
    _consecutiveFailures = 0;
    _cancelDelayedTimers();

    if (_isDisposing) {
      CfChallengeLogger.log('[CfRefresh] start 已排队，等待当前 WebView 完成销毁');
      return;
    }
    _startWebView();
  }

  /// 暂停：应用进后台时只停止维护任务，保留同一个 Headless WebView。
  ///
  /// Windows WebView2 的创建/销毁与主窗口共用平台消息线程。前后台切换如果
  /// 每次都 dispose/recreate，会放大原生生命周期竞态，甚至造成窗口无响应。
  void pause() {
    _isForeground = false;
    if (!_shouldBeRunning && !_isRunning && !_isDisposing) return;
    _pausedByLifecycle = true;
    _cancelDelayedTimers();
    _cancelRuntimeTimers();
    CfChallengeLogger.log('[CfRefresh] 暂停维护，保留现有 WebView');
  }

  /// 恢复：应用回前台后复用现有 WebView，只恢复计时器与 cookie 同步。
  void resume() {
    _isForeground = true;
    if (!_pausedByLifecycle && !_shouldBeRunning) return;
    _pausedByLifecycle = false;
    _shouldBeRunning = true;
    if (_isRunning && !_isDisposing) {
      final gen = _generation;
      CfChallengeLogger.log('[CfRefresh] 恢复，复用现有 WebView');
      _startTimers(gen, includeInitialTimeout: false);
      unawaited(_syncAndCheckCookies('lifecycle_resume', gen));
      return;
    }

    _generation++;
    _consecutiveFailures = 0;
    _cancelDelayedTimers();

    CfChallengeLogger.log('[CfRefresh] 恢复');
    if (_isDisposing) {
      CfChallengeLogger.log('[CfRefresh] resume 已排队，等待当前 WebView 完成销毁');
      return;
    }
    _startWebView();
  }

  /// 停止服务。返回的 Future 在真正需要"确保 WebView 已销毁完毕再继续"的
  /// 调用点（如 [CfChallengeService.showManualVerify] 起自己的验证 WebView
  /// 之前）应该 await；其余生命周期钩子等不关心时序的调用点可以不 await
  /// （fire-and-forget，跟之前行为一致）。
  ///
  /// 之前这里是同步方法内部 `unawaited(_disposeWebView(...))`：调用方拿不到
  /// 完成信号，紧接着立刻建自己的验证 WebView，两个 WebView 短暂共存，实测
  /// 会撞上 flutter_inappwebview_windows_plugin 的一处原生崩溃（0xc0000005）。
  Future<void> stop() async {
    _pausedByLifecycle = false;
    if (!_shouldBeRunning && !_isRunning && !_isDisposing) {
      return;
    }

    if (_isDisposing && !_shouldBeRunning) {
      // 已有一次销毁在进行中：等它完成，而不是直接返回让调用方以为已销毁。
      await _disposingFuture;
      return;
    }

    _shouldBeRunning = false;
    _generation++;
    _consecutiveFailures = 0;
    _cancelDelayedTimers();

    if (_isRunning || _headlessWebView != null || _webViewController != null) {
      await _disposeWebView(reason: 'stop');
    }
    CfChallengeLogger.log('[CfRefresh] 服务已停止');
  }

  // ---------------------------------------------------------------------------
  // WebView 管理
  // ---------------------------------------------------------------------------

  void _startWebView() {
    if (_isRunning || _isDisposing || !_shouldBeRunning || !_isForeground) {
      return;
    }

    final sitekey = _sitekey;
    if (sitekey == null || sitekey.isEmpty) {
      CfChallengeLogger.log('[CfRefresh] 无 sitekey，跳过启动');
      return;
    }

    final gen = _generation;
    unawaited(() async {
      final baseline = await _readClearanceSnapshot();
      if (gen != _generation ||
          _isDisposing ||
          _isRunning ||
          !_shouldBeRunning ||
          !_isForeground) {
        return;
      }
      if (baseline == null) {
        CfChallengeLogger.log('[CfRefresh] 无 cf_clearance，跳过启动');
        return;
      }

      _rememberCookieSnapshot(baseline, markAdvanced: false);
      _runningStartedAt = DateTime.now();
      _lastCookieAdvanceAt = _runningStartedAt;
      await _createAndRunWebView(sitekey, gen);
    }());
  }

  Future<void> _createAndRunWebView(String sitekey, int gen) async {
    if (!_canStartGeneration(gen)) return;

    try {
      WebViewCookiePriming.instance.invalidate();
      await WebViewCookiePriming.instance.prime(AppConstants.baseUrl);
    } catch (e) {
      debugPrint('[CfRefresh] WebView cookie priming 失败，继续启动: $e');
      CfChallengeLogger.log('[CfRefresh] WebView cookie priming 失败，继续启动: $e');
    }
    if (!_canStartGeneration(gen)) return;

    final originLoadCompleter = Completer<void>();
    final html = _buildTurnstileHtml(sitekey);
    final webView = HeadlessInAppWebView(
      webViewEnvironment: io.Platform.isWindows
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialSettings: WebViewSettings.headlessCf,
      initialUserScripts: WebViewSettings.compatPolyfillScripts,
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      onWebViewCreated: (controller) {
        if (!_canHandleGeneration(gen)) {
          CfChallengeLogger.log(
            '[CfRefresh] 忽略过期 WebView 创建回调: gen=$gen current=$_generation',
          );
          return;
        }
        _webViewController = controller;
        WebViewSettings.applyWindowsHeadlessMemoryTarget(controller);
        WebViewSettings.registerJsErrorReporter(controller);
        _registerJavaScriptHandlers(controller, gen);
      },
      onLoadStop: (_, url) {
        if (!originLoadCompleter.isCompleted) {
          originLoadCompleter.complete();
        }
        if (_canHandleGeneration(gen)) {
          _lastSignalAt = DateTime.now();
          unawaited(_syncAndCheckCookies('load_stop', gen));
          debugPrint('[CfRefresh] WebView load stop: $url');
        }
      },
      onReceivedError: (_, request, error) {
        debugPrint(
          '[CfRefresh] WebView 错误: url=${request.url}, ${error.description}',
        );
      },
    );

    _headlessWebView = webView;
    _isRunning = true;

    try {
      CfChallengeLogger.log('[CfRefresh] 启动 Turnstile WebView');
      // WebView 创建/加载在平台主线程执行重活,与掉帧时间轴对齐归因
      FrameJankMonitor.logEvent('WEBVIEW', 'CfRefresh run() 开始');

      await webView.run();
      FrameJankMonitor.logEvent('WEBVIEW', 'CfRefresh run() 完成');
      if (!_canHandleGeneration(gen)) return;

      final controller = webView.webViewController;
      if (controller == null) {
        throw StateError('Headless WebView controller is null');
      }

      if (io.Platform.isWindows) {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(_windowsBootstrapUrl)),
        );
        try {
          await originLoadCompleter.future.timeout(const Duration(seconds: 8));
        } on TimeoutException {
          debugPrint('[CfRefresh] Windows origin bootstrap load timeout');
        }
        if (!_canHandleGeneration(gen)) return;
        await _writeTurnstileHtml(controller, html);
      } else {
        await controller.loadData(
          data: html,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }

      if (!_canHandleGeneration(gen)) return;
      _startTimers(gen);
    } catch (e, stackTrace) {
      debugPrint('[CfRefresh] WebView 启动失败: $e');
      debugPrintStack(label: '[CfRefresh] start stack', stackTrace: stackTrace);
      CfChallengeLogger.log('[CfRefresh] WebView 启动失败: $e');
      if (identical(_headlessWebView, webView)) {
        _isRunning = false;
        _headlessWebView = null;
        _webViewController = null;
        try {
          await webView.dispose();
        } catch (disposeError) {
          CfChallengeLogger.log(
            '[CfRefresh] 启动失败后的 WebView dispose 异常: $disposeError',
          );
        }
      }
      if (gen == _generation && _shouldBeRunning) {
        _recordFailure('start_failed', gen: gen, restart: true);
      }
    }
  }

  void _registerJavaScriptHandlers(InAppWebViewController controller, int gen) {
    controller.addJavaScriptHandler(
      handlerName: 'onCfRefreshSignal',
      callback: (args) {
        if (!_canHandleGeneration(gen)) return null;
        _handleRefreshSignal(args, gen);
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onTurnstileToken',
      callback: (args) {
        if (!_canHandleGeneration(gen)) return null;
        _lastSignalAt = DateTime.now();
        _cancelInitialTimer();
        final tokenLength = _readInt(args, 'length');
        CfChallengeLogger.log(
          '[CfRefresh] Turnstile token 回调 len=$tokenLength',
        );
        unawaited(_syncAndCheckCookies('turnstile_token', gen));
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onTurnstileExpired',
      callback: (_) {
        if (!_canHandleGeneration(gen)) return null;
        _lastSignalAt = DateTime.now();
        CfChallengeLogger.log('[CfRefresh] Turnstile token 已过期，等待自动刷新');
        unawaited(_syncAndCheckCookies('turnstile_expired', gen));
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onTurnstileError',
      callback: (args) {
        if (!_canHandleGeneration(gen)) return null;
        _lastSignalAt = DateTime.now();
        final error = args.isNotEmpty ? args.first?.toString() : 'unknown';
        CfChallengeLogger.log('[CfRefresh] Turnstile 错误: $error');
        unawaited(_syncAndCheckCookies('turnstile_error', gen));
        _recordFailure('turnstile_error:$error', gen: gen, restart: true);
        return null;
      },
    );
  }

  void _handleRefreshSignal(List<dynamic> args, int gen) {
    final data = _readMap(args);
    final type = data['type']?.toString() ?? 'unknown';
    _lastSignalAt = DateTime.now();

    if (type == 'api_ready' || type.endsWith(':start')) {
      _cancelInitialTimer();
    }
  }

  Future<void> _writeTurnstileHtml(
    InAppWebViewController controller,
    String html,
  ) async {
    final encodedHtml = jsonEncode(html);
    await controller.evaluateJavascript(
      source:
          '''
document.open();
document.write($encodedHtml);
document.close();
''',
    );
  }

  /// stale_refresh 的轻量恢复:**原地重载** Turnstile 页面,不销毁重建
  /// WebView 实例。
  ///
  /// 旧路径(dispose → priming 逐 cookie 三段式 → HeadlessInAppWebView.run
  /// → loadData)每一步都是平台主线程的重活,滚动中撞上 = vsyncOverhead
  /// 型掉帧(诊断实测 ov 50~97ms)。重载只有一次 loadData/loadUrl 调用,
  /// 平台线程占用降一个量级;cookie 环境未变,无需重新 priming。
  ///
  /// 连续多次重载仍无 cookie 更新(说明不是页面卡死而是环境问题)才
  /// 退回完全重建,由 [_recordFailure] 的既有退避逻辑接管。
  static const int _maxReloadsBeforeRestart = 2;
  int _staleReloads = 0;

  Future<void> _reloadTurnstile(String reason, {required int gen}) async {
    if (!_canHandleGeneration(gen)) return;
    final controller = _webViewController;
    final sitekey = _sitekey;
    if (controller == null || sitekey == null || sitekey.isEmpty) {
      _scheduleRestart(reason, gen: gen);
      return;
    }
    if (_staleReloads >= _maxReloadsBeforeRestart) {
      CfChallengeLogger.log('[CfRefresh] 原地重载 $_staleReloads 次仍无更新,退回完全重建');
      _staleReloads = 0;
      _scheduleRestart(reason, gen: gen);
      return;
    }
    _staleReloads++;
    FrameJankMonitor.logEvent('WEBVIEW', 'CfRefresh reload($reason)');

    try {
      final html = _buildTurnstileHtml(sitekey);
      if (io.Platform.isWindows) {
        await _writeTurnstileHtml(controller, html);
      } else {
        await controller.loadData(
          data: html,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }
      // 重载视为一次活动,把 stale 窗口锚点前移,避免下个 health tick
      // 立即再次触发
      _lastCookieAdvanceAt = DateTime.now();
    } catch (e) {
      CfChallengeLogger.log('[CfRefresh] 原地重载失败,退回完全重建: $e');
      _staleReloads = 0;
      _scheduleRestart(reason, gen: gen);
    }
  }

  Future<void> _disposeWebView({required String reason}) {
    if (_isDisposing) {
      CfChallengeLogger.log('[CfRefresh] 忽略重复 dispose 请求: $reason');
      return _disposingFuture ?? Future.value();
    }
    final future = _disposeWebViewImpl(reason);
    _disposingFuture = future;
    future.whenComplete(() {
      if (identical(_disposingFuture, future)) _disposingFuture = null;
    });
    return future;
  }

  Future<void> _disposeWebViewImpl(String reason) async {
    _isDisposing = true;
    _isRunning = false;
    _isSyncingCookies = false;
    _cancelRuntimeTimers();

    final wv = _headlessWebView;
    final controller = _webViewController;
    _headlessWebView = null;
    _webViewController = null;

    CfChallengeLogger.log(
      '[CfRefresh] disposing begin: reason=$reason, gen=$_generation',
    );

    try {
      if (controller != null) {
        controller.removeJavaScriptHandler(handlerName: 'onCfRefreshSignal');
        controller.removeJavaScriptHandler(handlerName: 'onTurnstileToken');
        controller.removeJavaScriptHandler(handlerName: 'onTurnstileExpired');
        controller.removeJavaScriptHandler(handlerName: 'onTurnstileError');
      }
    } catch (e) {
      CfChallengeLogger.log('[CfRefresh] 移除 JS handlers 异常: $e');
    }

    if (controller != null || wv != null) {
      await Future.delayed(_disposeGracePeriod);
    }

    try {
      await wv?.dispose();
    } catch (e) {
      CfChallengeLogger.log('[CfRefresh] WebView dispose 异常: $e');
    } finally {
      _isDisposing = false;
    }
    FrameJankMonitor.logEvent('WEBVIEW', 'CfRefresh dispose: $reason');

    CfChallengeLogger.log(
      '[CfRefresh] disposing end: reason=$reason, shouldRun=$_shouldBeRunning',
    );

    if (_shouldBeRunning && !_isRunning && _isForeground) {
      CfChallengeLogger.log('[CfRefresh] dispose 后按期望状态重启 WebView');
      _startWebView();
    }
  }

  // ---------------------------------------------------------------------------
  // Cookie 同步与健康检查
  // ---------------------------------------------------------------------------

  void _startTimers(int gen, {bool includeInitialTimeout = true}) {
    _cancelRuntimeTimers();

    if (includeInitialTimeout) {
      _initialTimer = Timer(_initialTimeout, () {
        if (!_canHandleGeneration(gen)) return;
        CfChallengeLogger.log('[CfRefresh] Turnstile 初始运行超时，准备重建');
        unawaited(_syncAndCheckCookies('initial_timeout', gen));
        _recordFailure('initial_timeout', gen: gen, restart: true);
      });
    }

    _cookiePollTimer = Timer.periodic(_cookiePollInterval, (_) {
      if (!_canHandleGeneration(gen)) {
        _cookiePollTimer?.cancel();
        return;
      }
      // 滚动中让路:cookie 同步是一趟平台主线程 IPC,与 vsync 分发
      // 同线程;这是兜底轮询,顺延一轮无影响
      if (ScrollBusySignal.isBusy) return;
      unawaited(_syncAndCheckCookies('poll', gen));
    });

    _healthTimer = Timer.periodic(_healthCheckInterval, (_) async {
      if (!_canHandleGeneration(gen)) {
        _healthTimer?.cancel();
        return;
      }
      // 滚动中让路(同 poll:stale 判定顺延一轮无影响)
      if (ScrollBusySignal.isBusy) return;
      // 平时不做 WebView cookie 同步(那是一趟平台主线程 IPC,主路径
      // 已由 JS 信号事件驱动 + 2min 兜底轮询覆盖);只在逼近 stale 窗口
      // 时同步一次拿最新状态,确认真 stale 才重载。
      final anchor = _lastCookieAdvanceAt ?? _runningStartedAt;
      if (anchor == null) return;
      var idle = DateTime.now().difference(anchor);
      if (idle < _staleRefreshWindow) return;

      await _syncAndCheckCookies('health', gen);
      if (!_canHandleGeneration(gen)) return;

      final freshAnchor = _lastCookieAdvanceAt ?? _runningStartedAt;
      if (freshAnchor == null) return;
      idle = DateTime.now().difference(freshAnchor);
      if (idle >= _staleRefreshWindow) {
        final lastSignalAgo = _lastSignalAt == null
            ? 'never'
            : '${DateTime.now().difference(_lastSignalAt!).inSeconds}s';
        CfChallengeLogger.log(
          '[CfRefresh] 长时间未观察到 cf_clearance 更新，原地重载 Turnstile '
          '(idle=${idle.inSeconds}s, lastSignalAgo=$lastSignalAgo)',
        );
        unawaited(_reloadTurnstile('stale_refresh', gen: gen));
      }
    });

    // 滚动窗口内把 headless WebView 挂起(Android onPause:暂停 JS 定时
    // 器与渲染,不销毁实例):Turnstile 是活网页,常驻 JS 把平台主线程
    // 烧到 60%+ 单核(生产 CPU 采样),而 vsync 分发/触摸事件与其同
    // 线程。滚动繁忙即挂起、静默 ~1s 后恢复,JS 信号与刷新逻辑 resume
    // 后自然补上。初始 Turnstile 运行期(_initialTimer 未清)只恢复不
    // 挂起,避免把首次验证拖到超时误判重建。
    if (io.Platform.isAndroid) {
      _scrollPauseTicker = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) {
          if (!_canHandleGeneration(gen)) {
            _scrollPauseTicker?.cancel();
            return;
          }
          unawaited(_updateScrollPause());
        },
      );
    }
  }

  /// 滚动繁忙 ↔ 静默的 WebView 挂起切换(仅 Android,由
  /// [_scrollPauseTicker] 驱动)。pause/resume 是单实例 onPause/onResume,
  /// 一次轻量平台调用;失败时复位标记,避免卡死在挂起态。
  Future<void> _updateScrollPause() async {
    final controller = _webViewController;
    if (controller == null) return;
    final wantPause = ScrollBusySignal.isBusy && _initialTimer == null;
    if (wantPause == _webViewPausedForScroll) return;
    try {
      if (wantPause) {
        _webViewPausedForScroll = true;
        await controller.pause();
      } else {
        _webViewPausedForScroll = false;
        await controller.resume();
      }
    } catch (e) {
      _webViewPausedForScroll = false;
      CfChallengeLogger.log('[CfRefresh] 滚动挂起/恢复失败: $e');
    }
  }

  Future<bool> _syncAndCheckCookies(String reason, int gen) async {
    if (!_canHandleGeneration(gen) || _isSyncingCookies) return false;
    final controller = _webViewController;
    if (controller == null) return false;

    _isSyncingCookies = true;
    try {
      await BoundarySyncService.instance.syncFromWebView(
        currentUrl: AppConstants.baseUrl,
        controller: controller,
        cookieNames: const {_cookieName},
        trusted: true,
      );

      if (!_canHandleGeneration(gen)) return false;
      final snapshot = await _readClearanceSnapshot();
      if (snapshot == null) {
        if (reason != 'poll' && reason != 'health') {
          CfChallengeLogger.log('[CfRefresh] 同步后未找到 cf_clearance: $reason');
        }
        return false;
      }

      final advanced = _isCookieAdvanced(snapshot);
      _rememberCookieSnapshot(snapshot, markAdvanced: advanced);

      if (advanced) {
        _cancelInitialTimer();
        _consecutiveFailures = 0;
        _staleReloads = 0;
        CfChallengeLogger.log(
          '[CfRefresh] cf_clearance 已更新: reason=$reason '
          'expires=${snapshot.expiresAt?.toIso8601String() ?? '-'}',
        );
      } else if (reason != 'poll' && reason != 'health') {
        CfChallengeLogger.log(
          '[CfRefresh] cf_clearance 未变化: reason=$reason '
          'expires=${snapshot.expiresAt?.toIso8601String() ?? '-'}',
        );
      }
      return advanced;
    } catch (e) {
      if (reason != 'poll' && reason != 'health') {
        CfChallengeLogger.log('[CfRefresh] cookie 同步失败: reason=$reason $e');
      }
      return false;
    } finally {
      _isSyncingCookies = false;
    }
  }

  Future<_ClearanceSnapshot?> _readClearanceSnapshot() async {
    final cookie = await CookieJarService().getCanonicalCookie(_cookieName);
    if (cookie == null || cookie.value.isEmpty) return null;
    if (!CookieJarService.matchesAppHost(cookie.domain)) return null;
    final expiresAt = cookie.expiresAt?.toLocal();
    if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
      return null;
    }
    return _ClearanceSnapshot(
      value: cookie.value,
      expiresAt: expiresAt,
      domain: cookie.domain,
    );
  }

  bool _isCookieAdvanced(_ClearanceSnapshot snapshot) {
    final previousValue = _lastCookieValue;
    final previousExpires = _lastCookieExpiresAt;

    if (previousValue != null && snapshot.value != previousValue) {
      return true;
    }
    if (previousExpires != null &&
        snapshot.expiresAt != null &&
        snapshot.expiresAt!.isAfter(
          previousExpires.add(const Duration(seconds: 30)),
        )) {
      return true;
    }
    if (previousExpires == null && snapshot.expiresAt != null) {
      return true;
    }
    return false;
  }

  void _rememberCookieSnapshot(
    _ClearanceSnapshot snapshot, {
    required bool markAdvanced,
  }) {
    _lastCookieValue = snapshot.value;
    _lastCookieExpiresAt = snapshot.expiresAt;
    if (markAdvanced) {
      _lastCookieAdvanceAt = DateTime.now();
    }
  }

  void _recordFailure(
    String reason, {
    required int gen,
    required bool restart,
  }) {
    if (gen != _generation || !_shouldBeRunning) return;

    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      CfChallengeLogger.log(
        '[CfRefresh] 连续失败 $_consecutiveFailures 次，停止自动续期: $reason',
      );
      _scheduleStop(reason, gen: gen);
      return;
    }

    if (restart) {
      _scheduleRestart(reason, gen: gen);
    }
  }

  // ---------------------------------------------------------------------------
  // 调度工具
  // ---------------------------------------------------------------------------

  bool _canStartGeneration(int gen) {
    return gen == _generation &&
        !_isRunning &&
        !_isDisposing &&
        _shouldBeRunning &&
        _isForeground;
  }

  bool _canHandleGeneration(int gen) {
    return gen == _generation && _isRunning && !_isDisposing && _isForeground;
  }

  void _scheduleRestart(String reason, {required int gen}) {
    _delayedRestartTimer?.cancel();
    _delayedRestartTimer = Timer(_restartDelay, () {
      if (gen != _generation ||
          !_shouldBeRunning ||
          _isDisposing ||
          !_isForeground) {
        CfChallengeLogger.log(
          '[CfRefresh] 取消延迟 restart: reason=$reason, gen=$gen '
          'current=$_generation running=$_isRunning disposing=$_isDisposing',
        );
        return;
      }
      CfChallengeLogger.log('[CfRefresh] 执行延迟 restart: $reason');
      if (_isRunning) {
        _generation++;
        unawaited(_disposeWebView(reason: 'restart:$reason'));
      } else {
        _startWebView();
      }
    });
  }

  void _scheduleStop(String reason, {required int gen}) {
    _delayedStopTimer?.cancel();
    _delayedStopTimer = Timer(_disposeGracePeriod, () {
      if (gen != _generation || _isDisposing || !_isRunning) {
        CfChallengeLogger.log(
          '[CfRefresh] 取消延迟 stop: reason=$reason, gen=$gen '
          'current=$_generation running=$_isRunning disposing=$_isDisposing',
        );
        return;
      }
      CfChallengeLogger.log('[CfRefresh] 执行延迟 stop: $reason');
      stop();
    });
  }

  void _cancelInitialTimer() {
    _initialTimer?.cancel();
    _initialTimer = null;
  }

  void _cancelRuntimeTimers() {
    _initialTimer?.cancel();
    _initialTimer = null;
    _cookiePollTimer?.cancel();
    _cookiePollTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    _scrollPauseTicker?.cancel();
    _scrollPauseTicker = null;
    // 旧实例的挂起态随销毁消失;新实例从 resumed 起步
    _webViewPausedForScroll = false;
  }

  void _cancelDelayedTimers() {
    _delayedRestartTimer?.cancel();
    _delayedRestartTimer = null;
    _delayedStopTimer?.cancel();
    _delayedStopTimer = null;
  }

  Map<String, dynamic> _readMap(List<dynamic> args) {
    if (args.isEmpty || args.first is! Map) return const {};
    return Map<String, dynamic>.from(args.first as Map);
  }

  int _readInt(List<dynamic> args, String key) {
    final value = _readMap(args)[key];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String get _windowsBootstrapUrl => '${AppConstants.baseUrl}/robots.txt';

  // ---------------------------------------------------------------------------
  // HTML 模板
  // ---------------------------------------------------------------------------

  String _buildTurnstileHtml(String sitekey) {
    final encodedSitekey = jsonEncode(sitekey);
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 320px;
      min-height: 100px;
      background: transparent;
      overflow: hidden;
    }
    #turnstile-container {
      width: 300px;
      min-height: 65px;
    }
  </style>
  <script>
    (function() {
      if (window.__fluxdoCfRefreshInstalled) return;
      window.__fluxdoCfRefreshInstalled = true;

      function call(name, payload) {
        try {
          window.flutter_inappwebview.callHandler(name, payload || {});
        } catch (_) {}
      }

      function signal(type, detail) {
        detail = detail || {};
        detail.type = type;
        detail.href = location.href;
        detail.ts = Date.now();
        call('onCfRefreshSignal', detail);
      }

      window.__fluxdoTurnstileReady = function() {
        signal('api_ready');
        try {
          if (!window.turnstile || typeof window.turnstile.render !== 'function') {
            call('onTurnstileError', 'turnstile api missing');
            return;
          }
          window.__fluxdoTurnstileWidgetId = window.turnstile.render(
            '#turnstile-container',
            {
              sitekey: $encodedSitekey,
              appearance: 'interaction-only',
              'refresh-expired': 'auto',
              'refresh-timeout': 'auto',
              callback: function(token) {
                signal('token', { length: token ? token.length : 0 });
                call('onTurnstileToken', { length: token ? token.length : 0 });
              },
              'expired-callback': function() {
                signal('expired');
                call('onTurnstileExpired', {});
              },
              'timeout-callback': function() {
                signal('timeout');
                call('onTurnstileError', 'timeout');
              },
              'error-callback': function(error) {
                signal('error', { error: String(error || 'unknown') });
                call('onTurnstileError', String(error || 'unknown'));
              },
              'unsupported-callback': function() {
                signal('unsupported');
                call('onTurnstileError', 'unsupported');
              }
            }
          );
          signal('rendered');
        } catch (e) {
          call('onTurnstileError', String(e && e.message ? e.message : e));
        }
      };
    })();
  </script>
  <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=__fluxdoTurnstileReady" async defer></script>
</head>
<body>
  <div id="turnstile-container"></div>
</body>
</html>
''';
  }
}

class _ClearanceSnapshot {
  const _ClearanceSnapshot({
    required this.value,
    required this.expiresAt,
    required this.domain,
  });

  final String value;
  final DateTime? expiresAt;
  final String? domain;
}
