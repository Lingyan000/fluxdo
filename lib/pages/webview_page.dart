import 'package:common_ui/common_ui.dart';

import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../utils/frame_jank_monitor.dart';
import '../utils/link_launcher.dart';
import '../services/deep_link_service.dart';
import '../services/browser_tabs.dart';
import '../services/browser_navigation.dart';
import '../services/browser_safe_area.dart';
import '../services/browser_native_safe_area.dart';
import '../services/browser_surface_theme.dart';
import '../services/webview_surface_capture.dart';
import '../widgets/browser/browser_page_route.dart';
import '../widgets/browser/browser_toolbar.dart';
import '../widgets/browser/browser_address_panel.dart';
import '../widgets/browser/browser_layout.dart';
import '../widgets/browser/browser_dock_motion.dart';
import '../widgets/browser/browser_web_viewport.dart';
import 'my_browser_page.dart';
import '../services/toast_service.dart';
import '../services/app_link_service.dart';
import '../services/network/cookie/cookie_store_observer.dart';
import '../services/network/cookie/webview_cookie_priming.dart';
import '../services/webview_settings.dart';
import '../services/windows_webview_environment_service.dart';
import '../widgets/common/app_link_confirm_dialog.dart';
import '../providers/web_bookmark_provider.dart';
import '../providers/web_history_provider.dart';
import '../providers/download_provider.dart';

import '../l10n/s.dart';

/// 通用内置浏览器页面
class WebViewPage extends ConsumerStatefulWidget {
  final String url;
  final String? title;
  final String? injectCss;
  final BrowserTabSession? session;

  const WebViewPage({
    super.key,
    required this.url,
    this.title,
    this.injectCss,
    this.session,
  });

  static void restore(NavigatorState navigator, BrowserTabSession session) {
    navigator.push(
      BrowserPageRoute<void>(
        fromDock: true,
        motion: BrowserDockViewport.motionOf(navigator.context),
        session: session,
        builder: (_) => WebViewPage(
          url: session.url,
          title: session.title,
          injectCss: session.injectCss,
          session: session,
        ),
      ),
    );
  }

  /// 打开浏览器，url 为空字符串时显示空白页
  static Future<T?> open<T extends Object?>(
    BuildContext context,
    String url, {
    String? title,
    String? injectCss,
  }) {
    return Navigator.of(context, rootNavigator: true).push<T>(
      BrowserPageRoute<T>(
        motion: BrowserDockViewport.motionOf(context),
        builder: (_) =>
            WebViewPage(url: url, title: title, injectCss: injectCss),
      ),
    );
  }

  @override
  ConsumerState<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends ConsumerState<WebViewPage> {
  late final BrowserTabSession _session;
  bool _minimized = false;
  bool _minimizing = false;
  InAppWebViewController? _controller;
  bool _isLoading = true;
  String _currentUrl = '';
  String _currentTitle = '';
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _historyStateSettled = false;
  int _navigationRevision = 0;
  final _addressController = TextEditingController();
  final _addressFocus = FocusNode();
  final _findText = TextEditingController();
  final _findFocus = FocusNode();
  late final FindInteractionController _findController;
  Animation<double>? _routeAnimation;
  Timer? _findDebounce;
  Timer? _searchTimeout;
  bool _addressEditing = false;
  bool _finding = false;
  bool _closing = false;
  bool _stopped = false;
  bool _suggestAlternative = false;
  String? _googleQuery;
  String? _loadError;
  String? _pendingNavigation;
  int _matchCount = 0;
  int _matchIndex = 0;

  /// 网页上报的安全区声明；null 时按普通网页由应用留边。
  BrowserPageSafeArea? _pageSafeArea;
  final _safeAreaPolicy = BrowserSafeAreaPolicy();
  BrowserViewportGeometry? _viewportGeometry;
  EdgeInsets _viewportUnsafe = EdgeInsets.zero;
  EdgeInsets? _checkedUnsafe;
  Timer? _safeAreaCheck;
  int _safeAreaMismatches = 0;
  int _safeAreaRevision = 0;
  bool _fullscreen = false;

  /// 网页没有声明底色时，从截图边缘取色填充留白，与小程序共用调度。
  final _surfaceTheme = BrowserSurfaceTheme();
  final _viewportKey = GlobalKey();
  bool _surfaceCapturing = false;

  /// 转场或对话框期间用静态截图盖住 WebView，避免 BackdropFilter 对
  /// hybrid composition（Android）/HWND（Windows）实时回读造成卡顿。
  Uint8List? _webViewSnapshot;
  bool _snapshotVisible = true;
  bool _restoredControllerReady = false;
  bool _revealingSnapshot = false;
  Timer? _previewIdle;
  Uint8List? _preparedPreview;
  int _previewRevision = 0;
  bool _capturingPreview = false;
  int _webPointers = 0;
  Size? _previewSize;
  double _dragOpenProgress = 1;
  BrowserPageRoute<dynamic>? _dragRoute;

  @override
  void initState() {
    super.initState();
    _session =
        widget.session ??
        BrowserTabSession(
          url: widget.url,
          title: widget.title ?? '',
          injectCss: widget.injectCss,
        );
    _session.attach();
    _currentUrl = widget.url;
    _currentTitle = widget.title ?? '';
    _isLoading = widget.session == null;
    _progress = widget.session == null ? 0 : 1;
    _webViewSnapshot = widget.session?.preview;
    _pageSafeArea = widget.session?.safeArea;
    _addressController.addListener(_addressChanged);
    _surfaceTheme.addListener(_surfaceChanged);
    _findController = FindInteractionController(
      onFindResultReceived: (_, index, count, done) {
        if (!mounted || !_finding || !done || _findText.text.isEmpty) return;
        setState(() {
          _matchIndex = index;
          _matchCount = count;
        });
      },
    );
    // 可见 WebView(hybrid composition)在位期间会参与每帧合成,
    // 打点让诊断时间轴能对齐"WebView 页在前台"与掉帧段
    FrameJankMonitor.logEvent('WEBVIEW', 'WebViewPage mount');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    if (_previewSize != size) {
      _previewSize = size;
      _invalidatePreview();
      _schedulePreview();
    }
    final route = ModalRoute.of(context);
    if (route is BrowserPageRoute) route.onReturnToDock = _returnToDock;
    final animation = route is BrowserPageRoute
        ? route.transitionAnimation
        : route?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeStatusListener(_routeStatusChanged);
      _routeAnimation = animation;
      animation?.addStatusListener(_routeStatusChanged);
    }
  }

  void _routeStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _resetSafeAreaCheck();
      if (mounted) setState(() {});
      _revealRestoredSnapshot();
      _schedulePreview();
    }
  }

  void _invalidatePreview() {
    _previewIdle?.cancel();
    _previewRevision++;
    _preparedPreview = null;
  }

  void _schedulePreview() {
    _previewIdle?.cancel();
    if (!mounted || _minimizing || _closing || _isLoading) return;
    _previewIdle = Timer(const Duration(milliseconds: 500), _preparePreview);
  }

  Future<void> _preparePreview() async {
    if (!mounted ||
        _capturingPreview ||
        _surfaceCapturing ||
        _minimizing ||
        _closing ||
        _addressEditing ||
        _isLoading ||
        _webPointers > 0 ||
        _controller == null ||
        ModalRoute.of(context)?.isCurrent != true ||
        _routeAnimation?.status != AnimationStatus.completed) {
      return;
    }
    final revision = _previewRevision;
    _capturingPreview = true;
    final watch = Stopwatch()..start();
    try {
      // Android 会把 snapshotWidth 再乘像素密度；预览限制为约 640 物理像素。
      final media = MediaQuery.of(context);
      final preview = await _controller!.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          snapshotWidth: media.size.width.clamp(
            0.0,
            640 / media.devicePixelRatio,
          ),
          compressFormat: CompressFormat.JPEG,
          quality: 75,
        ),
      );
      if (preview == null ||
          !mounted ||
          revision != _previewRevision ||
          _minimizing ||
          _closing) {
        return;
      }
      var decoded = true;
      await precacheImage(
        MemoryImage(preview),
        context,
        onError: (_, _) => decoded = false,
      );
      if (decoded &&
          mounted &&
          revision == _previewRevision &&
          !_minimizing &&
          !_closing) {
        _preparedPreview = preview;
      }
    } catch (_) {
      // 预览失败不影响交互，也不在点击时重试或等待。
    } finally {
      _capturingPreview = false;
      FrameJankMonitor.logEvent(
        'BROWSER_MOTION',
        'idle preview ${watch.elapsedMilliseconds}ms',
      );
    }
  }

  Future<void> _revealRestoredSnapshot() async {
    if (!mounted ||
        _minimizing ||
        _closing ||
        _revealingSnapshot ||
        !_restoredControllerReady ||
        _webViewSnapshot == null ||
        _routeAnimation?.status != AnimationStatus.completed) {
      return;
    }
    _revealingSnapshot = true;
    // 原生视图先在不透明截图下完成布局、合成；不在路由完成帧直接移走遮罩。
    for (var frame = 0; frame < 2; frame++) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _minimizing || _closing) return;
    }
    setState(() => _snapshotVisible = false);
  }

  void _addressChanged() {
    if (mounted && _addressEditing) setState(() {});
  }

  @override
  void dispose() {
    _previewIdle?.cancel();
    _searchTimeout?.cancel();
    _findDebounce?.cancel();
    _safeAreaCheck?.cancel();
    _surfaceTheme.dispose();
    _routeAnimation?.removeStatusListener(_routeStatusChanged);
    _addressController.dispose();
    _addressFocus.dispose();
    _findText.dispose();
    _findFocus.dispose();
    FrameJankMonitor.logEvent('WEBVIEW', 'WebViewPage dispose');
    // InAppWebView 自己负责解绑 Dart 控制器；此处不能用默认 dispose
    // 销毁共享实例。帧末确认子树卸载后，才允许重新挂载或释放原生实例。
    WidgetsBinding.instance.addPostFrameCallback((_) => _session.detach());
    if (!_minimized) unawaited(_session.close());
    super.dispose();
  }

  void _minimize() {
    if (_minimizing ||
        _minimized ||
        _closing ||
        !Navigator.of(context).canPop()) {
      return;
    }
    _logMotionStart('tap minimize');
    setState(() => _minimizing = true);
    _searchTimeout?.cancel();
    if (_finding) _endFind();
    FocusManager.instance.primaryFocus?.unfocus();
    _previewIdle?.cancel();
    final preview = _preparedPreview;
    _session
      ..url = _currentUrl
      ..title = _currentTitle
      ..preview = preview;
    setState(() {
      _minimized = true;
      _webViewSnapshot = preview;
      _snapshotVisible = true;
    });
    final route = ModalRoute.of(context);
    if (route is BrowserPageRoute) {
      route.beginMinimize(
        _session,
        hasSnapshot:
            preview != null || _currentUrl.isEmpty || _loadError != null,
      );
    }
    ref.read(browserTabsProvider).minimize(_session);
    Navigator.of(context).pop();
  }

  void _logMotionStart(String action) {
    final watch = Stopwatch()..start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FrameJankMonitor.logEvent(
        'BROWSER_MOTION',
        '$action first Flutter frame ${watch.elapsedMilliseconds}ms',
      );
    });
  }

  void _startMinimizeDrag(DragStartDetails details) {
    final route = ModalRoute.of(context);
    if (_minimizing ||
        _closing ||
        _addressEditing ||
        _finding ||
        !Navigator.of(context).canPop() ||
        route is! BrowserPageRoute ||
        route.transitionAnimation?.status != AnimationStatus.completed) {
      return;
    }
    _logMotionStart('drag minimize');
    _previewIdle?.cancel();
    _dragRoute = route;
    _dragOpenProgress = 1;
    _session
      ..url = _currentUrl
      ..title = _currentTitle;
    setState(() {
      _minimizing = true;
      _webViewSnapshot = _preparedPreview;
      _snapshotVisible = true;
    });
    route.beginMinimizeDrag(
      _session,
      hasSnapshot:
          _preparedPreview != null || _currentUrl.isEmpty || _loadError != null,
    );
  }

  void _updateMinimizeDrag(DragUpdateDetails details) {
    final route = _dragRoute;
    if (route == null) return;
    final media =
        BrowserDockViewport.maybeOf(context)?.media ?? MediaQuery.of(context);
    final travel = browserDockRect(media.size, media.padding.bottom).top;
    _dragOpenProgress = (_dragOpenProgress - details.delta.dy / travel).clamp(
      0.0,
      1.0,
    );
    route.setDragProgress(_dragOpenProgress);
  }

  void _endMinimizeDrag(DragEndDetails details) {
    final route = _dragRoute;
    if (route == null) return;
    if (route.shouldMinimize(details.primaryVelocity ?? 0)) {
      _dragRoute = null;
      _returnToDock();
    } else {
      _cancelMinimizeDrag();
    }
  }

  Future<void> _cancelMinimizeDrag() async {
    final route = _dragRoute;
    _dragRoute = null;
    if (route == null) return;
    await route.cancelMinimizeDrag();
    if (!mounted || _closing) return;
    setState(() {
      _minimizing = false;
    });
    _revealingSnapshot = false;
    _revealRestoredSnapshot();
    _schedulePreview();
  }

  void _returnToDock() {
    if (!mounted || _closing || _minimized) return;
    _previewIdle?.cancel();
    _searchTimeout?.cancel();
    _session
      ..url = _currentUrl
      ..title = _currentTitle
      ..preview = _webViewSnapshot ?? _preparedPreview;
    setState(() {
      _minimizing = true;
      _minimized = true;
    });
    ref.read(browserTabsProvider).minimize(_session);
    Navigator.of(context).pop();
  }

  Future<void> _syncRestoredState(InAppWebViewController controller) async {
    final revision = _navigationRevision;
    final (url, title, canGoBack, canGoForward, rawProgress) = await (
      controller.getUrl(),
      controller.getTitle(),
      controller.canGoBack(),
      controller.canGoForward(),
      controller.getProgress(),
    ).wait;
    final progress = rawProgress ?? 100;
    if (!mounted || revision != _navigationRevision) return;
    setState(() {
      _currentUrl = url?.toString() ?? _session.url;
      _currentTitle = title ?? _session.title;
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
      _historyStateSettled = true;
      _progress = progress / 100;
      _isLoading = progress < 100;
    });
    if (_isLoading) _watchSearch(_currentUrl);
  }

  @override
  Widget build(BuildContext context) {
    final windowsWebViewEnvironment =
        WindowsWebViewEnvironmentService.instance.environment;

    final isBookmarked = ref.watch(
      webBookmarkProvider.select(
        (list) => list.any((e) => e.url == _currentUrl),
      ),
    );
    final edgeToEdge = _safeAreaPolicy.edgeToEdge(_pageSafeArea);
    if (_pageSafeArea != null) _scheduleSafeAreaCheck();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncSurfaceSampling();
    });
    // 网页声明的底色 → 截图取色 → 浏览器画布色 → 主题色。
    final declared = _pageSafeArea?.background;
    final fallback =
        _pageSafeArea?.canvas ?? Theme.of(context).colorScheme.surface;
    final letterboxTop =
        declared ??
        AdaptiveSurfaceColors.resolve(
          sampled: _surfaceTheme.top,
          fallback: fallback,
        );
    final letterboxBottom =
        declared ??
        AdaptiveSurfaceColors.resolve(
          sampled: _surfaceTheme.bottom,
          fallback: fallback,
        );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyL, control: true):
            _beginAddressEditing,
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true):
            _beginAddressEditing,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _beginFind,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _beginFind,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_addressEditing) {
            _endAddressEditing();
          } else if (_finding) {
            _endFind();
          } else {
            _closeBrowser();
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          // WebView 还有历史时，返回键先回退网页；到首层后交给路由，
          // 这样离开浏览器页面可以使用 Android 预测式返回动画。
          // 历史状态未稳定时保守拦截并实时查询，避免新页面刚开始导航、
          // _canGoBack 尚未回填的窗口里把整个 WebView 路由直接退出。
          canPop:
              !_addressEditing &&
              !_finding &&
              _historyStateSettled &&
              !_canGoBack,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            if (_addressEditing) {
              _endAddressEditing();
              return;
            }
            if (_finding) {
              _endFind();
              return;
            }
            await _handleBackNavigation();
          },
          child: Scaffold(
            resizeToAvoidBottomInset: true,
            appBar: PreferredSize(
              preferredSize: const Size.fromHeight(66),
              child: GestureDetector(
                key: const ValueKey('browser-minimize-drag-area'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _startMinimizeDrag,
                onVerticalDragUpdate: _updateMinimizeDrag,
                onVerticalDragEnd: _endMinimizeDrag,
                onVerticalDragCancel: _cancelMinimizeDrag,
                child: BrowserToolbar(
                  title: _currentTitle,
                  url: _currentUrl,
                  editing: _addressEditing,
                  addressController: _addressController,
                  addressFocus: _addressFocus,
                  onAddressTap: _beginAddressEditing,
                  onCancelEdit: _endAddressEditing,
                  onSubmit: _navigateToUrl,
                  onClose: _closeBrowser,
                  onMinimize: _minimizing ? null : _minimize,
                  onMenu: _handleMenuAction,
                  loading: _isLoading,
                  progress: _progress,
                  bookmarked: isBookmarked,
                ),
              ),
            ),
            bottomNavigationBar: BrowserAnimatedSize(
              child: _addressEditing
                  ? const SizedBox.shrink()
                  : BrowserBottomToolbar(
                      canGoBack: _canGoBack,
                      canGoForward: _canGoForward,
                      loading: _isLoading,
                      hasUrl: _currentUrl.isNotEmpty,
                      bookmarked: isBookmarked,
                      onBack: () => _controller?.goBack(),
                      onForward: () => _controller?.goForward(),
                      onReload: _reloadOrStop,
                      onBookmark: _toggleBookmark,
                      onShare: _sharePage,
                    ),
            ),
            body: Column(
              children: [
                if (_finding) _buildFindBar(),
                if (_suggestAlternative &&
                    !_addressEditing &&
                    _loadError == null)
                  _buildSearchFallback(),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      BrowserWebViewport(
                        window: Offset.zero & MediaQuery.sizeOf(context),
                        systemPadding: MediaQuery.paddingOf(context),
                        observeGeometry: !_fullscreen && !_minimizing &&
                            !_addressEditing && !_closing &&
                            _routeAnimation?.status == AnimationStatus.completed,
                        onGeometryChanged: _viewportGeometryChanged,
                        unsafe: _viewportUnsafe,
                        edgeToEdge: edgeToEdge,
                        top: letterboxTop,
                        bottom: letterboxBottom,
                        child: Stack(
                          key: _viewportKey,
                          fit: StackFit.expand,
                          children: [
                            Offstage(
                              offstage:
                                  (_minimizing && _webViewSnapshot != null) ||
                                  _addressEditing ||
                                  _loadError != null ||
                                  _currentUrl.isEmpty,
                              child: Listener(
                                onPointerDown: (_) {
                                  _webPointers++;
                                  _invalidatePreview();
                                },
                                onPointerUp: (_) {
                                  _webPointers--;
                                  _schedulePreview();
                                },
                                onPointerCancel: (_) {
                                  _webPointers--;
                                  _schedulePreview();
                                },
                                child: WebViewSettings.wrapWithScrollFix(
                                  InAppWebView(
                                    keepAlive: _session.keepAlive,
                                    findInteractionController: _findController,
                                    webViewEnvironment:
                                        windowsWebViewEnvironment,
                                    initialSettings: WebViewSettings.visible
                                      ..useShouldOverrideUrlLoading = true,
                                    initialUserScripts: UnmodifiableListView([
                                      ...WebViewSettings.compatPolyfillScripts,
                                      BrowserSafeAreaProbe.userScript,
                                    ]),
                                    shouldOverrideUrlLoading:
                                        _shouldOverrideUrlLoading,
                                    onReceivedServerTrustAuthRequest:
                                        (_, challenge) =>
                                            WebViewSettings.handleServerTrustAuthRequest(
                                              challenge,
                                            ),
                                    onWebViewCreated: (controller) async {
                                      _controller = controller;
                                      _session.hasWebView = true;
                                      if (!mounted) return;
                                      // 首次加载及保活恢复都先同步，避免网页按整屏 Insets 留边。
                                      await _syncNativeSafeArea();
                                      if (!mounted) return;
                                      controller.addJavaScriptHandler(
                                        handlerName:
                                            BrowserSafeAreaProbe.handlerName,
                                        callback: (args) {
                                          _applyPageSafeArea(
                                            args.isEmpty ? null : args.first,
                                          );
                                          return null;
                                        },
                                      );
                                      if (_session.initialLoadRequested &&
                                          _pendingNavigation == null) {
                                        // 保活网页的探针去重状态还在，要求它重新上报一次。
                                        unawaited(
                                          controller
                                              .evaluateJavascript(
                                                source: BrowserSafeAreaProbe
                                                    .reportSource,
                                              )
                                              .catchError((_) => null),
                                        );
                                        await _syncRestoredState(controller);
                                        _restoredControllerReady = true;
                                        _revealRestoredSnapshot();
                                        return;
                                      }
                                      // 老 WKWebView 的 JS 运行时错误回传到 LogWriter。
                                      WebViewSettings.registerJsErrorReporter(
                                        controller,
                                      );
                                      final initialUrl =
                                          _pendingNavigation ?? widget.url;
                                      if (initialUrl.isNotEmpty) {
                                        _watchSearch(initialUrl);
                                        await _loadAddress(
                                          controller,
                                          initialUrl,
                                          _navigationRevision,
                                        );
                                      } else {
                                        _session.initialLoadRequested = true;
                                        if (mounted) {
                                          setState(() {
                                            _isLoading = false;
                                            _historyStateSettled = true;
                                          });
                                        }
                                      }
                                      _restoredControllerReady = true;
                                      _revealRestoredSnapshot();
                                      // Android: 启用 WebAuthn/PassKey 支持
                                      if (io.Platform.isAndroid) {
                                        WidgetsBinding.instance
                                            .addPostFrameCallback((_) {
                                              const MethodChannel(
                                                'com.fluxdo/webauthn',
                                              ).invokeMethod(
                                                'enableWebAuthentication',
                                              );
                                            });
                                      }
                                    },
                                    onEnterFullscreen: (_) => _setFullscreen(true),
                                    onExitFullscreen: (_) => _setFullscreen(false),
                                    onLoadStart: (controller, url) {
                                      if (!mounted) return;
                                      _resetSafeAreaCheck();
                                      _pageSafeArea = null;
                                      _session.safeArea = null;
                                      _invalidatePreview();
                                      _watchSearch(url?.toString() ?? '');
                                      setState(() {
                                        _navigationRevision += 1;
                                        _historyStateSettled = false;
                                        _isLoading = true;
                                        _progress = 0;
                                        _loadError = null;
                                        _stopped = false;
                                        if (_currentUrl != url?.toString()) {
                                          _currentTitle = '';
                                        }
                                        _currentUrl = url?.toString() ?? '';
                                      });
                                    },
                                    onProgressChanged: (controller, progress) {
                                      if (!mounted) return;
                                      setState(
                                        () => _progress = progress / 100,
                                      );
                                    },
                                    onScrollChanged: (_, _, _) {
                                      _invalidatePreview();
                                      _schedulePreview();
                                    },
                                    onLoadStop: (controller, url) async {
                                      if (!mounted ||
                                          url?.toString() != _currentUrl) {
                                        return;
                                      }
                                      _searchTimeout?.cancel();
                                      final revision = _navigationRevision;
                                      setState(() {
                                        _isLoading = false;
                                        if (_loadError == null) {
                                          _suggestAlternative = false;
                                        }
                                      });
                                      _schedulePreview();
                                      // 触发 cookie observer sweep (Android 主要触发点;
                                      // Apple 平台 native observer 已有覆盖, 此处与 debounce
                                      // 合并不会重复 sweep)
                                      CookieStoreObserver.instance
                                          .notifyExternalChange();
                                      await WebViewSettings.injectScrollFix(
                                        controller,
                                      );
                                      final title = await controller.getTitle();
                                      final canGoBack = await controller
                                          .canGoBack();
                                      final canGoForward = await controller
                                          .canGoForward();
                                      if (!mounted ||
                                          revision != _navigationRevision) {
                                        return;
                                      }
                                      final urlString = url?.toString();
                                      setState(() {
                                        _currentUrl = urlString ?? '';
                                        _canGoBack = canGoBack;
                                        _canGoForward = canGoForward;
                                        _historyStateSettled = true;
                                        if (title != null && title.isNotEmpty) {
                                          _currentTitle = title;
                                        }
                                      });
                                      if (widget.injectCss != null) {
                                        await controller.injectCSSCode(
                                          source: widget.injectCss!,
                                        );
                                      }
                                      // 记录浏览历史
                                      if (mounted &&
                                          _loadError == null &&
                                          urlString != null &&
                                          urlString.isNotEmpty) {
                                        ref
                                            .read(webHistoryProvider.notifier)
                                            .record(urlString, _currentTitle);
                                      }
                                    },
                                    onUpdateVisitedHistory:
                                        (controller, url, isReload) async {
                                          _invalidatePreview();
                                          _schedulePreview();
                                          final revision = _navigationRevision;
                                          final canGoBack = await controller
                                              .canGoBack();
                                          final canGoForward = await controller
                                              .canGoForward();
                                          if (!mounted ||
                                              revision != _navigationRevision) {
                                            return;
                                          }
                                          final urlString = url?.toString();
                                          setState(() {
                                            _currentUrl = urlString ?? '';
                                            _canGoBack = canGoBack;
                                            _canGoForward = canGoForward;
                                            _historyStateSettled = true;
                                          });
                                        },
                                    onTitleChanged: (controller, title) {
                                      if (!mounted) return;
                                      if (title != null && title.isNotEmpty) {
                                        setState(() => _currentTitle = title);
                                      }
                                    },
                                    onReceivedError:
                                        (controller, request, error) {
                                          if (error.type ==
                                              WebResourceErrorType.CANCELLED) {
                                            return;
                                          }
                                          if (request.isForMainFrame == false ||
                                              request.url.toString() !=
                                                  _currentUrl) {
                                            return;
                                          }
                                          _showLoadError(error.description);
                                        },
                                    onReceivedHttpError:
                                        (controller, request, response) {
                                          if (mounted &&
                                              !_closing &&
                                              !_minimized &&
                                              request.isForMainFrame == true &&
                                              request.url.toString() ==
                                                  _currentUrl &&
                                              (response.statusCode ?? 0) >=
                                                  400) {
                                            // HTTP 错误仍可能有可交互的站点说明或验证页。
                                            // 保留网页，只在真正的网络加载失败时显示应用错误页。
                                            _searchTimeout?.cancel();
                                            setState(
                                              () => _suggestAlternative = false,
                                            );
                                          }
                                        },
                                    onDownloadStarting: (controller, request) {
                                      if (!mounted) return null;
                                      final url = request.url.toString();
                                      ref
                                          .read(downloadProvider.notifier)
                                          .startDownload(
                                            url: url,
                                            suggestedFilename:
                                                request.suggestedFilename,
                                            mimeType: request.mimeType,
                                            contentLength:
                                                request.contentLength,
                                          );
                                      return null;
                                    },
                                  ),
                                  getController: () => _controller,
                                ),
                              ),
                            ),
                            if (_webViewSnapshot != null)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: AnimatedOpacity(
                                    key: const ValueKey(
                                      'browser-snapshot-cover',
                                    ),
                                    opacity: _snapshotVisible ? 1 : 0,
                                    duration:
                                        MediaQuery.disableAnimationsOf(context)
                                        ? Duration.zero
                                        : const Duration(milliseconds: 120),
                                    onEnd: () {
                                      if (mounted &&
                                          !_snapshotVisible &&
                                          !_minimized) {
                                        setState(() => _webViewSnapshot = null);
                                      }
                                    },
                                    child: ColoredBox(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surface,
                                      child: Image.memory(
                                        _webViewSnapshot!,
                                        fit: BoxFit.fitWidth,
                                        alignment: Alignment.topCenter,
                                        gaplessPlayback: true,
                                        errorBuilder: (_, _, _) =>
                                            const SizedBox.expand(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_loadError != null && !_addressEditing)
                        _buildLoadError(),
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !_addressEditing && _currentUrl.isNotEmpty,
                          child: AnimatedSwitcher(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 240),
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween(
                                      begin: const Offset(0, -.035),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                            child: _addressEditing || _currentUrl.isEmpty
                                ? _buildAddressPanel()
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _syncNativeSafeArea() async {
    if (defaultTargetPlatform != TargetPlatform.android ||
        !mounted ||
        _controller == null ||
        _closing ||
        _minimized) {
      return;
    }
    // Android 插件对保活实例返回 keepAliveId；不读取其内部扩展字段。
    final keepAliveId = _controller!.getViewId();
    if (keepAliveId is! String) return;
    await BrowserNativeSafeArea.attach(
      keepAliveId: keepAliveId,
    );
  }

  void _resetSafeAreaCheck() {
    _safeAreaRevision++;
    _safeAreaCheck?.cancel();
    _checkedUnsafe = null;
    _safeAreaMismatches = 0;
    _safeAreaPolicy.reset();
  }

  void _viewportGeometryChanged(BrowserViewportGeometry geometry) {
    if (!mounted || _fullscreen || _minimizing || _closing ||
        geometry == _viewportGeometry) {
      return;
    }
    setState(() {
      _viewportGeometry = geometry;
      _viewportUnsafe = geometry.unsafe;
      _resetSafeAreaCheck();
    });
  }

  void _setFullscreen(bool fullscreen) {
    if (!mounted || _fullscreen == fullscreen) return;
    setState(() {
      _fullscreen = fullscreen;
      _resetSafeAreaCheck();
    });
    // 插件的全屏视图直接挂在窗口下；原生观察器此时停止套用普通 WebView 边界。
    unawaited(_syncNativeSafeArea());
    if (!fullscreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _fullscreen) return;
        unawaited(_controller?.evaluateJavascript(
          source: BrowserSafeAreaProbe.reportSource,
        ).catchError((_) => null));
      });
    }
  }

  void _applyPageSafeArea(Object? raw) {
    final page = BrowserPageSafeArea.tryParse(raw);
    if (page == null || !mounted || page == _pageSafeArea) return;
    if (page.cover != _pageSafeArea?.cover) _resetSafeAreaCheck();
    if (page.env != _pageSafeArea?.env) {
      _safeAreaRevision++;
      _safeAreaCheck?.cancel();
      _checkedUnsafe = null;
    }
    _session.safeArea = page;
    setState(() => _pageSafeArea = page);
  }

  void _surfaceChanged() {
    if (mounted) setState(() {});
  }

  /// 只有留白可见且网页没有声明底色时才截图取色，其余时间不占用截图。
  void _syncSurfaceSampling() {
    if (!mounted) return;
    final render = _viewportKey.currentContext?.findRenderObject();
    final page = _pageSafeArea;
    _surfaceTheme.configure(
      enabled:
          page != null &&
          page.background == null &&
          _viewportUnsafe != EdgeInsets.zero &&
          !_safeAreaPolicy.edgeToEdge(page) &&
          _canCaptureSurface,
      document: (_session, _navigationRevision),
      bounds: render is RenderBox && render.hasSize
          ? render.localToGlobal(Offset.zero) & render.size
          : null,
      capture: _captureSurface,
    );
  }

  bool get _canCaptureSurface =>
      !_minimizing &&
      !_closing &&
      !_addressEditing &&
      !_isLoading &&
      _loadError == null &&
      _currentUrl.isNotEmpty &&
      _webViewSnapshot == null &&
      _webPointers == 0 &&
      _controller != null &&
      ModalRoute.of(context)?.isCurrent == true &&
      _routeAnimation?.status == AnimationStatus.completed;

  Future<SurfaceFrame?> _captureSurface(Rect region, {int? maxWidth}) async {
    final controller = _controller;
    final render = _viewportKey.currentContext?.findRenderObject();
    // 桌面端没有系统安全区，不会走到这里；Windows 的网页截图还会改动视口。
    if (!mounted ||
        defaultTargetPlatform == TargetPlatform.windows ||
        _surfaceCapturing ||
        _capturingPreview ||
        !_canCaptureSurface ||
        controller == null ||
        render is! RenderBox ||
        !render.hasSize) {
      return null;
    }
    final revision = _navigationRevision;
    final size = render.size;
    _surfaceCapturing = true;
    try {
      final frame = await WebViewSurfaceCapture.capture(
        takeScreenshot: (configuration) =>
            controller.takeScreenshot(screenshotConfiguration: configuration),
        platform: defaultTargetPlatform,
        viewport: render.localToGlobal(Offset.zero) & size,
        region: region,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        maxWidth: maxWidth ?? 48,
      );
      if (frame != null &&
          (!mounted ||
              revision != _navigationRevision ||
              controller != _controller ||
              size != _viewportKey.currentContext?.size)) {
        frame.image.dispose();
        return null;
      }
      return frame;
    } finally {
      _surfaceCapturing = false;
    }
  }

  // 普通网页也可能使用 env()；应用留边后，它实际收到的安全区应为零。
  EdgeInsets get _expectedPageInsets => _safeAreaPolicy.edgeToEdge(_pageSafeArea)
      ? _viewportUnsafe
      : EdgeInsets.zero;

  /// 等布局稳定后再比较，不以 viewport-fit=cover 作为使用 env() 的前提。
  void _scheduleSafeAreaCheck() {
    if (_fullscreen || _minimizing || _closing || _addressEditing ||
        _routeAnimation?.status != AnimationStatus.completed ||
        _viewportGeometry == null ||
        _safeAreaPolicy.nativeEnvReliable == false ||
        _expectedPageInsets == _checkedUnsafe) {
      return;
    }
    _checkedUnsafe = _expectedPageInsets;
    _safeAreaMismatches = 0;
    _safeAreaCheck?.cancel();
    // 原生视图改尺寸、网页收到 resize 都晚于 Flutter 布局，留出余量再读。
    _safeAreaCheck = Timer(
      const Duration(milliseconds: 400),
      _checkNativeSafeArea,
    );
  }

  Future<void> _checkNativeSafeArea() async {
    final controller = _controller;
    final expected = _expectedPageInsets;
    final revision = _safeAreaRevision;
    if (!mounted ||
        controller == null ||
        _minimizing ||
        _closing ||
        _addressEditing ||
        _fullscreen ||
        _pageSafeArea == null ||
        _safeAreaPolicy.nativeEnvReliable == false) {
      return;
    }
    Object? raw;
    try {
      raw = await controller.evaluateJavascript(
        source: BrowserSafeAreaProbe.measureSource,
      );
    } catch (_) {
      return;
    }
    final page = BrowserPageSafeArea.tryParse(raw);
    if (!mounted ||
        page == null ||
        revision != _safeAreaRevision || _fullscreen || _minimizing ||
        _closing || _addressEditing ||
        expected != _expectedPageInsets ||
        _safeAreaPolicy.nativeEnvReliable == false) {
      return;
    }
    final matches = BrowserSafeAreaPolicy.matches(expected, page.env);
    if (matches == null) return;
    if (matches) {
      _safeAreaPolicy.record(reliable: true);
      return;
    }
    // 连续两次对不上才下结论，排除原生视图尚未改完尺寸的窗口。
    if (++_safeAreaMismatches < 2) {
      _safeAreaCheck = Timer(
        const Duration(milliseconds: 800),
        _checkNativeSafeArea,
      );
      return;
    }
    FrameJankMonitor.logEvent(
      'WEBVIEW',
      'safe-area env mismatch expected=$expected observed=${page.env}',
    );
    _safeAreaPolicy.record(reliable: false);
    setState(() {});
  }

  /// 就地展开地址栏，选中完整网址并显示本地建议。
  void _beginAddressEditing() {
    if (_closing || _minimizing || _addressEditing) return;
    _resetSafeAreaCheck();
    if (_finding) _endFind();
    _addressController.value = TextEditingValue(
      text: _currentUrl,
      selection: TextSelection(baseOffset: 0, extentOffset: _currentUrl.length),
    );
    setState(() => _addressEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _addressEditing) _addressFocus.requestFocus();
    });
  }

  void _endAddressEditing() {
    _addressFocus.unfocus();
    if (mounted) setState(() => _addressEditing = false);
  }

  void _editSuggestion(String url) {
    if (!_addressEditing) _beginAddressEditing();
    _addressController.value = TextEditingValue(
      text: url,
      selection: TextSelection.collapsed(offset: url.length),
    );
    _addressFocus.requestFocus();
  }

  Widget _buildAddressPanel() => BrowserAddressPanel(
    key: const ValueKey('browser-address-panel'),
    query: _addressEditing ? _addressController.text : '',
    currentUrl: _currentUrl,
    currentTitle: _currentTitle,
    engine: ref.watch(browserSearchEngineProvider),
    bookmarks: ref.watch(webBookmarkProvider),
    history: ref.watch(webHistoryProvider),
    onNavigate: _navigateToUrl,
    onEdit: _editSuggestion,
    onEngineChanged: ref.read(browserSearchEngineProvider.notifier).select,
    onCopyCurrent: _copyUrl,
    onReturnToPage: _endAddressEditing,
  );

  void _navigateToUrl(String input) {
    final target = BrowserNavigationTarget.parse(
      input,
      ref.read(browserSearchEngineProvider),
    );
    if (target == null) return;
    _endAddressEditing();
    if (_finding) _endFind();
    final url = target.uri.toString();
    setState(() {
      _pendingNavigation = url;
      _currentUrl = url;
      _currentTitle = '';
      _loadError = null;
      _isLoading = true;
      _stopped = false;
      _progress = 0;
      _historyStateSettled = false;
      _navigationRevision++;
    });
    _watchSearch(url);
    final controller = _controller;
    if (controller != null) {
      unawaited(_loadAddress(controller, url, _navigationRevision));
    }
  }

  Future<void> _loadAddress(
    InAppWebViewController controller,
    String url,
    int revision,
  ) async {
    try {
      await WebViewCookiePriming.instance.prime(url);
      if (!mounted ||
          _closing ||
          _minimized ||
          revision != _navigationRevision) {
        return;
      }
      _session.initialLoadRequested = true;
      _pendingNavigation = null;
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (error) {
      if (mounted && revision == _navigationRevision) {
        _showLoadError(error.toString());
      }
    }
  }

  void _closeBrowser() {
    if (_closing) return;
    _closing = true;
    _searchTimeout?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    final route = ModalRoute.of(context);
    if (route is BrowserPageRoute) route.minimizing = false;
    Navigator.of(context).pop();
  }

  void _reloadOrStop() {
    final controller = _controller;
    if (controller == null) return;
    if (_isLoading) {
      _stopped = true;
      _searchTimeout?.cancel();
      setState(() {
        _isLoading = false;
        _suggestAlternative = false;
      });
      unawaited(controller.stopLoading());
    } else {
      _stopped = false;
      setState(() {
        _isLoading = true;
        _loadError = null;
        _progress = 0;
      });
      _watchSearch(_currentUrl);
      if (_session.initialLoadRequested) {
        unawaited(controller.reload());
      } else {
        unawaited(_loadAddress(controller, _currentUrl, _navigationRevision));
      }
    }
  }

  void _watchSearch(String url) {
    _searchTimeout?.cancel();
    final uri = Uri.tryParse(url);
    final google =
        uri != null &&
        (uri.host == 'google.com' || uri.host.endsWith('.google.com')) &&
        uri.path == '/search';
    _googleQuery = google ? uri.queryParameters['q'] : null;
    _suggestAlternative = false;
    if (_googleQuery?.isNotEmpty != true) return;
    _searchTimeout = Timer(const Duration(seconds: 12), () {
      if (mounted && !_closing && !_minimized && !_stopped && _isLoading) {
        setState(() => _suggestAlternative = true);
      }
    });
  }

  void _showLoadError(String error) {
    if (!mounted || _closing || _minimized || _stopped) return;
    _searchTimeout?.cancel();
    setState(() {
      _loadError = error;
      _isLoading = false;
      _historyStateSettled = true;
      _suggestAlternative = _googleQuery?.isNotEmpty == true;
    });
  }

  void _searchWithBingOnce() {
    final query = _googleQuery;
    if (query == null || query.isEmpty) return;
    _navigateToUrl(BrowserSearchEngine.bing.search(query).toString());
  }

  Widget _buildSearchFallback() => Material(
    key: const ValueKey('browser-slow-search'),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Align(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: browserAddressMaxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final message = Text(
                context.l10n.webview_googleSlow,
                style: Theme.of(context).textTheme.bodySmall,
              );
              final action = TextButton(
                onPressed: _searchWithBingOnce,
                child: Text(context.l10n.webview_tryBing),
              );
              final dismiss = IconButton(
                tooltip: context.l10n.common_close,
                onPressed: () => setState(() => _suggestAlternative = false),
                icon: const Icon(Symbols.close_rounded, size: 18),
              );
              final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
              if (constraints.maxWidth < (largeText ? 480 : 340)) {
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: message),
                        dismiss,
                      ],
                    ),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: message),
                  action,
                  dismiss,
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _buildLoadError() {
    final alternative = _suggestAlternative && _googleQuery?.isNotEmpty == true;
    final l10n = context.l10n;
    return ColoredBox(
      key: const ValueKey('browser-load-error'),
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.wifi_off_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 20),
                Text(
                  alternative
                      ? l10n.webview_searchFailed
                      : l10n.webview_loadFailed,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  alternative ? _googleQuery! : browserDisplayHost(_currentUrl),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  alternative
                      ? l10n.webview_googleUnavailable
                      : l10n.webview_checkConnection,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (alternative) ...[
                      FilledButton.icon(
                        onPressed: _searchWithBingOnce,
                        icon: const Icon(Symbols.search_rounded),
                        label: Text(l10n.webview_tryBing),
                      ),
                      OutlinedButton.icon(
                        onPressed: _reloadOrStop,
                        icon: const Icon(Symbols.refresh_rounded),
                        label: Text(l10n.common_retry),
                      ),
                    ] else
                      FilledButton.icon(
                        onPressed: _reloadOrStop,
                        icon: const Icon(Symbols.refresh_rounded),
                        label: Text(l10n.common_retry),
                      ),
                  ],
                ),
                TextButton(
                  onPressed: _beginAddressEditing,
                  child: Text(context.l10n.webview_editAddress),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _beginFind() {
    if (_currentUrl.isEmpty || _controller == null || _finding) return;
    if (_addressEditing) _endAddressEditing();
    setState(() {
      _finding = true;
      _matchCount = 0;
      _matchIndex = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _finding) _findFocus.requestFocus();
    });
  }

  void _endFind() {
    _findDebounce?.cancel();
    _findFocus.unfocus();
    _findText.clear();
    if (mounted) {
      setState(() {
        _finding = false;
        _matchCount = 0;
      });
    }
    unawaited(_findController.clearMatches());
  }

  void _findChanged(String query) {
    _findDebounce?.cancel();
    setState(() {
      _matchCount = 0;
      _matchIndex = 0;
    });
    _findDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || !_finding) return;
      if (query.isEmpty) {
        unawaited(_findController.clearMatches());
      } else {
        unawaited(_findController.findAll(find: query));
      }
    });
  }

  Widget _buildFindBar() => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('browser-find-input'),
              controller: _findText,
              focusNode: _findFocus,
              decoration: InputDecoration(
                hintText: context.l10n.webview_findInPage,
              ).withoutBorder(),
              onChanged: _findChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (text) {
                _findDebounce?.cancel();
                unawaited(_findController.findAll(find: text));
              },
            ),
          ),
          Text(
            '${_matchCount == 0 ? 0 : _matchIndex + 1}/$_matchCount',
            semanticsLabel: context.l10n.webview_findMatches(_matchCount),
          ),
          IconButton(
            tooltip: context.l10n.webview_previousMatch,
            onPressed: _matchCount == 0
                ? null
                : () => _findController.findNext(forward: false),
            icon: const Icon(Symbols.keyboard_arrow_up_rounded),
          ),
          IconButton(
            tooltip: context.l10n.webview_nextMatch,
            onPressed: _matchCount == 0
                ? null
                : () => _findController.findNext(),
            icon: const Icon(Symbols.keyboard_arrow_down_rounded),
          ),
          IconButton(
            tooltip: context.l10n.common_close,
            onPressed: _endFind,
            icon: const Icon(Symbols.close_rounded),
          ),
        ],
      ),
    ),
  );

  Future<void> _sharePage() async {
    if (_currentUrl.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: _currentUrl,
          title: _currentTitle.isEmpty ? null : _currentTitle,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      if (mounted) ToastService.showError(context.l10n.webview_shareFailed);
    }
  }

  /// 允许 WebView 内部加载的 scheme。
  static const _allowedSchemes = {'http', 'https', 'about', 'data', 'blob'};

  /// 拦截 URL 加载：对非 HTTP(S) 的应用链接弹出确认对话框
  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (url == null) return NavigationActionPolicy.ALLOW;

    final scheme = url.scheme.toLowerCase();

    // HTTP(S) 和内部 scheme 正常加载
    if (_allowedSchemes.contains(scheme)) {
      return NavigationActionPolicy.ALLOW;
    }

    // javascript: 静默阻止
    if (scheme == 'javascript') {
      return NavigationActionPolicy.CANCEL;
    }

    // 应用自有 scheme 直接交给深链服务，避免授权回调被当成外部应用
    // 链接弹出确认框，或在 WebView 内导航失败。
    if (scheme == 'fluxdo' || scheme == 'discourse') {
      DeepLinkService.instance.handleUri(url);
      return NavigationActionPolicy.CANCEL;
    }

    // 其他 scheme（应用链接）：解析目标应用并弹出确认对话框
    final urlString = url.toString();
    if (!mounted) return NavigationActionPolicy.CANCEL;

    // 通过原生代码解析目标应用信息
    final appInfo = await AppLinkService.resolveAppLink(urlString);

    if (!mounted) return NavigationActionPolicy.CANCEL;

    final confirmed = await showAppLinkConfirmDialog(
      context,
      urlString,
      appName: appInfo.appName,
      appIcon: appInfo.appIcon,
    );

    if (confirmed == true) {
      final success = await AppLinkService.launchAppLink(urlString);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_noAppForLink);
      }
    }

    // 无论用户选择如何，都不让 WebView 加载此 URL
    return NavigationActionPolicy.CANCEL;
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'find':
        _beginFind();
        break;
      case 'share':
        _sharePage();
        break;
      case 'library':
        Navigator.of(context).push(
          InteractionPageRoute<void>(builder: (_) => const MyBrowserPage()),
        );
        break;
      case 'toggle_bookmark':
        _toggleBookmark();
        break;
      case 'copy_url':
        _copyUrl();
        break;
      case 'open_external':
        _openInExternalBrowser();
        break;
    }
  }

  void _toggleBookmark() {
    if (_currentUrl.isEmpty) return;
    final added = ref
        .read(webBookmarkProvider.notifier)
        .toggle(_currentUrl, _currentTitle);
    ToastService.showSuccess(
      added
          ? S.current.webview_bookmarkAdded
          : S.current.webview_bookmarkRemoved,
    );
  }

  Future<void> _handleBackNavigation() async {
    final controller = _controller;
    if (controller == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final canGoBack = await controller.canGoBack();
    if (canGoBack) {
      await controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyUrl() async {
    if (_currentUrl.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: _currentUrl));
      if (mounted) {
        ToastService.showSuccess(S.current.common_linkCopied);
      }
    }
  }

  Future<void> _openInExternalBrowser() async {
    if (_currentUrl.isEmpty) return;

    try {
      final success = await launchInExternalBrowser(_currentUrl);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_cannotOpenBrowser);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.webview_openFailed(e.toString()));
      }
    }
  }
}
