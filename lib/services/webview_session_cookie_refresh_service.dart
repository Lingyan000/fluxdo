import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../constants.dart';
import '../utils/frame_jank_monitor.dart';
import 'log/log_writer.dart';
import 'network/cookie/boundary_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'network/cookie/webview_cookie_priming.dart';
import 'preloaded_data_service.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';

/// WebView session bootstrap 的执行结果。
///
/// 在成功/失败之外额外携带"是否被 Cloudflare 挡下(403/429)"的信号,
/// 供 [BrowserTrustCoordinator] 区分"普通失败"与"CF 失败",据此触发统一的
/// CF 处理(等待/发起验证 → force 重跑 bootstrap),避免 bootstrap 这条线把
/// CF 403 静默吞掉、与 Dio 侧的 CF 自愈各自为政。
class SessionBootstrapResult {
  const SessionBootstrapResult.success()
    : ok = true,
      cfBlocked = false,
      status = null,
      phase = null;

  const SessionBootstrapResult.failure({
    this.cfBlocked = false,
    this.status,
    this.phase,
  }) : ok = false;

  /// bootstrap 是否成功(fingerprint POST 成功且 session cookie 已落 jar)。
  final bool ok;

  /// 失败是否由 CF 挑战(403/429)导致。
  final bool cfBlocked;

  /// 触发失败的 HTTP 状态码(如有)。
  final int? status;

  /// 失败阶段(home/post/exception/timeout/controller 等),便于诊断。
  final String? phase;

  @override
  String toString() =>
      'SessionBootstrapResult(ok: $ok, cfBlocked: $cfBlocked, '
      'status: $status, phase: $phase)';
}

/// 让 WebView 浏览器会话与 native CookieJar 保持一致。
///
/// 一些站点会在登录后的普通页面里由 JS/XHR 产生额外的 HttpOnly/session
/// cookie。native HTTP 无法自行生成这些 cookie，也不应该按名字伪造。
///
/// 这里不加载完整 Discourse/Ember 前端，而是在同源轻量文档中运行站点的
/// 会话 bootstrap 脚本。当前 linux.do 的 bootstrap 来自 fingerprint 插件:
/// 动态发现插件包后，只抽出 FingerprintJS 与 endpoint，用 WebView 自己的
/// JS/网络栈 POST，让服务端自然产生 HttpOnly session cookie。随后全量同步
/// WebView cookie store 回 CookieJar。
class WebViewSessionCookieRefreshService {
  WebViewSessionCookieRefreshService._();
  static final WebViewSessionCookieRefreshService instance =
      WebViewSessionCookieRefreshService._();

  static const Duration _attemptCooldown = Duration(seconds: 45);
  static const Duration _successTtl = Duration(minutes: 15);
  static const Duration _bootstrapTimeout = Duration(seconds: 18);

  /// 非 force 触发源的最小尝试间隔,防止两个独立触发源背靠背各起一个
  /// headless WebView(见 ensureSynced 里的用法注释)。故意很短:被这道
  /// 闸门拦下的那次不会重试,只是这个窗口错过同步,下一次自然触发
  /// (dio 请求失败/resume 等)几秒后照常能跑。
  ///
  /// force 请求穿透本闸门:闸门要防的是「非协调」触发源撞车,而 force
  /// 只有两个来源(登录成功 / CF 恢复),都是单点串行编排——尤其
  /// cf_recover:coordinator 先跑一次 ensureSynced(写入 _lastAttemptAt)
  /// → 被 CF 挡 → 用户完成验证(自动过盾常 <3s)→ force 重跑。若被
  /// 本闸门吞掉,coordinator 不重试,后续自然触发全要过失败退避
  /// (45s 起步指数放大)——正是 12b78389 修掉的「CF 后持续 403」死局
  /// 的时序变体。force 路径对背靠背的贡献本就被 waitForManualTeardown
  /// 的 1.2s 冷却 + _activeRefresh join 两道既有机制压着。
  static const Duration _minAttemptSpacing = Duration(seconds: 3);

  /// 连续失败的最大冷却(与 _successTtl 对齐):端点 404 等"重试也不会好"
  /// 的失败,不该比成功路径(15min 免打扰)更频繁地烧 WebView。
  static const Duration _maxFailureCooldown = Duration(minutes: 15);

  final CookieJarService _jar = CookieJarService();

  Future<SessionBootstrapResult>? _activeRefresh;
  DateTime? _lastAttemptAt;
  DateTime? _lastSuccessAt;
  String? _lastSuccessToken;

  /// 连续失败次数(成功清零)。每次 bootstrap = 一整个 headless WebView
  /// 生命周期 + FingerprintJS 全套采集,失败按 45s 固定冷却重试曾造成
  /// 生产事故:站点轮换 fingerprint 端点后旧端点永远 404,用户挂在帖子页
  /// 的周期 POST(drafts/presence/timings)每分钟拉起一次完整 bootstrap,
  /// 数小时不停 → CPU 常驻 100%+、打字/滚动被平台主线程 WebView
  /// 创建销毁反复打断。指数退避把"永不成功"场景压到与成功 TTL 同频。
  int _failureStreak = 0;

  /// 上次 fingerprint 上报 404 → 判定弹药过期(预加载插件候选 / WebView
  /// 缓存里的旧插件 JS 提取出的端点已被站点轮换)。置位后下一次 bootstrap
  /// 绕过注入候选并以 no-cache 拉插件 JS,强制新鲜 discover;成功即复位。
  bool _forceFreshPlugin = false;

  /// 当前失败退避冷却:45s → 90s → 3m → 6m → 12m → 15m 封顶。
  Duration get _effectiveCooldown {
    if (_failureStreak <= 1) return _attemptCooldown;
    final shifted = _attemptCooldown * (1 << (_failureStreak - 1).clamp(0, 5));
    return shifted > _maxFailureCooldown ? _maxFailureCooldown : shifted;
  }

  DateTime? get lastSuccessAt => _lastSuccessAt;

  void markSynced({
    String reason = 'external',
    String? tToken,
    bool? hasRuntimeCookie,
  }) {
    _lastSuccessAt = DateTime.now();
    _lastSuccessToken = tToken;
    // 外部路径确认同步成功 = 会话链路健康,失败退避一并复位。
    _failureStreak = 0;
    _logEnsureEvent(
      event: 'webview_session_sync_marked',
      reason: reason,
      level: 'info',
      extra: {
        'hasRuntimeCookie': ?hasRuntimeCookie,
        'tokenBound': tToken != null && tToken.isNotEmpty,
      },
    );
  }

  bool hasFreshSyncForToken(String? tToken) {
    final lastSuccessAt = _lastSuccessAt;
    return tToken != null &&
        tToken.isNotEmpty &&
        _lastSuccessToken == tToken &&
        lastSuccessAt != null &&
        DateTime.now().difference(lastSuccessAt) < _successTtl;
  }

  /// 登出复位:换账号 = 新浏览器会话,下一个登录会话需要重新 bootstrap。
  /// 同时清掉失败退避与 fresh 标记,新会话从干净状态开始。
  void resetSessionState({String reason = 'logout'}) {
    _lastSuccessAt = null;
    _lastSuccessToken = null;
    _lastAttemptAt = null;
    _failureStreak = 0;
    _forceFreshPlugin = false;
    _logEnsureEvent(
      event: 'webview_session_sync_reset',
      reason: reason,
      level: 'info',
    );
  }

  /// 确保当前进程已经让 WebView 登录页面跑过一次并同步 cookie。
  Future<SessionBootstrapResult> ensureSynced({
    String reason = 'unknown',
    bool force = false,
  }) async {
    final startedAt = DateTime.now();
    _logEnsureEvent(
      event: 'webview_session_sync_started',
      reason: reason,
      extra: {'force': force},
    );

    if (!_jar.isInitialized) {
      await _jar.initialize();
    }

    final tToken = await _jar.getTToken();
    if (tToken == null || tToken.isEmpty) {
      _logEnsureEvent(
        event: 'webview_session_sync_skipped',
        reason: reason,
        level: 'info',
        extra: {'skipReason': 'no_t'},
      );
      return const SessionBootstrapResult.failure(phase: 'no_t');
    }

    // fingerprint 上报对齐浏览器语义:每次完整页面加载跑一次(SPA 内路由
    // 切换不重跑,标签页挂几天也不重跑)→ app 的对应物 = 每「进程 × 登录
    // 会话」一次。此前按 15min TTL 反复重跑:挂后台回来 / 挂机后的首个
    // 请求都会白烧一整个 headless WebView(mac 上 6~20s,创建销毁抢平台
    // 主线程,恰是"长时间挂后台回来卡"的来源之一)。产物 _rt/_forum_session
    // 不随 _t 轮换失效;换账号由 logout → [resetSessionState] 复位,
    // CF recover 走 force,失败补跑由退避链继续。
    if (!force && _lastSuccessAt != null) {
      _logEnsureEvent(
        event: 'webview_session_sync_skipped',
        reason: reason,
        level: 'info',
        extra: {
          'skipReason': 'synced_this_session',
          'lastSuccessAgeMs': DateTime.now()
              .difference(_lastSuccessAt!)
              .inMilliseconds,
        },
      );
      return const SessionBootstrapResult.success();
    }

    final active = _activeRefresh;
    if (active != null) {
      _logEnsureEvent(
        event: 'webview_session_sync_join_active',
        reason: reason,
        level: 'info',
      );
      return active;
    }

    final now = DateTime.now();
    final lastAttemptAt = _lastAttemptAt;
    final cooldown = _effectiveCooldown;
    if (!force &&
        lastAttemptAt != null &&
        now.difference(lastAttemptAt) < cooldown) {
      _logEnsureEvent(
        event: 'webview_session_sync_skipped',
        reason: reason,
        level: 'info',
        extra: {
          'skipReason': 'attempt_cooldown',
          'lastAttemptAgeMs': now.difference(lastAttemptAt).inMilliseconds,
          if (_failureStreak > 0) 'failureStreak': _failureStreak,
          if (_failureStreak > 0) 'cooldownMs': cooldown.inMilliseconds,
        },
      );
      return const SessionBootstrapResult.failure(phase: 'attempt_cooldown');
    }
    // 非 force 的最小间隔闸门:两条独立触发源(比如同时失败的多个 dio
    // 请求各自的 ensureInBackground)有概率在几乎同一时刻都通过了各自
    // 的判断,背靠背各起一个 headless WebView——每个 WebView 创建/销毁
    // 都占平台主线程(见上面 FrameJankMonitor 标注的掉帧点),GPU 贴图
    // 资源短时间内高频创建销毁还牵出过一次原生层崩溃(Skia
    // GrResourceCache 内部断言,dump 定位到的)。跟失败退避冷却分开算,
    // 这里只是"几秒内最多真正跑一次"的闸门;force 穿透的理由见
    // _minAttemptSpacing 注释(cf_recover 被吞会复活 CF 后持续 403)。
    if (!force &&
        lastAttemptAt != null &&
        now.difference(lastAttemptAt) < _minAttemptSpacing) {
      _logEnsureEvent(
        event: 'webview_session_sync_skipped',
        reason: reason,
        level: 'info',
        extra: {
          'skipReason': 'min_spacing',
          'lastAttemptAgeMs': now.difference(lastAttemptAt).inMilliseconds,
          'force': force,
        },
      );
      return const SessionBootstrapResult.failure(phase: 'min_spacing');
    }

    _lastAttemptAt = now;
    late final Future<SessionBootstrapResult> future;
    future = _refreshBrowserSession(reason: reason)
        .then((result) {
          // 失败退避计数:这里只会看到真正执行过的尝试(no_t / TTL /
          // cooldown / join 都在上面早退,不进本回调)。
          if (result.ok) {
            _failureStreak = 0;
          } else {
            _failureStreak++;
          }
          _logEnsureEvent(
            event: 'webview_session_sync_completed',
            reason: reason,
            level: result.ok ? 'info' : 'warning',
            extra: {
              'ok': result.ok,
              if (result.cfBlocked) 'cfBlocked': true,
              if (result.status != null) 'status': result.status,
              if (!result.ok) 'failureStreak': _failureStreak,
              'elapsedMs': DateTime.now().difference(startedAt).inMilliseconds,
            },
          );
          return result;
        })
        .whenComplete(() {
          if (identical(_activeRefresh, future)) {
            _activeRefresh = null;
          }
        });
    _activeRefresh = future;
    return future;
  }

  void ensureInBackground({String reason = 'unknown', bool force = false}) {
    unawaited(
      ensureSynced(reason: reason, force: force).catchError((Object e) {
        debugPrint('[WebViewSessionSync] 后台同步失败: $e');
        return const SessionBootstrapResult.failure(phase: 'exception');
      }),
    );
  }

  Future<SessionBootstrapResult> _refreshBrowserSession({
    required String reason,
  }) async {
    debugPrint('[WebViewSessionSync] 开始运行轻量会话 bootstrap: reason=$reason');

    try {
      WebViewCookiePriming.instance.invalidate();
      await WebViewCookiePriming.instance.prime(AppConstants.baseUrl);
    } catch (e) {
      debugPrint('[WebViewSessionSync] WebView cookie priming 失败，继续尝试: $e');
    }

    final loadCompleter = Completer<void>();
    HeadlessInAppWebView? webView;
    InAppWebViewController? controller;

    Future<void> syncCookies() async {
      final c = controller;
      if (c == null) return;

      await BoundarySyncService.instance.syncFromWebView(
        currentUrl: AppConstants.baseUrl,
        controller: c,
        cookieNames: null,
        allowLowConfidenceSessionCookies: true,
        trusted: true,
      );
    }

    webView = HeadlessInAppWebView(
      webViewEnvironment: io.Platform.isWindows
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialSettings: WebViewSettings.headless,
      initialUserScripts: WebViewSettings.compatPolyfillScripts,
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      onWebViewCreated: (createdController) {
        controller = createdController;
        WebViewSettings.applyWindowsHeadlessMemoryTarget(createdController);
        WebViewSettings.registerJsErrorReporter(createdController);
      },
      onLoadStop: (_, _) {
        if (!loadCompleter.isCompleted) {
          loadCompleter.complete();
        }
      },
      onReceivedError: (_, request, error) {
        debugPrint(
          '[WebViewSessionSync] WebView 错误: url=${request.url}, ${error.description}',
        );
      },
    );

    try {
      // WebView 创建/销毁占用平台主线程,与掉帧时间轴对齐归因
      FrameJankMonitor.logEvent('WEBVIEW', 'SessionSync run(): $reason');
      await webView.run();
      final c = webView.webViewController;
      if (c == null) {
        debugPrint('[WebViewSessionSync] Headless WebView controller 为空');
        return const SessionBootstrapResult.failure(phase: 'controller');
      }

      if (io.Platform.isWindows) {
        await c.loadUrl(
          urlRequest: URLRequest(url: WebUri(_windowsBootstrapUrl)),
        );
      } else {
        await c.loadData(
          data: _bootstrapHtml,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }

      try {
        await loadCompleter.future.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        debugPrint('[WebViewSessionSync] 轻量 bootstrap 文档加载等待超时，继续尝试');
      }

      if (io.Platform.isWindows) {
        await _writeBootstrapHtml(c);
      }

      final bootstrap = await runOnController(
        c,
        reason: reason,
        pluginCandidates: PreloadedDataService().pluginCandidatesSync,
      );
      if (!bootstrap.ok) {
        await syncCookies();
        await logCookieSummary(reason: reason, bootstrapOk: false);
        debugPrint('[WebViewSessionSync] 站点会话 bootstrap 未完成');
        return SessionBootstrapResult.failure(
          cfBlocked: bootstrap.cfBlocked,
          status: bootstrap.status,
          phase: bootstrap.phase,
        );
      }

      await syncCookies();
      await logCookieSummary(reason: reason, bootstrapOk: true);
      final tToken = await _jar.getTToken();
      if (tToken != null && tToken.isNotEmpty) {
        _lastSuccessAt = DateTime.now();
        _lastSuccessToken = tToken;
        debugPrint('[WebViewSessionSync] 浏览器会话 cookie 已同步');
        return const SessionBootstrapResult.success();
      }

      debugPrint('[WebViewSessionSync] 同步后未找到有效 _t');
      return const SessionBootstrapResult.failure(phase: 'no_t_after_sync');
    } catch (e) {
      debugPrint('[WebViewSessionSync] 刷新浏览器会话 cookie 失败: $e');
      return const SessionBootstrapResult.failure(phase: 'exception');
    } finally {
      try {
        await webView.dispose();
      } catch (e) {
        debugPrint('[WebViewSessionSync] dispose WebView 失败: $e');
      }
      FrameJankMonitor.logEvent('WEBVIEW', 'SessionSync dispose');
    }
  }

  void _logEnsureEvent({
    required String event,
    required String reason,
    String level = 'debug',
    Map<String, dynamic>? extra,
  }) {
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'cookie_trace',
      'event': event,
      'message': 'WebView session sync state: $event',
      'reason': reason,
      ...?extra,
    });
  }

  /// 记录当前主域 cookie 摘要，便于确认站点 bootstrap 产生的 HttpOnly
  /// session cookie 是否已经被同步。只记录名称和诊断信息，不记录真实值。
  Future<void> logCookieSummary({
    required String reason,
    bool? bootstrapOk,
    String? endpoint,
    int? status,
  }) async {
    try {
      if (!_jar.isInitialized) {
        await _jar.initialize();
      }
      final uri = Uri.parse(AppConstants.baseUrl);
      final details = await _jar.getCookieDiagnosticsForRequest(uri);
      final names = details
          .map((cookie) => cookie['name']?.toString())
          .whereType<String>()
          .where((name) => name.isNotEmpty)
          .toList(growable: false);

      final entry = <String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'cookie_trace',
        'event': 'webview_session_bootstrap_cookie_summary',
        'message': 'WebView session bootstrap 后的主域 cookie 摘要',
        'reason': reason,
        'cookieNames': names,
        'cookieDetails': details,
      };
      if (bootstrapOk != null) entry['bootstrapOk'] = bootstrapOk;
      if (endpoint != null) entry['endpoint'] = endpoint;
      if (status != null) entry['status'] = status;
      LogWriter.instance.write(entry);
    } catch (e) {
      debugPrint('[WebViewSessionSync] 记录 cookie 摘要失败: $e');
    }
  }

  /// 在一个已经处于 linux.do origin 的 WebView 中运行会话 bootstrap。
  ///
  /// 供原生登录对话框复用：登录成功后不需要打开完整站点页面，直接在同一个
  /// 同源 WebView 里跑站点 session bootstrap，再做边界同步。
  ///
  /// [pluginCandidates] 是首页 HTML 中预先扫出的 plugin js url 列表（来自
  /// `PreloadedDataService.pluginCandidatesSync`）。传入后 bootstrap 脚本会
  /// 跳过自己的首页 fetch，直接用这个列表查找 fingerprint 插件。未传或为空
  /// 时降级到脚本内的 discover 流程，行为与历史版本一致。
  Future<SessionBootstrapResult> runOnController(
    InAppWebViewController controller, {
    String reason = 'unknown',
    List<String>? pluginCandidates,
    Duration timeout = _bootstrapTimeout,
    bool Function()? isCancelled,
    Future<void>? cancellationSignal,
  }) async {
    if (isCancelled?.call() == true) {
      return const SessionBootstrapResult.failure(phase: 'cancelled');
    }
    final handlerName =
        'fluxdo_session_bootstrap_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>>();
    // 上次 fingerprint 上报 404 → 候选列表/WebView 缓存里的插件 JS 已过期
    // (站点会轮换混淆端点)。本次绕过注入候选、以 no-cache 拉插件 JS,
    // 走全新 discover —— 唯一能拿到新端点的路径;否则同一份旧弹药
    // 无论重试多少次都是 404。
    final freshPlugin = _forceFreshPlugin;

    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (args) {
        if (completer.isCompleted || isCancelled?.call() == true) return null;
        final raw = args.isNotEmpty ? args.first?.toString() : null;
        try {
          final decoded = raw == null || raw.isEmpty
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(raw) as Map);
          completer.complete(decoded);
        } catch (e) {
          completer.complete({
            'ok': false,
            'phase': 'decode',
            'error': e.toString(),
          });
        }
        return null;
      },
    );

    try {
      if (isCancelled?.call() == true) {
        return const SessionBootstrapResult.failure(phase: 'cancelled');
      }
      await _injectPluginCandidates(
        controller,
        freshPlugin ? null : pluginCandidates,
      );
      if (isCancelled?.call() == true) {
        return const SessionBootstrapResult.failure(phase: 'cancelled');
      }
      await controller.evaluateJavascript(
        source:
            'window.__fluxdoFreshPlugin = ${freshPlugin ? 'true' : 'false'};',
      );
      if (isCancelled?.call() == true) {
        return const SessionBootstrapResult.failure(phase: 'cancelled');
      }
      final script = _bootstrapScript(handlerName);
      await controller.evaluateJavascript(source: script);
      if (isCancelled?.call() == true) {
        return const SessionBootstrapResult.failure(phase: 'cancelled');
      }
      final resultFuture = completer.future.timeout(timeout);
      final result = cancellationSignal == null
          ? await resultFuture
          : await Future.any<Map<String, dynamic>>([
              resultFuture,
              cancellationSignal.then(
                (_) => <String, dynamic>{'ok': false, 'phase': 'cancelled'},
              ),
            ]);
      final ok = result['ok'] == true;
      final cfBlocked = result['cfBlocked'] == true;
      final endpoint = result['endpoint']?.toString();
      final status = (result['status'] as num?)?.toInt();
      final phase = result['phase']?.toString();
      if (ok) {
        _forceFreshPlugin = false;
      } else if (status == 404 || phase == 'discover') {
        // 端点 404 / 候选里找不到插件 = 弹药过期,下一轮强制新鲜 discover;
        // 同时废掉 PreloadedDataService 里的旧候选,别的调用方也不再拿它。
        _forceFreshPlugin = true;
        PreloadedDataService().invalidatePluginCandidates();
      }
      debugPrint(
        '[WebViewSessionSync] bootstrap result: ok=$ok cfBlocked=$cfBlocked '
        'reason=$reason phase=$phase '
        'plugin=${result['plugin']} endpoint=$endpoint status=$status '
        'fresh=$freshPlugin error=${result['error']}',
      );
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': ok ? 'info' : 'warning',
        'type': 'cookie_trace',
        'event': 'webview_session_bootstrap_result',
        'message': 'WebView session bootstrap 执行结果',
        'reason': reason,
        'ok': ok,
        if (cfBlocked) 'cfBlocked': true,
        if (freshPlugin) 'freshPlugin': true,
        'phase': phase,
        'plugin': result['plugin']?.toString(),
        'endpoint': endpoint,
        'status': status,
        'error': result['error']?.toString(),
      });
      return ok
          ? const SessionBootstrapResult.success()
          : SessionBootstrapResult.failure(
              cfBlocked: cfBlocked,
              status: status,
              phase: phase,
            );
    } on TimeoutException {
      debugPrint('[WebViewSessionSync] bootstrap 超时: reason=$reason');
      return const SessionBootstrapResult.failure(phase: 'timeout');
    } catch (e) {
      debugPrint('[WebViewSessionSync] bootstrap 执行失败: reason=$reason $e');
      return const SessionBootstrapResult.failure(phase: 'controller_error');
    } finally {
      try {
        controller.removeJavaScriptHandler(handlerName: handlerName);
      } catch (_) {
        // 旧平台实现可能没有 remove 能力；handler 名唯一，残留也不会串线。
      }
    }
  }

  Future<void> _writeBootstrapHtml(InAppWebViewController controller) async {
    final html = jsonEncode(_bootstrapHtml);
    await controller.evaluateJavascript(
      source:
          '''
document.open();
document.write($html);
document.close();
''',
    );
  }

  /// 把 caller 提供的 plugin url 列表注入到 WebView 全局，bootstrap 脚本会
  /// 优先用它跳过自己的首页 fetch。
  Future<void> _injectPluginCandidates(
    InAppWebViewController controller,
    List<String>? pluginCandidates,
  ) async {
    if (pluginCandidates == null || pluginCandidates.isEmpty) {
      // 显式清掉旧值，避免上一次注入残留误导本次（HeadlessWebView 之间不共享
      // window，但 runOnController 也用于复用控制器的登录对话框场景）。
      await controller.evaluateJavascript(
        source: 'window.__fluxdoPluginCandidates = null;',
      );
      return;
    }
    final encoded = jsonEncode(pluginCandidates);
    await controller.evaluateJavascript(
      source: 'window.__fluxdoPluginCandidates = $encoded;',
    );
  }

  String get _windowsBootstrapUrl => '${AppConstants.baseUrl}/robots.txt';

  String get _bootstrapHtml =>
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body></body></html>';

  String _bootstrapScript(String handlerName) {
    final handler = jsonEncode(handlerName);
    final baseUrl = jsonEncode(AppConstants.baseUrl);
    return '''
(async function() {
  const handlerName = $handler;
  const appBaseUrl = $baseUrl;
  function done(payload) {
    try {
      window.flutter_inappwebview.callHandler(handlerName, JSON.stringify(payload || {}));
    } catch (e) {}
  }

  async function readCsrfToken() {
    try {
      const response = await fetch('/session/csrf', {
        method: 'GET',
        credentials: 'include',
        cache: 'no-store',
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        }
      });
      if (!response.ok) return null;
      const json = await response.json();
      return json && json.csrf ? String(json.csrf) : null;
    } catch (_) {
      return null;
    }
  }

  async function postForm(url, data) {
    const params = new URLSearchParams();
    Object.keys(data || {}).forEach(function(key) {
      params.append(key, data[key] == null ? '' : String(data[key]));
    });
    const headers = {
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest'
    };
    const csrf = await readCsrfToken();
    if (csrf) headers['X-CSRF-Token'] = csrf;

    const response = await fetch(url, {
      method: 'POST',
      credentials: 'include',
      cache: 'no-store',
      headers,
      body: params.toString()
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error('POST ' + url + ' -> ' + response.status + ': ' + text.slice(0, 160));
    }
    return {
      url,
      status: response.status,
      ok: response.ok,
      bodyLength: text.length
    };
  }

  function normalizeAssetUrl(raw) {
    if (!raw) return null;
    const cleaned = raw.replace(/&amp;/g, '&');
    try {
      return new URL(cleaned, appBaseUrl + '/').toString();
    } catch (_) {
      return null;
    }
  }

  async function discoverPluginUrls() {
    // 优先用 dart 侧 PreloadedDataService 注入的列表 (来源同一份首页 HTML),
    // 避免 bootstrap 再 fetch 一次首页。无注入时降级到自己拉首页扫描。
    const injected = Array.isArray(window.__fluxdoPluginCandidates)
      ? window.__fluxdoPluginCandidates.filter(function(u) { return typeof u === 'string' && u.length > 0; })
      : null;
    if (injected && injected.length) {
      return injected.slice();
    }

    const urls = new Set();
    const response = await fetch('/?__fluxdo_session_bootstrap=' + Date.now(), {
      method: 'GET',
      credentials: 'include',
      cache: 'no-store',
      headers: { 'Accept': 'text/html,*/*' }
    });
    const html = await response.text();
    if (!response.ok) {
      throw new Error('home fetch -> ' + response.status + ': ' + html.slice(0, 120));
    }

    const assetPattern = /(https?:\\/\\/[^"'\\s<>]+\\/assets\\/[^"'\\s<>]*plugins\\/[^"'\\s<>]+?\\.js(?:\\?[^"'\\s<>]*)?|\\/assets\\/[^"'\\s<>]*plugins\\/[^"'\\s<>]+?\\.js(?:\\?[^"'\\s<>]*)?)/g;
    let match;
    while ((match = assetPattern.exec(html)) !== null) {
      const url = normalizeAssetUrl(match[1]);
      if (url) urls.add(url);
    }
    return Array.from(urls);
  }

  async function findFingerprintPlugin() {
    // dart 侧在上次端点 404 后置位:插件 JS 必须绕过 HTTP 缓存重新拉,
    // 否则 force-cache 会一直命中旧 JS,提取出的过期端点重试也是 404。
    const freshPlugin = window.__fluxdoFreshPlugin === true;
    const candidates = await discoverPluginUrls();
    for (const url of candidates) {
      try {
        const response = await fetch(url, {
          method: 'GET',
          credentials: 'omit',
          cache: freshPlugin ? 'reload' : 'force-cache'
        });
        if (!response.ok) continue;
        const source = await response.text();
        if (
          source.indexOf('initializers/fingerprint') >= 0 &&
          source.indexOf('visitor_id') >= 0 &&
          source.indexOf('Fingerprint') >= 0
        ) {
          return { url, source };
        }
      } catch (_) {}
    }
    return null;
  }

  function extractFingerprintRunner(source) {
    // 端点上报调用的压缩函数名会随论坛构建变化(曾是 `_`,现为 `L`),
    // 不写死函数名,只匹配 `<任意标识符>("<端点>",{type:"POST",data:{visitor_id:` 这一稳定结构。
    const endpointMatch = source.match(/[A-Za-z_\$][\\w\$]*\\("([^"]+)",\\{type:"POST",data:\\{visitor_id:/);
    if (!endpointMatch) {
      throw new Error('fingerprint endpoint not found');
    }
    const fpMatch = source.match(/[A-Za-z_\$][\\w\$]*=(function\\(n\\)\\{function e[\\s\\S]*?Object\\.defineProperty\\(n,"__esModule",\\{value:!0\\}\\),n\\})\\(\\{\\}\\)/);
    if (!fpMatch) {
      throw new Error('fingerprint engine not found');
    }
    return {
      endpoint: endpointMatch[1],
      engineFactory: fpMatch[1]
    };
  }

  async function runFingerprintSource(plugin) {
    const runner = extractFingerprintRunner(plugin.source);
    const fingerprint = (0, eval)('(' + runner.engineFactory + ')({})');
    if (!fingerprint || typeof fingerprint.load !== 'function') {
      throw new Error('fingerprint engine invalid');
    }
    const agent = await fingerprint.load();
    const result = await agent.get();
    const data = {};
    Object.keys(result.components || {}).forEach(function(key) {
      data[key] = result.components[key] && result.components[key].value;
    });
    const post = await postForm(runner.endpoint, {
      visitor_id: result.visitorId,
      version: result.version,
      data: JSON.stringify(data)
    });
    post.endpoint = runner.endpoint;
    post.plugin = plugin.url;
    return post;
  }

  try {
    if (location.origin !== appBaseUrl) {
      return done({ ok: false, phase: 'origin', error: 'unexpected origin: ' + location.origin });
    }
    const plugin = await findFingerprintPlugin();
    if (!plugin) {
      return done({ ok: false, phase: 'discover', error: 'fingerprint plugin not found' });
    }
    const post = await runFingerprintSource(plugin);
    return done({
      ok: post && post.ok === true,
      phase: 'post',
      plugin: post && post.plugin,
      status: post && post.status,
      endpoint: post && post.endpoint
    });
  } catch (e) {
    var msg = String(e && e.message ? e.message : e);
    // home fetch / postForm 失败时 throw 的 message 形如 "... -> 403: ...",
    // 从中解析出 HTTP status,把 403/429 标记为 CF 拦截,供 dart 侧统一处理。
    var statusMatch = msg.match(/->\\s*(\\d{3})/);
    var st = statusMatch ? parseInt(statusMatch[1], 10) : null;
    return done({ ok: false, phase: 'exception', error: msg, status: st, cfBlocked: st === 403 || st === 429 });
  }
})();
''';
  }
}
