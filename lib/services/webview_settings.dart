import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../constants.dart';
import 'eruda_settings_service.dart';
import 'log/log_writer.dart';
import 'network/doh/network_settings_service.dart';

/// WebView 配置工具类
/// 区分 Headless（后台同步）和 Visible（用户可见页面）两种场景
class WebViewSettings {
  WebViewSettings._();

  /// Windows 触摸板/滚轮 workaround（flutter_inappwebview_windows #2783）
  ///
  /// C++ 层 sendScroll 把 delta 乘以 6 后通过 SendMouseInput(WHEEL) 发给 WebView2，
  /// 但触摸板的小 delta（1~5px）乘以 6 仍远小于 WHEEL_DELTA(120)，被 WebView2 忽略。
  ///
  /// 方案：JS 完全接管滚动 ——
  /// 1. 注入 wheel 事件 preventDefault 阻止 C++ 层产生的重复原生滚动
  /// 2. Flutter Listener 捕获 PointerScrollEvent 后通过 JS 精确设置 scrollTop/scrollLeft
  static const _scrollFixJs = '''
(function(){
  if(window.__fluxdoScrollFix) return;
  window.__fluxdoScrollFix = true;
  window.addEventListener('wheel', function(e){ e.preventDefault(); }, {passive:false});
  function canScroll(el, axis) {
    if (!el || el === document) return false;
    var style = getComputedStyle(el);
    var overflow = axis === 'x' ? style.overflowX : style.overflowY;
    if (!/(auto|scroll|overlay)/.test(overflow)) return false;
    return axis === 'x'
      ? el.scrollWidth > el.clientWidth + 1
      : el.scrollHeight > el.clientHeight + 1;
  }
  function canMove(el, axis, delta) {
    if (!canScroll(el, axis)) return false;
    var current = axis === 'x' ? el.scrollLeft : el.scrollTop;
    var maximum = axis === 'x'
      ? el.scrollWidth - el.clientWidth
      : el.scrollHeight - el.clientHeight;
    return delta < 0 ? current > 0 : current < maximum - 1;
  }
  function findScroller(start, axis, delta) {
    var el = start;
    while (el && el !== document.documentElement && el !== document.body) {
      if (canMove(el, axis, delta)) return el;
      el = el.parentElement;
    }
    return document.scrollingElement || document.documentElement;
  }
  window.__fluxdoScroll = function(dx, dy, x, y) {
    var start = Number.isFinite(x) && Number.isFinite(y)
      ? document.elementFromPoint(x, y)
      : document.activeElement;
    if (dy) {
      var vertical = findScroller(start, 'y', dy);
      vertical.scrollTop += dy;
    }
    if (dx) {
      var horizontal = findScroller(start, 'x', dx);
      horizontal.scrollLeft += dx;
    }
  };
})();
''';

  /// 在 onLoadStop 中调用，为 Windows WebView 注入滚轮补丁
  static Future<void> injectScrollFix(InAppWebViewController controller) async {
    if (!Platform.isWindows) return;
    await controller.evaluateJavascript(source: _scrollFixJs);
  }

  /// 包裹 InAppWebView，在 Windows 上捕获滚轮事件并通过 JS 转发
  static Widget wrapWithScrollFix(
    Widget child, {
    required InAppWebViewController? Function() getController,
  }) {
    if (!Platform.isWindows) return child;
    return _JsonScrollListener(getController: getController, child: child);
  }

  /// Gateway 模式下 WebView 的 SSL 信任回调
  ///
  /// 代理做 MITM 时会用自签 CA 签发证书，WKWebView/WebView 不信任它。
  /// 仅在本地代理网关模式运行时放行，其他情况走系统默认验证。
  static Future<ServerTrustAuthResponse?> handleServerTrustAuthRequest(
    URLAuthenticationChallenge challenge,
  ) async {
    // Android/macOS: gateway MITM 模式下放行代理 CA 证书。
    // iOS: 使用隧道模式（非 MITM），不会触发代理 CA 信任问题。
    if (NetworkSettingsService.instance.isGatewayMode) {
      return ServerTrustAuthResponse(
        action: ServerTrustAuthResponseAction.PROCEED,
      );
    }
    return null;
  }

  /// Headless WebView 配置（后台同步用，轻量）
  /// 用于 CsrfTokenService、WebViewHttpAdapter、会话 bootstrap 等
  static InAppWebViewSettings get headless => InAppWebViewSettings(
    javaScriptEnabled: true,
    sharedCookiesEnabled: true,
    userAgent: AppConstants.webViewUserAgentOverride,

    // 性能优化 - 不加载不必要的资源
    blockNetworkImage: true,
    loadsImagesAutomatically: false,
    mediaPlaybackRequiresUserGesture: true,
    allowsInlineMediaPlayback: false,

    // 缓存优化
    cacheEnabled: true,
    cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,

    // 禁用不需要的回调以减少开销
    useShouldOverrideUrlLoading: false,
    useShouldInterceptRequest: false,
    useOnLoadResource: false,
    useOnDownloadStart: false,

    // 其他优化
    transparentBackground: true,
    disableContextMenu: true,
    verticalScrollBarEnabled: false,
    horizontalScrollBarEnabled: false,
    disableVerticalScroll: true,
    disableHorizontalScroll: true,
    supportZoom: false,

    // 安全相关
    thirdPartyCookiesEnabled: true,
  );

  /// Headless WebView 配置（CF/Turnstile 用）。
  ///
  /// CF 相关页面更看重浏览器环境接近默认行为，因此这里不禁图片、也不强制
  /// LOAD_CACHE_ELSE_NETWORK；资源占用主要交给 WebView2 memory target 处理。
  static InAppWebViewSettings get headlessCf => InAppWebViewSettings(
    javaScriptEnabled: true,
    sharedCookiesEnabled: true,
    userAgent: AppConstants.webViewUserAgentOverride,

    // 这些开关只影响 WebView 插件回调，不改变页面可见能力。
    useShouldOverrideUrlLoading: false,
    useShouldInterceptRequest: false,
    useOnLoadResource: false,
    useOnDownloadStart: false,

    transparentBackground: true,
    disableContextMenu: true,
    verticalScrollBarEnabled: false,
    horizontalScrollBarEnabled: false,
    disableVerticalScroll: true,
    disableHorizontalScroll: true,
    supportZoom: false,

    thirdPartyCookiesEnabled: true,
  );

  /// Windows WebView2 后台实例使用低内存目标。
  ///
  /// 该 API 只在支持 ICoreWebView2_19 的 Runtime 生效；旧 Runtime 会由插件
  /// native 层 no-op。这里异步 fire-and-forget，避免影响 WebView 创建流程。
  static void applyWindowsHeadlessMemoryTarget(
    InAppWebViewController controller,
  ) {
    if (!Platform.isWindows) return;
    unawaited(() async {
      try {
        await controller.setMemoryUsageTargetLevel(MemoryUsageTargetLevel.LOW);
      } catch (e) {
        debugPrint('[WebViewSettings] 设置 WebView2 低内存目标失败: $e');
      }
    }());
  }

  /// 老 WKWebView (主要 iOS 15+) 兼容性脚本：core-js polyfill + JS 错误回传。
  /// 产物在 `assets/polyfill/compat-polyfill.js`，由 `tools/polyfill-bundle/` 子工程
  /// 用 @babel/preset-env + core-js + esbuild 按 browserslist (iOS >= 15.0) 自动打包。
  /// 抬基线 / 升 polyfill 全部去那边改。
  static const _polyfillAssetPath = 'assets/polyfill/compat-polyfill.js';
  static UnmodifiableListView<UserScript>? _compatPolyfillScripts;
  static bool _polyfillLoadAttempted = false;

  /// 启动期调用一次（main.dart 并行初始化阶段），把 asset 内容读入内存。
  /// 加载失败不抛错，只打日志 —— polyfill 缺失最坏只影响老平台兼容性，
  /// 不应让整个 app 启动失败。
  static Future<void> preloadPolyfill() async {
    if (_polyfillLoadAttempted) return;
    _polyfillLoadAttempted = true;
    try {
      final source = await rootBundle.loadString(_polyfillAssetPath);
      _compatPolyfillScripts = UnmodifiableListView([
        UserScript(
          source: source,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          // 必须 true: es-module-shims 在 iOS 15 上为每个 module 评估创建
          // about:blank iframe。实测 Discourse vendor bundle 触发它创建 1100+
          // 个 iframe (10 秒内, 110/秒)。如果对每个 iframe 都注入这 155KB
          // polyfill, parse + 跑 + callHandler 把主线程霸占, Discourse 永远
          // 启动不了 (splash 永驻)。
          // iframe 不需要 polyfill: es-module-shims 的 stub iframe 只评估
          // module、不跑业务代码;CF turnstile / Stripe / Google GSI 等真实
          // 第三方 iframe 用 IIFE 不依赖 importmap, 也不需要我们的 polyfill。
          forMainFrameOnly: true,
        ),
      ]);
    } catch (e) {
      debugPrint(
        '[WebViewSettings] 加载 compat polyfill asset 失败: $e。'
        '请确认已运行 `cd tools/polyfill-bundle && pnpm build`。',
      );
      _compatPolyfillScripts = UnmodifiableListView<UserScript>([]);
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'error',
        'type': 'webview',
        'event': 'compat_polyfill_load_failed',
        'message': '加载 compat polyfill asset 失败',
        'asset': _polyfillAssetPath,
        'error': e.toString(),
      });
    }
  }

  /// Eruda 默认关闭时注入的禁用脚本: 在 polyfill 之前抢先设
  /// `__fluxdoErudaInited = true`, 让 bundle 内 eruda-init 的 guard 跳过 init。
  /// 见 [ErudaSettingsService]。纯 dart 控制, 不改 / 不重打包 bundle。
  static final UserScript _erudaDisableScript = UserScript(
    source: 'window.__fluxdoErudaInited = true;',
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: true,
  );

  /// 兼容性脚本列表，传给 `InAppWebView.initialUserScripts`。
  /// 必须先在启动期调 [preloadPolyfill]；未加载时返回空列表 + 一次性告警。
  ///
  /// Eruda 开关关闭时 (默认), 在 polyfill 前追加禁用脚本; 打开时原样返回让
  /// bundle 内的 eruda 正常初始化。
  static UnmodifiableListView<UserScript> get compatPolyfillScripts {
    final cached = _compatPolyfillScripts;
    if (cached == null) {
      if (!_polyfillLoadAttempted) {
        debugPrint(
          '[WebViewSettings] compatPolyfillScripts 在 preloadPolyfill() 完成前被读取，'
          '老 WebView 兼容性会缺失。请检查 main.dart 初始化序列。',
        );
      }
      return UnmodifiableListView<UserScript>([]);
    }
    if (!ErudaSettingsService.instance.enabled) {
      return UnmodifiableListView<UserScript>([_erudaDisableScript, ...cached]);
    }
    return cached;
  }

  /// 注册 JS 错误 / lifecycle 回传 handler，把 WebView 内的事件落到 LogWriter。
  /// 在 `onWebViewCreated` 拿到 controller 后调用一次。
  ///
  /// JS 侧通过 `flutter_inappwebview.callHandler('onWebViewJsError', payload)` 发，
  /// 按 `source` 字段路由（统一 debug 级，仅开发者模式落盘）：
  /// - `lifecycle` → event=boot 阶段名，带 polyfill 自检 probes/missing
  /// - `console.error` → 能突破跨域 sanitization 拿到 Discourse 自家 stack
  /// - `window.error` / `unhandledrejection` → uncaught 兜底（跨域时 sanitized）
  ///
  /// 这些都是 WebView 诊断信息：日常浏览、贴内嵌入(iframe)、外链页面的 JS 报错
  /// 与 app 自身无关，常态全部丢弃；排查老设备白屏/兼容性时开开发者模式即可收集。
  static void registerJsErrorReporter(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onWebViewJsError',
      callback: (args) {
        // 非开发者模式直接丢弃，省去 Map 构造与跨进程数据落盘
        if (!LogWriter.verboseEnabled) return null;
        if (args.isEmpty) return null;
        try {
          final raw = args[0];
          if (raw is! Map) return null;
          final data = Map<String, dynamic>.from(raw);
          final source = data['source']?.toString() ?? 'unknown';

          if (source == 'lifecycle') {
            // 把 message 用作 event 名,日志里能直接看到 boot 阶段:
            //   compat_bundle_loaded         - polyfill 跑完
            //   discourse_boot_dom           - DOMContentLoaded
            //   discourse_boot_load          - window load
            //   discourse_boot_init          - Discourse dispatchEvent(discourse-init)
            //   discourse_boot_ready         - Ember ready,#d-splash 被移除
            //   discourse_boot_status_30s    - 30 秒兜底,看 stages 字段哪一步没到
            final msg = data['message']?.toString() ?? 'compat_bundle_loaded';
            LogWriter.instance.write({
              'timestamp': DateTime.now().toIso8601String(),
              'level': 'debug',
              'type': 'webview_compat',
              'event': msg,
              'message': msg,
              'probes': data['probes'],
              'missing': data['missing'],
              'stage': data['stage'],
              'stages': data['stages'],
              'extra': data['extra'],
              'hasSplash': data['hasSplash'],
              'pageUrl': data['url'],
              'pageUa': data['ua'],
              'platform': Platform.operatingSystem,
              'platformVersion': Platform.operatingSystemVersion,
            });
          } else {
            LogWriter.instance.write({
              'timestamp': DateTime.now().toIso8601String(),
              'level': 'debug',
              'type': 'webview_js',
              'event': 'js_runtime_error',
              'message': data['message']?.toString() ?? 'unknown',
              'jsSource': source,
              'jsFilename': data['filename'],
              'jsLineno': data['lineno'],
              'jsColno': data['colno'],
              'jsStack': data['stack'],
              'jsEventType': data['eventType'],
              'jsTargetTag': data['targetTag'],
              'jsTargetSrc': data['targetSrc'],
              'pageUrl': data['url'],
              'pageUa': data['ua'],
              'platform': Platform.operatingSystem,
              'platformVersion': Platform.operatingSystemVersion,
            });
          }
        } catch (_) {}
        return null;
      },
    );
  }

  /// 可见 WebView 配置（登录页、CF 手动验证等，完整功能）
  /// 用于 WebViewLoginPage、CF 手动验证页面等
  static InAppWebViewSettings get visible => InAppWebViewSettings(
    javaScriptEnabled: true,
    sharedCookiesEnabled: true,
    domStorageEnabled: true,
    userAgent: AppConstants.webViewUserAgentOverride,
    isInspectable: true,

    // 保持完整功能
    blockNetworkImage: false,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,

    // 缓存
    cacheEnabled: true,

    // 保持默认回调（可能需要）
    useShouldOverrideUrlLoading: false,

    // 启用下载拦截
    useOnDownloadStart: true,

    // 安全相关
    thirdPartyCookiesEnabled: true,
  );
}

/// Windows 滚轮/触摸板事件转发 widget
class _JsonScrollListener extends StatefulWidget {
  const _JsonScrollListener({required this.getController, required this.child});

  final InAppWebViewController? Function() getController;
  final Widget child;

  @override
  State<_JsonScrollListener> createState() => _JsonScrollListenerState();
}

class _JsonScrollListenerState extends State<_JsonScrollListener> {
  double _pendingDx = 0;
  double _pendingDy = 0;
  Offset _lastPosition = Offset.zero;
  int? _frameCallbackId;
  bool _inFlight = false;

  @override
  void dispose() {
    final callbackId = _frameCallbackId;
    if (callbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
    super.dispose();
  }

  void _queueScroll(double dx, double dy, Offset position) {
    if (dx == 0 && dy == 0) return;
    _pendingDx += dx;
    _pendingDy += dy;
    _lastPosition = position;
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_frameCallbackId != null || _inFlight || !mounted) return;
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameCallbackId = null;
      _flushScroll();
    });
  }

  Future<void> _flushScroll() async {
    final controller = widget.getController();
    if (controller == null || (_pendingDx == 0 && _pendingDy == 0)) return;

    final dx = _pendingDx;
    final dy = _pendingDy;
    final position = _lastPosition;
    _pendingDx = 0;
    _pendingDy = 0;
    _inFlight = true;
    try {
      final args = jsonEncode([dx, dy, position.dx, position.dy]);
      await controller.evaluateJavascript(
        source: 'window.__fluxdoScroll?.apply(null, $args)',
      );
    } catch (_) {
      // 页面导航/销毁窗口期允许丢弃本次滚动，下一次输入会重新注入并转发。
    } finally {
      _inFlight = false;
      if (_pendingDx != 0 || _pendingDy != 0) _scheduleFlush();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      // 鼠标滚轮
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _queueScroll(
            event.scrollDelta.dx,
            event.scrollDelta.dy,
            event.localPosition,
          );
        }
      },
      // 精确触摸板（Precision Touchpad）
      onPointerPanZoomUpdate: (event) {
        _queueScroll(
          -event.panDelta.dx,
          -event.panDelta.dy,
          event.localPosition,
        );
      },
      child: widget.child,
    );
  }
}
