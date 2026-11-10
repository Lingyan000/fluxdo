import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'mini_app_fullscreen.dart';
import 'mini_app_window_bridge.dart';
import 'mini_app_window_session.dart';

import '../../constants.dart';
import '../../services/local_notification_service.dart' show navigatorKey;
import '../../l10n/s.dart';
import '../../providers/core_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../services/auth_session.dart';
import '../../services/browser_tabs.dart';
import '../../services/toast_service.dart';
import '../../services/browser_surface_theme.dart';
import '../../services/navigation/browser_dock_observer.dart';
import '../../services/navigation/minimizable_page_route.dart';
import '../../services/log/log_writer.dart';
import '../../services/embedded_browser_controller_pool.dart';
import '../../services/network/cookie/webview_cookie_priming.dart';
import '../../services/navigation/app_route_observer.dart';
import '../../services/webview_settings.dart';
import '../../services/webview_surface_capture.dart';
import '../../services/windows_webview_environment_service.dart';
import '../../utils/link_launcher.dart';
import '../../utils/platform_utils.dart';
import '../../utils/dialog_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/external_link_confirm_dialog.dart';
import '../../widgets/browser/browser_dock_motion.dart';
import 'mini_app.dart';
import 'mini_app_detail_page.dart';
import 'mini_app_feedback_dialog.dart';
import 'mini_app_host_adapter.dart';
import 'mini_app_modal_blur.dart';
import 'mini_app_media_lifecycle.dart';
import 'mini_app_runner_chrome.dart';
import 'mini_app_runtime_surface.dart';
import '../../utils/error_utils.dart';
import 'mini_app_providers.dart';
import 'mini_app_url.dart';
import 'mini_app_engine.dart';
import 'mini_app_tab_session.dart';
import 'mini_app_lightweight_host.dart';
import 'mini_app_launch_report.dart';
import 'mini_app_panel_shell.dart';
import 'mini_app_panel_motion.dart';
import 'mini_app_glass_backdrop.dart';

enum _PanelResult { openPage }

class MiniAppRunnerPage extends ConsumerStatefulWidget {
  const MiniAppRunnerPage({
    super.key,
    required this.details,
    this.launchUri,
    this.visible = true,
    this.onMinimize,
    this.onFullscreenChanged,
    this.independentWindow = false,
    this.onCloseWindow,
    this.initialEngine,
    this.tabSession,
    this.asPanel = false,
    this.panelMotion,
  });
  final MiniAppDetails details;
  final Uri? launchUri;
  final bool visible;
  final VoidCallback? onMinimize;
  final ValueChanged<bool>? onFullscreenChanged;
  final bool independentWindow;
  final VoidCallback? onCloseWindow;
  final MiniAppEngine? initialEngine;
  final MiniAppTabSession? tabSession;
  final bool asPanel;
  final MiniAppPanelMotion? panelMotion;

  static Future<void> open(
    BuildContext context,
    MiniAppDetails details, {
    Uri? launchUri,
    bool asPanel = false,
  }) async {
    final tabs = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(browserTabsProvider);
    final entry = MiniAppUrl.embed(
      launchUri?.toString() ?? details.embedUrl,
      details.app.id,
      AppConstants.baseUrl,
    );
    final saved = tabs.tabs
        .whereType<MiniAppTabSession>()
        .where((tab) => tab.entry == entry && !tab.isClosed)
        .firstOrNull;
    final session = saved == null
        ? MiniAppTabSession(
            details: details,
            entry: entry,
            engine: ProviderScope.containerOf(
              context,
              listen: false,
            ).read(preferencesProvider).miniAppEngine,
          )
        : await tabs.take(saved) as MiniAppTabSession?;
    if (session == null) return;
    session.preferPanel = asPanel;
    if (!context.mounted ||
        session.isClosed ||
        !AuthSession().isValid(session.accountGeneration!)) {
      await session.close();
      return;
    }
    await restore(
      Navigator.of(context, rootNavigator: true),
      session,
      fromDock: saved != null,
    );
  }

  static Future<void> restore(
    NavigatorState navigator,
    MiniAppTabSession session, {
    bool fromDock = true,
  }) async {
    if (session.isClosed ||
        !AuthSession().isValid(session.accountGeneration!)) {
      await session.close();
      return;
    }
    if (session.preferPanel) {
      ModalRoute<dynamic>? panelRoute;
      final motion = BrowserDockViewport.motionOf(navigator.context);
      final panelMotion = !PlatformUtils.isDesktop
          ? MiniAppPanelMotion(
              navigator,
              motion,
              session,
              reduceMotion: MediaQuery.disableAnimationsOf(navigator.context),
            )
          : null;
      Widget panelBuilder(BuildContext context) {
        panelRoute = ModalRoute.of(context);
        return MiniAppPanelShell(
          motion: panelMotion,
          onHeightChanged: panelMotion?.updateExtent,
          builder: (onFullscreenChanged) => MiniAppRunnerPage(
            details: session.details,
            launchUri: session.entry,
            initialEngine: session.engine,
            tabSession: session,
            asPanel: true,
            panelMotion: panelMotion,
            onFullscreenChanged: onFullscreenChanged,
          ),
        );
      }

      final pending = PlatformUtils.isDesktop
          ? showAppDialog<_PanelResult>(
              context: navigator.context,
              routeSettings: const RouteSettings(name: miniAppPageRouteName),
              builder: panelBuilder,
            )
          : showAppBottomSheet<_PanelResult>(
              context: navigator.context,
              useRootNavigator: true,
              routeSettings: const RouteSettings(name: miniAppPageRouteName),
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              constraints: const BoxConstraints(maxWidth: double.infinity),
              // 网页内部手势交给 WebView，仅顶部把手/工具栏驱动收起。
              enableDrag: false,
              transitionAnimationController: panelMotion?.controller,
              onDisposed: panelMotion?.dispose,
              sheetAnimationStyle: panelMotion == null
                  ? null
                  : const AnimationStyle(
                      curve: Curves.linear,
                      reverseCurve: Curves.linear,
                    ),
              builder: panelBuilder,
            );
      panelMotion?.start(fromDock: fromDock);
      final result = await pending;
      if (panelMotion != null) {
        panelMotion.didPop();
        await panelRoute?.completed;
      }
      if (result != _PanelResult.openPage) return;
      // 只有确认旧平台视图已卸载，才能将同一实例交给完整页面。
      await panelRoute?.completed;
      await session.whenDetached;
      if (!navigator.mounted ||
          session.isClosed ||
          !AuthSession().isValid(session.accountGeneration!)) {
        await session.close();
        return;
      }
      session.preferPanel = false;
    }
    await navigator.push<void>(
      MinimizablePageRoute<void>(
        name: miniAppPageRouteName,
        fromDock: fromDock,
        motion: BrowserDockViewport.motionOf(navigator.context),
        session: session,
        builder: (_) => MiniAppRunnerPage(
          details: session.details,
          launchUri: session.entry,
          initialEngine: session.engine,
          tabSession: session,
        ),
      ),
    );
  }

  @override
  ConsumerState<MiniAppRunnerPage> createState() => _MiniAppRunnerPageState();
}

class _MiniAppRunnerPageState extends ConsumerState<MiniAppRunnerPage>
    with WidgetsBindingObserver, RouteAware {
  InAppWebViewController? _controller;
  // 插件在 Widget 构造时创建平台包装对象，布局变化时复用同一个实例。
  InAppWebView? _webView;
  EmbeddedBrowserLease? _lease;
  Timer? _stateTimer;
  Timer? _restoreUiTimer;
  Timer? _bootTimer;
  late MiniAppEngine _engine;
  int _viewEpoch = 0;
  bool _switchingEngine = false;
  MiniAppTabSession? get _tab => widget.tabSession;
  bool _minimized = false, _minimizing = false;
  bool _transferring = false;
  Uint8List? _minimizePreview;
  Animation<double>? _restoreAnimation;
  String? _lightweightHtml;
  final _launchClock = Stopwatch();
  int? _createdMs, _cookiesReadyMs;
  num? _reportedStart;
  int? _reportedHostFailureEpoch;
  late MiniAppDetails _details;
  Uri? _entry;
  late final int _generation;
  late final UnmodifiableListView<UserScript> _userScripts;
  bool _active = false, _loading = true, _covered = false;
  bool _backgrounded = false;
  bool _routeSuspended = false;
  MiniAppMediaLifecycle _localMediaLifecycle = MiniAppMediaLifecycle();
  MiniAppMediaBinding? _mediaBinding;
  bool _nativeFullscreen = false, _platformFullscreen = false;
  int? _pollingEpoch;
  bool _soundBusy = false,
      _compatible = false,
      _recorded = false,
      _actionBusy = false;
  bool? _muted;
  bool _documentFullscreen = false;
  bool _keyboardVisible = false;
  MiniAppOrientation? _orientationMode;
  bool _soundKnown = false;
  int _soundProbes = 0;
  int _nativeOverlays = 0;
  final _modalBlur = MiniAppModalBlur();
  final _viewportKey = GlobalKey();
  final _textureCaptureKey = GlobalKey();
  final _pageKey = GlobalKey();
  final _toolbarKey = GlobalKey();
  final _surfaceTheme = BrowserSurfaceTheme();
  bool _pointerActive = false;
  final _surfacePointers = <int>{};
  Timer? _pointerIdle;
  bool _hostLoading = false, _hostFailed = false, _webPermission = false;
  bool _hostReady = false;
  int _documentEpoch = 0;
  String _hostStage = '', _hostDetail = '';
  double? _hostProgress;
  MiniAppPermissionRequest? _permission;
  String? _webOnlyPermission;
  bool _permissionBusy = false;
  Completer<bool>? _permissionAnswer;
  int _permissionRevision = 0;
  Object? _error;
  int? _reportedStateReadEpoch;
  bool get _fullscreen =>
      _nativeFullscreen || _documentFullscreen || _platformFullscreen;
  final _systemUi = MiniAppFullscreen(
    restoreOrientations: () => PreferencesNotifier.isPortraitLocked
        ? [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
        : [],
  );

  void _updateDisplay(VoidCallback change) {
    if (!mounted) return;
    final wasFullscreen = _fullscreen;
    setState(change);
    if (!_fullscreen) _restoreUiTimer?.cancel();
    if (_fullscreen != wasFullscreen) {
      _applySystemUi(_fullscreen);
      widget.onFullscreenChanged?.call(_fullscreen);
    }
  }

  void _setFullscreen(bool fullscreen) {
    if (fullscreen && !widget.visible) return;
    _updateDisplay(() => _nativeFullscreen = fullscreen);
  }

  void _leaveFullscreen() {
    unawaited(
      _evaluate('document.exitFullscreen?.().catch(() => {});')
          .catchError((_) => null),
    );
    _updateDisplay(() {
      _nativeFullscreen = false;
      _documentFullscreen = false;
      _platformFullscreen = false;
    });
  }

  Future<void> _orientation(MiniAppOrientation orientation) async {
    try {
      await _systemUi.setOrientation(orientation);
      if (mounted) _orientationMode = orientation;
    } catch (_) {
      if (mounted) _notice(context.l10n.miniApp_actionUnavailable);
    }
  }

  void _rotate() {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    unawaited(
      _orientation(
        landscape ? MiniAppOrientation.portrait : MiniAppOrientation.landscape,
      ),
    );
  }

  void _applySystemUi(bool fullscreen) {
    unawaited(_systemUi.setFullscreen(fullscreen).catchError((_) {}));
  }

  @override
  void initState() {
    super.initState();
    _backgrounded = switch (WidgetsBinding.instance.lifecycleState) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => true,
      _ => false,
    };
    _details = widget.details;
    _engine =
        widget.initialEngine ?? ref.read(preferencesProvider).miniAppEngine;
    _generation = _tab?.accountGeneration ?? AuthSession().generation;
    _tab?.attach();
    _lightweightHtml = _tab?.lightweightHtml;
    _recorded = _tab?.recorded ?? false;
    if (_tab != null) _tab!.onRevoked = _revoked;
    WidgetsBinding.instance.addObserver(this);
    AuthSession().generationChanges.addListener(_sessionChanged);
    try {
      _entry = MiniAppUrl.embed(
        widget.launchUri?.toString() ?? _details.embedUrl,
        _details.app.id,
        AppConstants.baseUrl,
      );
      _userScripts = UnmodifiableListView([
        ...WebViewSettings.compatPolyfillScripts,
        UserScript(
          forMainFrameOnly: false,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          source: MiniAppHostAdapter.frameViewportScript(
            Uri.parse(AppConstants.baseUrl),
          ),
        ),
        UserScript(
          forMainFrameOnly: true,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          source: MiniAppHostAdapter.navigationScript(_entry!),
        ),
        UserScript(
          forMainFrameOnly: true,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          source:
              '''(() => {
            if (location.origin !== ${jsonEncode(_entry!.origin)} ||
                location.pathname !== ${jsonEncode(_entry!.path)}) return;
            const install = () => {
              if (!document.documentElement) return false;
              const style = document.createElement('style');
              style.textContent = ${jsonEncode(MiniAppHostAdapter.css)};
              document.documentElement.appendChild(style);
              return true;
            };
            if (!install()) {
              const observer = new MutationObserver(() => {
                if (install()) observer.disconnect();
              });
              observer.observe(document, {childList: true});
            }
          })()''',
        ),
      ]);
      scheduleMicrotask(_activate);
    } catch (e) {
      _error = e;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardVisible = View.of(context).viewInsets.bottom > 0;
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
    if (route is MinimizablePageRoute) route.onReturnToDock = _returnToDock;
    widget.panelMotion
      ?..onReturnToDock = _returnToDock
      ..canDrag = () =>
          mounted &&
          widget.visible &&
          !_fullscreen &&
          !_minimized &&
          !_transferring &&
          _permission == null &&
          !_switchingEngine &&
          _nativeOverlays == 0 &&
          ModalRoute.of(context)?.isCurrent == true;
    final animation = route is MinimizablePageRoute && route.fromDock
        ? route.transitionAnimation
        : widget.panelMotion?.controller.view;
    if (_restoreAnimation == null && animation != null) {
      _restoreAnimation = animation;
      widget.panelMotion?.moving.addListener(_panelMotionChanged);
      if (animation.status != AnimationStatus.completed) {
        _minimizePreview = _tab?.preview;
        animation.addStatusListener(_restoreFinished);
      }
    }
  }

  void _panelMotionChanged() {
    if (!mounted) return;
    if (widget.panelMotion?.moving.value == true) {
      _stateTimer?.cancel();
    } else if (!_minimized) {
      unawaited(_startPolling());
    }
    _syncSurfaceSampling();
  }

  void _restoreFinished(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted || _minimized) return;
    _restoreAnimation?.removeStatusListener(_restoreFinished);
    setState(() => _minimizePreview = null);
  }

  @override
  void didUpdateWidget(MiniAppRunnerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (!widget.visible) {
      _modalBlur.reset();
      _stateTimer?.cancel();
      _restoreUiTimer?.cancel();
      // 折叠不销毁平台视图，也不继续占用全屏、方向或媒体播放。
      _nativeFullscreen = _documentFullscreen = _platformFullscreen = false;
      _orientationMode = null;
      unawaited(
        _evaluate('document.exitFullscreen?.().catch(() => {});')
            .catchError((_) => null),
      );
      unawaited(_systemUi.suspend().catchError((_) {}));
    }
    _syncVisibility();
  }

  void _syncVisibility() {
    _syncMediaState();
    if (mounted && widget.visible && _active && !_covered && !_backgrounded) {
      unawaited(_startPolling());
    }
  }

  @override
  void didPushNext() {
    _stateTimer?.cancel();
    _routeSuspended = _nativeOverlays == 0;
    if (mounted) setState(() => _covered = true);
    _syncMediaState();
  }

  @override
  void didPopNext() {
    if (mounted) setState(() => _covered = false);
    _routeSuspended = false;
    _syncMediaState();
    if (_fullscreen && widget.visible) _applySystemUi(true);
    if (_active && widget.visible) _startPolling();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _modalBlur.refresh();
    });
    final keyboardVisible = View.of(context).viewInsets.bottom > 0;
    if (_keyboardVisible && !keyboardVisible && _fullscreen) {
      // Android 收键盘后的一秒内不接受系统栏隐藏请求，等限制结束再恢复。
      _restoreUiTimer?.cancel();
      _restoreUiTimer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted && _fullscreen && !_covered && !_keyboardVisible) {
          _applySystemUi(true);
        }
      });
    } else if (keyboardVisible) {
      _restoreUiTimer?.cancel();
    }
    _keyboardVisible = keyboardVisible;
  }

  void _activate() {
    if (!mounted || _entry == null || !AuthSession().isValid(_generation)) {
      return;
    }
    if (Platform.isWindows) {
      _lease = _tab == null
          ? EmbeddedBrowserControllerPool.instance.tryAcquire(
              priority: EmbeddedBrowserPriority.iframe,
              onRevoked: _revoked,
            )
          : (_tab!.acquireBrowserLease() ? _tab!.browserLease : null);
      if (_lease == null) {
        setState(() => _error = StateError(context.l10n.miniApp_browserBusy));
        return;
      }
    }
    setState(() {
      _launchClock
        ..reset()
        ..start();
      _createdMs = _cookiesReadyMs = null;
      _reportedStart = null;
      _webView = null;
      _active = true;
      _loading = true;
      _error = null;
    });
  }

  void _revoked() {
    if (!mounted) return;
    _modalBlur.reset();
    _viewEpoch++;
    _documentEpoch++;
    _invalidatePermissionAnswer();
    _bootTimer?.cancel();
    _stateTimer?.cancel();
    _controller = null;
    _resetMediaLifecycle();
    _lease?.release();
    _lease = null;
    _tab?.browserLease = null;
    setState(() {
      _active = false;
      _permission = null;
      _error = StateError(context.l10n.miniApp_browserBusy);
    });
    unawaited(_discardInactiveTabView());
  }

  void _sessionChanged() {
    if (!mounted) return;
    _modalBlur.reset();
    _viewEpoch++;
    _documentEpoch++;
    _invalidatePermissionAnswer();
    _bootTimer?.cancel();
    if (_fullscreen) _leaveFullscreen();
    unawaited(_systemUi.restore().catchError((_) {}));
    _stateTimer?.cancel();
    _controller = null;
    _resetMediaLifecycle();
    _lease?.release();
    _lease = null;
    _tab?.browserLease = null;
    setState(() {
      _active = false;
      _permission = null;
      _error = StateError(context.l10n.miniApp_sessionChanged);
    });
    unawaited(_discardInactiveTabView());
  }

  Future<void> _discardInactiveTabView() async {
    final tab = _tab;
    if (tab == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!_active) await tab.discardWebView();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stateTimer?.cancel();
      _syncSurfaceSampling();
      // Android 的原生 select、日期选择器也会让 Activity 短暂失焦。
      // inactive 仍可见，不暂停 WebView、不操作网页焦点或重新设置系统栏。
      if (state != AppLifecycleState.inactive && !_backgrounded) {
        _backgrounded = true;
        _syncMediaState();
      }
    } else {
      final restore = _backgrounded;
      _backgrounded = false;
      _syncMediaState();
      if (!_active || !widget.visible) return;
      if (restore) {
        if (_fullscreen) _applySystemUi(true);
        if (_orientationMode case final orientation?) {
          unawaited(_orientation(orientation));
        }
      }
      _startPolling();
      _syncSurfaceSampling();
    }
  }

  @override
  void dispose() {
    _localMediaLifecycle.dispose();
    _invalidatePermissionAnswer();
    _restoreAnimation?.removeStatusListener(_restoreFinished);
    widget.panelMotion?.moving.removeListener(_panelMotionChanged);
    widget.panelMotion
      ?..onReturnToDock = null
      ..canDrag = null;
    _pointerIdle?.cancel();
    _surfaceTheme.dispose();
    _bootTimer?.cancel();
    _viewEpoch++;
    _modalBlur.dispose();
    unawaited(_systemUi.restore().catchError((_) {}));
    _stateTimer?.cancel();
    _restoreUiTimer?.cancel();
    AuthSession().generationChanges.removeListener(_sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    final tab = _tab;
    if (tab == null) {
      _lease?.release();
    } else {
      // 仅主动收起保留原生实例，且可在底栏看到并关闭；返回/关闭必须销毁。
      WidgetsBinding.instance.addPostFrameCallback((_) => tab.detach());
      if (!_minimized && !_transferring) unawaited(tab.close());
    }
    super.dispose();
  }

  void _openAsPage() {
    final tab = _tab;
    if (tab == null || _transferring || _minimizing || _permission != null) {
      return;
    }
    _transferring = true;
    tab
      ..details = _details
      ..engine = _engine
      ..recorded = _recorded
      ..lightweightHtml = _lightweightHtml;
    Navigator.of(context).pop(_PanelResult.openPage);
  }

  Future<void> _minimize() async {
    final tab = _tab;
    if (tab == null ||
        _minimizing ||
        _minimized ||
        _permission != null ||
        _switchingEngine ||
        !Navigator.of(context).canPop()) {
      return;
    }
    setState(() => _minimizing = true);
    FocusManager.instance.primaryFocus?.unfocus();
    _stateTimer?.cancel();
    if (_fullscreen) _leaveFullscreen();
    if (widget.panelMotion != null) {
      // 弹窗只平移实时原生表面；不能在用户操作后先同步截屏再开始动画。
      _returnToDock();
      return;
    }
    final snapshot = _visualCapturePending
        ? Future<Uint8List?>.value()
        : Future<Uint8List?>.sync(
            () => _controller?.takeScreenshot(
              screenshotConfiguration: ScreenshotConfiguration(
                snapshotWidth: 360 / MediaQuery.devicePixelRatioOf(context),
                compressFormat: CompressFormat.JPEG,
                quality: 65,
              ),
            ),
          ).timeout(const Duration(milliseconds: 140)).catchError((_) => null);
    await _systemUi.suspend().catchError((_) {});
    final preview = await snapshot;
    if (!mounted ||
        tab.isClosed ||
        !AuthSession().isValid(_generation) ||
        ModalRoute.of(context)?.isCurrent != true) {
      if (mounted) setState(() => _minimizing = false);
      if (mounted) _syncMediaState();
      return;
    }
    tab.preview = preview;
    _returnToDock();
  }

  /// 反向拖回时直接交还底栏；媒体暂停异步处理，不让手势等待截图。
  void _returnToDock() {
    final tab = _tab;
    if (!mounted || tab == null || tab.isClosed || _minimized) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _stateTimer?.cancel();
    tab
      ..details = _details
      ..engine = _engine
      ..recorded = _recorded
      ..lightweightHtml = _lightweightHtml;
    final tabs = ref.read(browserTabsProvider);
    tab.onRevoked = () => tabs.close(tab);
    setState(() {
      _minimized = true;
      _minimizePreview = widget.panelMotion == null ? tab.preview : null;
    });
    _syncMediaState();
    final route = ModalRoute.of(context);
    if (route is MinimizablePageRoute) {
      route.beginMinimize(tab, hasSnapshot: tab.preview != null);
    }
    widget.panelMotion?.minimize();
    tabs.minimize(tab);
    Navigator.of(context).pop();
  }

  void _resetMediaLifecycle() {
    _mediaBinding = null;
    _localMediaLifecycle.dispose();
    _localMediaLifecycle = MiniAppMediaLifecycle();
    // 账号失效/实例撤销时，旧会话不能再执行排队中的原生操作。
    _tab?.mediaLifecycle.dispose();
  }

  void _bindMediaLifecycle(InAppWebViewController controller) {
    final lifecycle = _tab?.mediaLifecycle ?? _localMediaLifecycle;
    final platform = defaultTargetPlatform;
    final generation = _generation;
    final entry = _entry!;
    // 回调只持有实例和身份，不持有旧页面；收起后的操作也能完成并有序恢复。
    _mediaBinding = lifecycle.bind(
      platform: (suspended, isCurrent) async {
        if (!isCurrent() || !AuthSession().isValid(generation)) return;
        switch (platform) {
          case TargetPlatform.android:
            if (suspended) {
              await controller.pause();
            } else {
              await controller.resume();
            }
          case TargetPlatform.iOS:
          case TargetPlatform.macOS:
            await controller.setAllMediaPlaybackSuspended(suspended: suspended);
          case TargetPlatform.windows:
          case TargetPlatform.linux:
            await controller.setMuted(muted: suspended);
          default:
            break;
        }
      },
      host: (suspended, isCurrent) async {
        final url = await controller.getUrl();
        if (!isCurrent() || !AuthSession().isValid(generation)) return;
        if (url?.origin != entry.origin || url?.path != entry.path) return;
        await controller.evaluateJavascript(
          source: 'window.fluxdoMiniAppHost?.setSuspended($suspended);',
        );
      },
    );
    _syncMediaState();
  }

  void _syncMediaState({bool refreshHost = false}) {
    _mediaBinding?.update(
      suspended:
          !widget.visible || _minimized || _backgrounded || _routeSuspended,
      refreshHost: refreshHost,
    );
  }

  Future<Object?> _evaluate(
    String source, {
    void Function(String operation)? onOperation,
  }) async {
    final controller = _controller;
    final epoch = _documentEpoch;
    if (controller == null || !AuthSession().isValid(_generation)) return null;
    onOperation?.call('get_url');
    final url = await controller.getUrl();
    final uri = url == null
        ? null
        : MiniAppUrl.parse(url.toString(), AppConstants.baseUrl);
    if (uri == null || MiniAppUrl.appId(uri) != _details.app.id) return null;
    if (!mounted ||
        epoch != _documentEpoch ||
        !AuthSession().isValid(_generation) ||
        _controller != controller) {
      return null;
    }
    onOperation?.call('evaluate_js');
    return controller.evaluateJavascript(source: source);
  }

  Future<void> _startPolling() {
    _stateTimer?.cancel();
    if (!mounted ||
        !widget.visible ||
        _covered ||
        _backgrounded ||
        widget.panelMotion?.moving.value == true) {
      return Future.value();
    }
    _stateTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _readState(),
    );
    return _readState();
  }

  Future<void> _readState() async {
    if (!mounted ||
        _permissionBusy ||
        _pollingEpoch == _documentEpoch ||
        _switchingEngine ||
        !_active ||
        _covered ||
        _backgrounded ||
        widget.panelMotion?.moving.value == true ||
        !widget.visible) {
      return;
    }
    final epoch = _documentEpoch;
    final permissionRevision = _permissionRevision;
    _pollingEpoch = epoch;
    var operation = 'get_url';
    void reportReadFailure(Object error) {
      if (mounted &&
          epoch == _documentEpoch &&
          permissionRevision == _permissionRevision &&
          _active &&
          widget.visible &&
          !_covered &&
          !_backgrounded &&
          AuthSession().isValid(_generation) &&
          _reportedStateReadEpoch != epoch) {
        _reportedStateReadEpoch = epoch;
        _reportNativeFailure('state_read', error, operation: operation);
      }
    }

    // A Future timeout does not cancel WebView IPC. Retain the in-flight guard
    // until it completes so a slow page cannot accumulate one call every 3s.
    // The separate boot deadline still reports an actual startup failure.
    final readDeadline = Timer(const Duration(seconds: 3), () {
      reportReadFailure(TimeoutException('Mini app state read delayed'));
    });
    try {
      final raw = await _evaluate(
        MiniAppHostAdapter.snapshot,
        onOperation: (value) => operation = value,
      );
      readDeadline.cancel();
      operation = 'state_apply';
      if (!mounted ||
          epoch != _documentEpoch ||
          permissionRevision != _permissionRevision ||
          !_active ||
          !widget.visible ||
          !AuthSession().isValid(_generation) ||
          raw is! Map) {
        return;
      }
      final compatible = raw['compatible'] == true;
      if (raw['engineMounted'] == true || raw['failed'] == true) {
        _bootTimer?.cancel();
      }
      if (_engine == MiniAppEngine.lightweight &&
          _reportedHostFailureEpoch != epoch) {
        final failure = MiniAppLaunchReport.hostFailure(
          raw['bootFailure'],
          _details.app.id,
        );
        if (failure != null) {
          _reportedHostFailureEpoch = epoch;
          debugPrint('[MiniApp] host-failed ${jsonEncode(failure)}');
          if (MiniAppWindowSession.current case final session?) {
            unawaited(
              session.request('launchReport', failure).catchError((_) => null),
            );
          } else {
            LogWriter.instance.write(failure);
          }
        }
      }
      final report = MiniAppLaunchReport.parse(
        raw['performance'],
        _details.app.id,
      );
      if (report != null && report['loaderStartMs'] != _reportedStart) {
        _reportedStart = report['loaderStartMs'] as num;
        final entry = {
          'type': 'mini_app',
          'event': 'mini_app_launch',
          'level': 'info',
          'engine': _engine.name,
          'independentWindow': widget.independentWindow,
          'observedElapsedMs': _launchClock.elapsedMilliseconds,
          'viewCreatedMs': _createdMs,
          'cookiesReadyMs': _cookiesReadyMs,
          ...report,
        };
        if (MiniAppWindowSession.current case final session?) {
          unawaited(
            session.request('launchReport', entry).catchError((_) => null),
          );
        } else {
          LogWriter.instance.write(entry);
        }
      }
      final release = raw['release'];
      if (_engine == MiniAppEngine.lightweight &&
          release is Map &&
          release['app_id'] == _details.app.id &&
          release['channel'] == 'production' &&
          release['id'] is int &&
          (release['id'] as int) > 0 &&
          release['version'] is String &&
          release['name'] is String &&
          _details.feedback['release_id'] != release['id']) {
        setState(
          () => _details = MiniAppDetails(
            MiniApp.fromJson({
              ..._details.app.toJson(),
              for (final key in [
                'version',
                'name',
                'description',
                'icon_url',
                'release_notes',
              ])
                if (release[key] is String) key: release[key],
            }),
            _details.embedUrl,
            configuration: {
              ..._details.configuration,
              'releaseId': release['id'],
            },
            feedback: {..._details.feedback, 'release_id': release['id']},
          ),
        );
      }
      final permission = MiniAppPermissionRequest.parse(raw['permission']);
      if (_permission != null &&
          _permission?.signature != permission?.signature) {
        await _evaluate(MiniAppHostAdapter.releasePermission);
      }
      var claimed = _permission?.signature == permission?.signature;
      if (permission != null &&
          !claimed &&
          permission.signature != _webOnlyPermission &&
          !_permissionBusy) {
        claimed =
            await _evaluate(
              MiniAppHostAdapter.permissionOperation(permission.signature),
            ) ==
            true;
      }
      if (!mounted ||
          epoch != _documentEpoch ||
          permissionRevision != _permissionRevision ||
          !_active ||
          !widget.visible ||
          !AuthSession().isValid(_generation)) {
        return;
      }
      final nativePermission =
          claimed && permission?.signature != _webOnlyPermission
          ? permission
          : null;
      final hostProgress = raw['progress'] is num
          ? (raw['progress'] as num).toDouble().clamp(0.0, 1.0)
          : null;
      final hostStage = raw['stage'] as String? ?? '';
      final hostDetail = raw['detail'] as String? ?? '';
      final hostReady = compatible && raw['ready'] == true;
      if (_hostLoading != (raw['loading'] == true) ||
          _hostReady != hostReady ||
          (_loading &&
              (hostReady ||
                  raw['loading'] == true ||
                  raw['webPermission'] == true)) ||
          _hostFailed != (raw['failed'] == true) ||
          _webPermission != (raw['webPermission'] == true) ||
          _hostStage != hostStage ||
          _hostDetail != hostDetail ||
          _hostProgress != hostProgress ||
          _permission?.signature != nativePermission?.signature) {
        setState(() {
          _hostReady = hostReady;
          // 宿主已开始加载或已就绪，就不再等待整个网页的 load 事件。
          if (hostReady ||
              raw['loading'] == true ||
              raw['webPermission'] == true) {
            _loading = false;
          }
          _hostLoading = raw['loading'] == true;
          _hostFailed = raw['failed'] == true;
          _webPermission = raw['webPermission'] == true;
          _hostStage = hostStage;
          _hostDetail = hostDetail;
          _hostProgress = hostProgress;
          _permission = nativePermission;
        });
      }
      final documentFullscreen = raw['fullscreen'] == true;
      if (documentFullscreen != _documentFullscreen) {
        _updateDisplay(() => _documentFullscreen = documentFullscreen);
      }
      final muted = raw['muted'] as bool?;
      if (compatible != _compatible || muted != _muted) {
        setState(() {
          _compatible = compatible;
          if (muted != null) _muted = muted;
        });
      }
      if (!_loading &&
          compatible &&
          raw['ready'] == true &&
          permission == null &&
          !_soundKnown &&
          !_soundBusy &&
          _soundProbes < 3) {
        _soundProbes++;
        unawaited(_soundOperation(toggle: false));
      }
      if (!_recorded &&
          compatible &&
          raw['ready'] == true &&
          !ref.read(currentUserProvider).isLoading) {
        _recorded = true;
        if (MiniAppWindowSession.current case final session?) {
          unawaited(session.record().catchError((_) {}));
        } else {
          ref.read(miniAppRecentsProvider).record(_details.app);
        }
      }
      final externalLink = raw['externalLink'];
      if (raw['webPermission'] != true &&
          _permission == null &&
          !_permissionBusy &&
          !_openingLink &&
          _nativeOverlays == 0 &&
          externalLink is Map) {
        final id = externalLink['id'];
        final url = externalLink['url'];
        if (id is String &&
            id.length < 256 &&
            url is String &&
            url.length <= 8192) {
          unawaited(_openHostLink(id, url, epoch, permissionRevision));
        }
      }
    } catch (error) {
      // 导航或销毁会使待处理的 DOM 读取失效。
      reportReadFailure(error);
    } finally {
      readDeadline.cancel();
      if (_pollingEpoch == epoch) _pollingEpoch = null;
    }
  }

  void _invalidatePermissionAnswer() {
    final answer = _permissionAnswer;
    _permissionAnswer = null;
    _permissionRevision++;
    _permissionBusy = false;
    if (answer != null && !answer.isCompleted) answer.complete(false);
  }

  Future<void> _answerPermission(bool allow) async {
    final request = _permission;
    if (request == null || _permissionBusy) return;
    final epoch = _documentEpoch;
    final answer = Completer<bool>();
    _permissionAnswer = answer;
    _permissionRevision++;
    var granted = false;
    setState(() => _permissionBusy = true);
    try {
      final accepted = await _evaluate(
        MiniAppHostAdapter.permissionOperation(request.signature, allow: allow),
      ).timeout(const Duration(seconds: 4));
      if (!mounted || epoch != _documentEpoch) return;
      granted = allow && accepted == true;
      _webOnlyPermission = request.signature;
      // DOM 已变或网页拒绝操作时交回官方界面，绝不推测授权成功。
      if (accepted != true) {
        await _evaluate(
          MiniAppHostAdapter.permissionOperation(
            request.signature,
            release: true,
          ),
        ).timeout(const Duration(seconds: 1));
      }
    } catch (_) {
      if (!mounted || epoch != _documentEpoch) return;
      _webOnlyPermission = request.signature;
      await _evaluate(
        MiniAppHostAdapter.permissionOperation(
          request.signature,
          release: true,
        ),
      ).timeout(const Duration(seconds: 1)).catchError((_) => null);
    } finally {
      if (mounted && epoch == _documentEpoch && !granted) {
        await _evaluate(MiniAppHostAdapter.clearExternalLinks)
            .timeout(const Duration(seconds: 1))
            .catchError((_) => null);
      }
      if (mounted && epoch == _documentEpoch) {
        _permissionRevision++;
        setState(() {
          _permission = null;
          _permissionBusy = false;
        });
      }
      if (identical(_permissionAnswer, answer)) _permissionAnswer = null;
      if (!answer.isCompleted) {
        answer.complete(granted && mounted && epoch == _documentEpoch);
      }
    }
    await _readState();
  }

  Future<void> _retryHost() async {
    if (_engine == MiniAppEngine.lightweight) {
      await _restartEngine(_engine);
      return;
    }
    final retried = await _evaluate(MiniAppHostAdapter.retry)
        .catchError((_) => null);
    if (retried != true) await _controller?.reload();
    await _readState();
  }

  /// 切换是显式的重新启动：先移除旧平台视图，再创建新引擎。
  Future<void> _restartEngine(MiniAppEngine engine) async {
    if (_switchingEngine || !mounted || !AuthSession().isValid(_generation)) {
      return;
    }
    _switchingEngine = true;
    _modalBlur.reset();
    _stateTimer?.cancel();
    _bootTimer?.cancel();
    _documentEpoch++;
    _invalidatePermissionAnswer();
    try {
      if (_engine == MiniAppEngine.lightweight) {
        await _evaluate('window.fluxdoMiniAppHost?.destroy();')
            .timeout(const Duration(milliseconds: 500))
            .catchError((_) => null);
      }
      if (!mounted || !AuthSession().isValid(_generation)) return;
      _viewEpoch++;
      _controller = null;
      _resetMediaLifecycle();
      _webView = null;
      _lightweightHtml = null;
      _lease?.release();
      _lease = null;
      _tab?.browserLease = null;
      setState(() {
        _engine = engine;
        _active = false;
        _error = null;
        _loading = true;
        _compatible = _hostReady = _hostFailed = _hostLoading = false;
        _permission = null;
        _permissionBusy = false;
        _webPermission = false;
        _webOnlyPermission = null;
        _hostStage = _hostDetail = '';
        _hostProgress = null;
        _soundKnown = _soundBusy = false;
        _soundProbes = 0;
        _muted = null;
      });
      await WidgetsBinding.instance.endOfFrame;
      await _tab?.discardWebView();
      if (mounted && AuthSession().isValid(_generation)) _activate();
    } finally {
      _switchingEngine = false;
    }
  }

  void _armBootTimeout(int viewEpoch) {
    _bootTimer?.cancel();
    _bootTimer = Timer(const Duration(seconds: 30), () {
      if (mounted &&
          viewEpoch == _viewEpoch &&
          AuthSession().isValid(_generation)) {
        final error = TimeoutException('Mini app host startup timed out');
        _reportNativeFailure('timeout', error);
        setState(() => _error = error);
      }
    });
  }

  void _reportNativeFailure(String phase, Object error, {String? operation}) {
    final report = MiniAppLaunchReport.nativeFailure({
      'appId': _details.app.id,
      'engine': _engine.name,
      'phase': phase,
      if (phase == 'state_read') ...{
        'operation': operation,
        'hostReady': _hostReady,
      },
      'errorName': switch (error) {
        PlatformException() => 'PlatformException',
        TimeoutException() => 'TimeoutException',
        FormatException() => 'FormatException',
        StateError() => 'StateError',
        _ => 'Error',
      },
      if (error is PlatformException) 'code': error.code,
      if (error is WebResourceError) 'code': error.type.toString(),
    }, _details.app.id);
    if (report == null) return;
    debugPrint('[MiniApp] ${report['event']} ${jsonEncode(report)}');
    if (MiniAppWindowSession.current case final session?) {
      unawaited(
        session.request('launchReport', report).catchError((_) => null),
      );
    } else {
      LogWriter.instance.write(report);
    }
  }

  String _bootErrorDetail() => switch (_error) {
    TimeoutException() => context.l10n.error_requestTimeoutRetry,
    StateError(:final message) => message.toString(),
    PlatformException(:final message, :final code) => message ?? code,
    FormatException() => context.l10n.error_unrecognizedDataFormat,
    _ => context.l10n.miniApp_engineBootFailed,
  };

  Future<void> _loadEntry(
    InAppWebViewController controller,
    int viewEpoch,
  ) async {
    _traceWindowsLaunch('load-entry');
    if (_engine == MiniAppEngine.web) {
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(_entry.toString())),
      );
      return;
    }
    final colors = Theme.of(context).colorScheme;
    String cssColor(Color color) =>
        '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    _lightweightHtml = MiniAppLightweightHost.build(
      details: _details,
      entry: _entry!,
      site: AppConstants.baseUrl,
      background: cssColor(colors.surface),
      foreground: cssColor(colors.onSurface),
      primary: cssColor(colors.primary),
      expectedUserId: ref.read(currentUserProvider).value?.id,
      failureMessage: context.l10n.miniApp_engineBootFailed,
      preparingMessage: context.l10n.miniApp_launchPreparing,
    );
    _armBootTimeout(viewEpoch);
    if (Platform.isAndroid || Platform.isWindows) {
      // 替换当前精确入口文档，保留真实源、路径与 HTTP 缓存分区。
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(_entry.toString())),
      );
    } else {
      // WKWebView/WPE 使用 HTTPS baseUrl，宿主启动时还会验证真实源。
      await controller.loadData(
        data: _lightweightHtml!,
        baseUrl: WebUri(_entry.toString()),
        historyUrl: WebUri(_entry.toString()),
      );
    }
  }

  // 原生崩溃不会进入 Dart catch；保留启动边界，且不输出 Cookie 或启动参数。
  void _traceWindowsLaunch(String stage) {
    if (!Platform.isWindows) return;
    debugPrint(
      '[MiniApp] $stage engine=${_engine.name} '
      'app=${_details.app.id} view=$_viewEpoch '
      'elapsed=${_launchClock.elapsedMilliseconds}ms',
    );
  }

  Future<void> _sound() async {
    await _soundOperation(toggle: true);
  }

  Future<void> _soundOperation({required bool toggle}) async {
    if (_soundBusy || !_compatible) return;
    final epoch = _documentEpoch;
    setState(() => _soundBusy = true);
    try {
      final controller = _controller;
      if (controller == null || !AuthSession().isValid(_generation)) return;
      final url = await controller.getUrl();
      final uri = url == null
          ? null
          : MiniAppUrl.parse(url.toString(), AppConstants.baseUrl);
      if (uri == null ||
          MiniAppUrl.appId(uri) != _details.app.id ||
          !mounted ||
          epoch != _documentEpoch ||
          !AuthSession().isValid(_generation)) {
        return;
      }
      final result = await controller.callAsyncJavaScript(
        functionBody: MiniAppHostAdapter.soundOperation,
        arguments: {'toggle': toggle},
      );
      if (!mounted ||
          epoch != _documentEpoch ||
          controller != _controller ||
          !AuthSession().isValid(_generation)) {
        return;
      }
      final state = result?.value;
      if (state is Map &&
          state['available'] == true &&
          state['muted'] is bool) {
        setState(() {
          _muted = state['muted'] as bool;
          _soundKnown = true;
        });
      } else if (toggle) {
        _notice(context.l10n.miniApp_actionUnavailable);
      }
    } catch (_) {
      if (mounted && epoch == _documentEpoch && toggle) {
        _notice(context.l10n.miniApp_actionUnavailable);
      }
    } finally {
      if (mounted && epoch == _documentEpoch) {
        setState(() => _soundBusy = false);
      }
    }
  }

  void _notice(String message, {ToastType type = ToastType.info}) =>
      ToastService.show(message, type: type);

  bool get _nativeSurfaceCoversView =>
      _error != null ||
      ((_loading || _hostLoading) && (!_webPermission || _permission != null));

  bool _visualCapturePending = false;
  bool _openingLink = false;
  bool _takingHostLink = false;

  Future<void> _openHostLink(
    String id,
    String url,
    int epoch,
    int permissionRevision,
  ) async {
    if (_takingHostLink) return;
    _takingHostLink = true;
    try {
      final taken = await _evaluate(MiniAppHostAdapter.takeExternalLink(id))
          .timeout(const Duration(seconds: 2));
      if (taken != true ||
          !mounted ||
          epoch != _documentEpoch ||
          permissionRevision != _permissionRevision) {
        return;
      }
      await _openLink(url);
    } catch (_) {
      if (mounted && epoch == _documentEpoch) {
        _notice(context.l10n.common_cannotOpenBrowser, type: ToastType.error);
      }
    } finally {
      if (mounted && epoch == _documentEpoch) {
        await _evaluate(MiniAppHostAdapter.finishExternalLink(id))
            .timeout(const Duration(seconds: 1))
            .catchError((_) => null);
      }
      _takingHostLink = false;
    }
  }

  Future<void> _openLink(String url) async {
    final epoch = _documentEpoch;
    final answer = _permissionAnswer;
    // 官方按钮可在 evaluateJavascript 返回之前同步导航。
    // 等本次回答结束再交给离站确认；拒绝/失败/旧文档的跳转直接作废。
    if (answer != null && !await answer.future) return;
    if (_openingLink ||
        !mounted ||
        epoch != _documentEpoch ||
        !_active ||
        _covered ||
        !widget.visible ||
        _permissionBusy ||
        _permission != null ||
        !AuthSession().isValid(_generation)) {
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'https', 'http', 'mailto', 'tel'}.contains(uri.scheme)) {
      return;
    }
    _openingLink = true;
    try {
      if (isInternalUrl(uri)) {
        await launchContentLink(context, url);
      } else {
        await launchExternalLink(
          context,
          url,
          confirm: (target, risk) => _withNativeOverlay<ExternalLinkOpenChoice>(
            (ready, onBlur, filterBackdrop) => showExternalLinkConfirmDialog(
              context,
              target,
              risk,
              blurReady: ready,
              onBlurSigmaChanged: onBlur,
              filterBackdrop: filterBackdrop,
            ),
          ),
          showBlocked: (target) async {
            await _withNativeOverlay(
              (ready, onBlur, filterBackdrop) => showLinkBlockedDialog(
                context,
                target,
                blurReady: ready,
                onBlurSigmaChanged: onBlur,
                filterBackdrop: filterBackdrop,
              ),
            );
          },
        );
      }
    } catch (_) {
      if (mounted) {
        _notice(context.l10n.common_cannotOpenBrowser, type: ToastType.error);
      }
    } finally {
      _openingLink = false;
    }
  }

  Future<MiniAppGlassFrame?> _captureDockBackdrop(
    Rect globalBounds, {
    int? maxWidth,
  }) async {
    if (_visualCapturePending || _pointerActive) return null;
    _visualCapturePending = true;
    try {
      return await _captureSurface(globalBounds, maxWidth: maxWidth ?? 220);
    } finally {
      _visualCapturePending = false;
    }
  }

  Future<MiniAppGlassFrame?> _captureSurface(
    Rect globalBounds, {
    required int maxWidth,
  }) async {
    final controller = _controller;
    final render = _viewportKey.currentContext?.findRenderObject();
    if (!_active ||
        widget.panelMotion?.moving.value == true ||
        !widget.visible ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) ||
        _covered ||
        _nativeOverlays > 0 ||
        controller == null ||
        _nativeSurfaceCoversView ||
        render is! RenderBox ||
        !render.hasSize) {
      return null;
    }
    final epoch = _documentEpoch;
    final size = render.size;
    final local =
        (render.globalToLocal(globalBounds.topLeft) & globalBounds.size)
            .intersect(Offset.zero & size);
    if (local.isEmpty) return null;
    final actualGlobal = render.localToGlobal(local.topLeft) & local.size;
    final density = MediaQuery.devicePixelRatioOf(context);
    final SurfaceFrame? frame;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      // WebView2 的 CDP 局部截图会临时重设 Chromium 视口，导致正文白闪。
      // Windows 内容本来就是 Flutter Texture，直接读取已显示的纹理；
      // 独立边界只包含网页，不包含加载遮罩、圆弧或原生菜单。
      final boundary = _textureCaptureKey.currentContext?.findRenderObject();
      if (boundary is! RenderTextureCaptureBoundary) return null;
      frame = await boundary.capture(
        actualGlobal,
        maxWidth: maxWidth,
        devicePixelRatio: density,
      );
    } else {
      frame = await WebViewSurfaceCapture.capture(
        takeScreenshot: (configuration) =>
            controller.takeScreenshot(screenshotConfiguration: configuration),
        platform: defaultTargetPlatform,
        viewport: render.localToGlobal(Offset.zero) & size,
        region: actualGlobal,
        devicePixelRatio: density,
        maxWidth: maxWidth,
      );
    }
    if (frame == null) return null;
    if (!mounted ||
        widget.panelMotion?.moving.value == true ||
        epoch != _documentEpoch ||
        controller != _controller ||
        size != _viewportKey.currentContext?.size ||
        !AuthSession().isValid(_generation)) {
      frame.image.dispose();
      return null;
    }
    return frame;
  }

  Future<T?> _withNativeOverlay<T>(
    Future<T?> Function(
      ValueListenable<bool>? blurReady,
      ValueChanged<double>? onBlurSigmaChanged,
      bool filterBackdrop,
    )
    show,
  ) async {
    if (_nativeOverlays > 0) return null;
    setState(() => _nativeOverlays++);
    MiniAppModalFrameLease? frame;
    final epoch = _documentEpoch;
    try {
      final controller = _controller;
      final needsFrame =
          !PlatformUtils.isDesktop &&
          defaultTargetPlatform == TargetPlatform.android &&
          _active &&
          controller != null &&
          !_nativeSurfaceCoversView;
      final enabled = ref.read(preferencesProvider).dialogBlur;
      if (needsFrame && enabled) {
        frame = _modalBlur.acquire(() async {
          if (_visualCapturePending) return null;
          _visualCapturePending = true;
          try {
            if (!mounted || controller != _controller) {
              return null;
            }
            final captureEpoch = _documentEpoch;
            // 每次尝试读取当前尺寸，不能一直拿打开菜单前的旧键盘/旋转尺寸校验。
            final size = _viewportKey.currentContext?.size;
            if (size == null || size.isEmpty) return null;
            final density = MediaQuery.devicePixelRatioOf(context);
            final bytes = await controller.takeScreenshot(
              screenshotConfiguration: ScreenshotConfiguration(
                // Android 的 snapshotWidth 是逻辑尺寸，会再次乘 DPR。
                // 模糊底图只需约 360 个物理像素，避免高分屏的大图 PNG 编解码。
                snapshotWidth:
                    (size.width * density).clamp(1.0, 360.0) / density,
                compressFormat: CompressFormat.JPEG,
                quality: 70,
              ),
            );
            if (bytes == null ||
                !mounted ||
                captureEpoch != _documentEpoch ||
                controller != _controller) {
              return null;
            }
            final codec = await ui.instantiateImageCodec(bytes);
            try {
              final image = (await codec.getNextFrame()).image;
              if (!mounted ||
                  captureEpoch != _documentEpoch ||
                  controller != _controller ||
                  size != _viewportKey.currentContext?.size) {
                image.dispose();
                return null;
              }
              try {
                final composed = await _composeModalFrame(image);
                if (!mounted ||
                    captureEpoch != _documentEpoch ||
                    controller != _controller ||
                    size != _viewportKey.currentContext?.size ||
                    !AuthSession().isValid(_generation)) {
                  composed?.dispose();
                  return null;
                }
                return composed;
              } finally {
                image.dispose();
              }
            } finally {
              codec.dispose();
            }
          } finally {
            _visualCapturePending = false;
          }
        });
      }
      if (!mounted ||
          epoch != _documentEpoch ||
          !AuthSession().isValid(_generation) ||
          _permission != null) {
        return null;
      }
      return await show(
        frame == null ? null : _modalBlur,
        frame?.onBlurSigmaChanged,
        frame == null,
      );
    } finally {
      frame?.finish();
      if (mounted) setState(() => _nativeOverlays--);
    }
  }

  Future<void> _info() async {
    if (_permission != null) return;
    await _withNativeOverlay(
      (blurReady, onBlur, filterBackdrop) => MiniAppDetailPage.showSummary(
        context,
        _details,
        blurReady: blurReady,
        onBlurSigmaChanged: onBlur,
        filterBackdrop: filterBackdrop,
      ),
    );
  }

  bool _menuOpen = false;
  Future<void> _menu(bool loggedIn, BuildContext anchorContext) async {
    if (_menuOpen || _permission != null) return;
    _menuOpen = true;
    try {
      final selected = await _withNativeOverlay(
        (blurReady, onBlur, filterBackdrop) => showMiniAppMenu(
          context,
          _details,
          loggedIn: loggedIn,
          anchorContext: anchorContext,
          fullscreen: _fullscreen,
          soundAvailable: _active && _compatible && !_soundBusy,
          muted: _muted != false,
          canRotate: PlatformUtils.isMobile,
          canDetach: !widget.independentWindow,
          canMinimize: !widget.asPanel && _tab != null,
          blurReady: blurReady,
          onBlurSigmaChanged: onBlur,
          filterBackdrop: filterBackdrop,
        ),
      );
      if (!mounted || selected == null) return;
      if (selected == MiniAppMenuAction.info) {
        await _info();
      } else {
        await _action(selected.name);
      }
    } finally {
      _menuOpen = false;
    }
  }

  Future<void> _action(String action) async {
    if (_actionBusy || _entry == null || !AuthSession().isValid(_generation)) {
      return;
    }
    final generation = _generation;
    _actionBusy = true;
    try {
      if (action == 'share') {
        await _share();
        return;
      }
      if (action == 'minimize') {
        await _minimize();
        return;
      }
      if (action == 'separateWindow') {
        if (!mounted || !AuthSession().isValid(generation)) return;
        final opened = await MiniAppWindowBridge.open(
          _details,
          _entry!,
          engine: _engine,
          iconBrightness: Theme.of(context).brightness,
          container: ProviderScope.containerOf(context, listen: false),
          community: (path) async {
            final hostContext = navigatorKey.currentContext;
            if (hostContext != null) {
              await launchContentLink(
                hostContext,
                '${AppConstants.baseUrl}$path',
              );
            }
          },
        );
        if (mounted && opened) {
          if (_fullscreen) _leaveFullscreen();
          // 独立窗口已接管，主窗口中的原实例必须关闭，不能变成收起会话。
          Navigator.of(context).pop();
        }
        return;
      }
      if (action == 'fullscreen') {
        _fullscreen ? _leaveFullscreen() : _setFullscreen(true);
        return;
      }
      if (action == 'systemOrientation') {
        await _orientation(MiniAppOrientation.system);
        return;
      }
      if (action == 'sound') {
        await _sound();
        return;
      }
      if (action == 'embed') {
        final code =
            '<iframe src="${const HtmlEscape(HtmlEscapeMode.attribute).convert(_entry.toString())}" title="${const HtmlEscape(HtmlEscapeMode.attribute).convert(_details.app.name)}" loading="lazy"></iframe>';
        await Clipboard.setData(ClipboardData(text: code));
        if (mounted) _notice(context.l10n.miniApp_copied);
        return;
      }
      if (action == 'favorite') {
        await ref
            .read(miniAppServiceProvider)
            .favorite(_details, !_details.app.favorited);
      } else {
        final feedback = switch (action) {
          'rating' => MiniAppFeedback.rating,
          'tip' => MiniAppFeedback.tip,
          _ => MiniAppFeedback.report,
        };
        final saved = await _withNativeOverlay(
          (blurReady, onBlur, filterBackdrop) => MiniAppFeedbackDialog.show(
            context,
            details: _details,
            action: feedback,
            blurReady: blurReady,
            onBlurSigmaChanged: onBlur,
            filterBackdrop: filterBackdrop,
          ),
        );
        if (saved == true && mounted && AuthSession().isValid(generation)) {
          _notice(
            feedback == MiniAppFeedback.report
                ? context.l10n.miniApp_reportSent
                : feedback == MiniAppFeedback.tip
                ? context.l10n.miniApp_tipSent
                : context.l10n.miniApp_saved,
          );
        }
      }
      if (!mounted || !AuthSession().isValid(generation)) return;
      final fresh = await ref
          .read(miniAppServiceProvider)
          .details(_details.app.id);
      if (mounted && AuthSession().isValid(generation)) {
        setState(
          () => _details = MiniAppDetails(
            MiniApp.fromJson({
              ..._details.app.toJson(),
              'is_favorited': fresh.app.favorited,
              'rating_average': fresh.app.rating,
              'rating_count': fresh.app.ratingCount,
            }),
            _details.embedUrl,
            configuration: _details.configuration,
            feedback: {
              ...fresh.feedback,
              'release_id': _details.feedback['release_id'],
            },
          ),
        );
      }
    } catch (e) {
      if (mounted) _notice(ErrorUtils.getErrorInfo(e).message);
    } finally {
      _actionBusy = false;
    }
  }

  Future<void> _share() async {
    final entry = _entry;
    if (entry == null) return;
    final parameters = {...entry.queryParametersAll}..remove('embed_mode');
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: entry.replace(queryParameters: parameters).toString(),
        title: _details.app.name,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _surfaceTheme,
      builder: (context, _) {
        final fallback = Theme.of(context).colorScheme.surface;
        final top = AdaptiveSurfaceColors.resolve(
          sampled: _surfaceTheme.top,
          fallback: fallback,
        );
        final bottom = AdaptiveSurfaceColors.resolve(
          sampled: _surfaceTheme.bottom,
          fallback: fallback,
        );
        return TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: top),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 260),
          builder: (context, top, _) => TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: bottom),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 260),
            builder: (context, bottom, _) => _buildPage(context, top!, bottom!),
          ),
        );
      },
    );
  }

  bool get _canSampleSurface => const {
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  }.contains(defaultTargetPlatform);

  void _syncSurfaceSampling() {
    if (!mounted) return;
    final render = _viewportKey.currentContext?.findRenderObject();
    _surfaceTheme.configure(
      enabled:
          _canSampleSurface &&
          _active &&
          widget.visible &&
          !_covered &&
          _nativeOverlays == 0 &&
          !_pointerActive &&
          widget.panelMotion?.moving.value != true &&
          !_nativeSurfaceCoversView &&
          _permission == null &&
          _hostReady,
      document: (_generation, _documentEpoch),
      bounds: render is RenderBox && render.hasSize
          ? render.localToGlobal(Offset.zero) & render.size
          : null,
      capture: _captureDockBackdrop,
    );
  }

  Widget _buildPage(BuildContext context, Color topColor, Color bottomColor) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncSurfaceSampling());
    final viewEpoch = _viewEpoch;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final loggedIn =
        ref.watch(currentUserProvider).value != null &&
        _details.configuration['channel'] == 'production' &&
        _details.configuration['anonymous'] != true &&
        AuthSession().isValid(_generation);
    return PopScope(
      canPop:
          !widget.visible ||
          (!widget.independentWindow && !_fullscreen && _permission == null),
      onPopInvokedWithResult: (didPop, _) {
        if (!widget.visible) return;
        if (!didPop) {
          if (_permission != null) {
            unawaited(_answerPermission(false));
          } else if (_fullscreen) {
            _leaveFullscreen();
          } else if (widget.independentWindow) {
            widget.onCloseWindow?.call();
          }
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AdaptiveSurfaceColors.overlay(topColor, bottomColor),
        child: Stack(
          key: _pageKey,
          fit: StackFit.expand,
          children: [
            Scaffold(
              backgroundColor: bottomColor,
              appBar: _fullscreen
                  ? null
                  : PreferredSize(
                      preferredSize: Size.fromHeight(landscape ? 48 : 56),
                      child: RepaintBoundary(
                        key: _toolbarKey,
                        child: MiniAppRunnerToolbar(
                          backgroundColor: topColor,
                          independentWindow: widget.independentWindow,
                          app: _details.app,
                          onBack:
                              widget.onCloseWindow ??
                              () => Navigator.maybePop(context),
                          onMinimize: widget.asPanel ? _minimize : null,
                          onOpenPage: widget.asPanel ? _openAsPage : null,
                          primary: !widget.asPanel,
                          minimizeBusy: _minimizing || _permission != null,
                          onInfo: _info,
                          onMenu: (anchor) => _menu(loggedIn, anchor),
                          onFullscreen: () => _setFullscreen(true),
                          onRotate: PlatformUtils.isMobile ? _rotate : null,
                          landscape: landscape,
                          compact: landscape,
                        ),
                      ),
                    ),
              body: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [topColor, bottomColor],
                  ),
                ),
                child: SafeArea(
                  // 全屏仍避让刘海/挖孔；系统栏隐藏后这些 inset 只保留物理遮挡。
                  top: _fullscreen,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _trackSurfacePointers(
                          Stack(
                            key: _viewportKey,
                            fit: StackFit.expand,
                            children: [
                              if (_active)
                                TextureCaptureBoundary(
                                  key: _textureCaptureKey,
                                  child: IgnorePointer(
                                    ignoring: _covered || _permission != null,
                                    child: _webView ??= InAppWebView(
                                      key: ValueKey((_generation, viewEpoch)),
                                      // 内容区从按下开始直接接收触摸，不让外层返回/弹层手势
                                      // 将原生事件拖到抬手才派发；覆盖在上方的按钮仍独立命中。
                                      gestureRecognizers: {
                                        Factory<OneSequenceGestureRecognizer>(
                                          EagerGestureRecognizer.new,
                                        ),
                                      },
                                      keepAlive: _tab?.keepAlive,
                                      webViewEnvironment: Platform.isWindows
                                          ? WindowsWebViewEnvironmentService
                                                .instance
                                                .environment
                                          : null,
                                      initialSettings: WebViewSettings.visible
                                        ..userAgent =
                                            MiniAppWindowSession
                                                .current
                                                ?.userAgent ??
                                            WebViewSettings.visible.userAgent
                                        ..useShouldOverrideUrlLoading = true
                                        ..useShouldInterceptRequest =
                                            _engine ==
                                                MiniAppEngine.lightweight &&
                                            (Platform.isAndroid ||
                                                Platform.isWindows)
                                        ..javaScriptBridgeForMainFrameOnly =
                                            true
                                        ..javaScriptHandlersForMainFrameOnly =
                                            true
                                        ..contentInsetAdjustmentBehavior =
                                            ScrollViewContentInsetAdjustmentBehavior
                                                .NEVER
                                        ..overScrollMode = OverScrollMode.NEVER
                                        ..disallowOverScroll = true
                                        ..iframeAllowFullscreen = true,
                                      initialUserScripts: _userScripts,
                                      shouldInterceptRequest: (_, request) async {
                                        if (!mounted ||
                                            viewEpoch != _viewEpoch ||
                                            !AuthSession().isValid(
                                              _generation,
                                            ) ||
                                            _engine !=
                                                MiniAppEngine.lightweight ||
                                            _lightweightHtml == null ||
                                            !MiniAppLightweightHost.intercepts(
                                              entry: _entry!,
                                              request: Uri.parse(
                                                request.url.toString(),
                                              ),
                                              method: request.method,
                                              mainFrame: request.isForMainFrame,
                                              headers: request.headers,
                                            )) {
                                          return null;
                                        }
                                        return WebResourceResponse(
                                          data: Uint8List.fromList(
                                            utf8.encode(_lightweightHtml!),
                                          ),
                                          contentType: 'text/html',
                                          contentEncoding: 'utf-8',
                                          statusCode: 200,
                                          reasonPhrase: 'OK',
                                          headers: {
                                            'Cache-Control': 'no-store',
                                            'X-Content-Type-Options': 'nosniff',
                                          },
                                        );
                                      },
                                      onWebViewCreated: (controller) async {
                                        if (!mounted ||
                                            viewEpoch != _viewEpoch) {
                                          return;
                                        }
                                        _controller = controller;
                                        _bindMediaLifecycle(controller);
                                        _traceWindowsLaunch('webview-created');
                                        if (_tab case final tab?) {
                                          tab.hasWebView = true;
                                          if (tab.initialLoadRequested) {
                                            if (_engine ==
                                                MiniAppEngine.lightweight) {
                                              _armBootTimeout(viewEpoch);
                                            }
                                            _syncVisibility();
                                            await _startPolling();
                                            return;
                                          }
                                        }
                                        _createdMs =
                                            _launchClock.elapsedMilliseconds;
                                        try {
                                          if (!mounted ||
                                              viewEpoch != _viewEpoch ||
                                              !AuthSession().isValid(
                                                _generation,
                                              )) {
                                            return;
                                          }
                                          if (MiniAppWindowSession.current
                                              case final session?) {
                                            await session.prime();
                                          } else {
                                            await WebViewCookiePriming.instance
                                                .prime(_entry.toString());
                                          }
                                          if (!mounted ||
                                              viewEpoch != _viewEpoch ||
                                              !AuthSession().isValid(
                                                _generation,
                                              )) {
                                            return;
                                          }
                                          _cookiesReadyMs =
                                              _launchClock.elapsedMilliseconds;
                                          await _loadEntry(
                                            controller,
                                            viewEpoch,
                                          );
                                          if (_tab != null) {
                                            _tab!.initialLoadRequested = true;
                                          }
                                          if (!widget.visible) {
                                            _syncVisibility();
                                          }
                                        } catch (e) {
                                          if (mounted &&
                                              viewEpoch == _viewEpoch) {
                                            _bootTimer?.cancel();
                                            _reportNativeFailure(
                                              'document_load',
                                              e,
                                            );
                                            setState(() => _error = e);
                                          }
                                        }
                                      },
                                      onReceivedServerTrustAuthRequest: (_, challenge) async {
                                        final session =
                                            MiniAppWindowSession.current;
                                        if (session == null) {
                                          return WebViewSettings.handleServerTrustAuthRequest(
                                            challenge,
                                          );
                                        }
                                        final der = challenge
                                            .protectionSpace
                                            .sslCertificate
                                            ?.x509Certificate
                                            ?.encoded;
                                        if (der == null) return null;
                                        final valid = await session.request(
                                          'verifyCertificate',
                                          {
                                            'der': der,
                                            'host':
                                                challenge.protectionSpace.host,
                                          },
                                        );
                                        return valid == true
                                            ? ServerTrustAuthResponse(
                                                action:
                                                    ServerTrustAuthResponseAction
                                                        .PROCEED,
                                              )
                                            : null;
                                      },
                                      onScrollChanged: (_, x, y) {
                                        _pointerActive = true;
                                        _syncSurfaceSampling();
                                        _resumeSurfaceSampling();
                                      },
                                      onLoadStart: (_, _) {
                                        if (mounted &&
                                            viewEpoch == _viewEpoch) {
                                          _traceWindowsLaunch('document-start');
                                          _documentEpoch++;
                                          _invalidatePermissionAnswer();
                                          _modalBlur.refresh();
                                          _reportedStart = null;
                                          setState(() {
                                            _loading = true;
                                            _compatible = false;
                                            _soundKnown = false;
                                            _soundBusy = false;
                                            _soundProbes = 0;
                                            _hostLoading = false;
                                            _hostReady = false;
                                            _hostFailed = false;
                                            _hostStage = '';
                                            _hostDetail = '';
                                            _hostProgress = null;
                                            _permission = null;
                                            _permissionBusy = false;
                                            _webPermission = false;
                                            _webOnlyPermission = null;
                                          });
                                          unawaited(_startPolling());
                                        }
                                      },
                                      onLoadStop: (controller, url) async {
                                        if (!mounted ||
                                            viewEpoch != _viewEpoch) {
                                          return;
                                        }
                                        _traceWindowsLaunch('document-stop');
                                        final epoch = _documentEpoch;
                                        final uri = url == null
                                            ? null
                                            : MiniAppUrl.parse(
                                                url.toString(),
                                                AppConstants.baseUrl,
                                              );
                                        if (uri == null ||
                                            MiniAppUrl.appId(uri) !=
                                                _details.app.id) {
                                          return;
                                        }
                                        await controller.injectCSSCode(
                                          source: MiniAppHostAdapter.css,
                                        );
                                        if (!mounted ||
                                            epoch != _documentEpoch) {
                                          return;
                                        }
                                        _syncMediaState(refreshHost: true);
                                        await _startPolling();
                                        if (mounted &&
                                            epoch == _documentEpoch) {
                                          setState(() => _loading = false);
                                        }
                                      },
                                      onReceivedError: (_, request, error) {
                                        if (mounted &&
                                            viewEpoch == _viewEpoch &&
                                            request.isForMainFrame == true) {
                                          _bootTimer?.cancel();
                                          _reportNativeFailure(
                                            'document_load',
                                            error,
                                          );
                                          setState(
                                            () => _error = StateError(
                                              error.description,
                                            ),
                                          );
                                        }
                                      },
                                      onRenderProcessGone: (_, _) {
                                        _traceWindowsLaunch('renderer-gone');
                                        if (viewEpoch == _viewEpoch) _revoked();
                                      },
                                      onWebContentProcessDidTerminate: (_) {
                                        if (viewEpoch == _viewEpoch) _revoked();
                                      },
                                      onEnterFullscreen: (_) {
                                        if (!mounted ||
                                            viewEpoch != _viewEpoch ||
                                            !widget.visible) {
                                          return;
                                        }
                                        _updateDisplay(
                                          () => _platformFullscreen = true,
                                        );
                                      },
                                      onExitFullscreen: (_) {
                                        if (!mounted ||
                                            viewEpoch != _viewEpoch) {
                                          return;
                                        }
                                        _updateDisplay(() {
                                          _platformFullscreen = false;
                                          _documentFullscreen = false;
                                        });
                                        // 平台退出网页全屏会还原原生系统栏和方向。
                                        // 用户仍处于客户端全屏时，重新应用当前选择。
                                        if (_fullscreen) _applySystemUi(true);
                                        if (_orientationMode
                                            case final orientation?) {
                                          unawaited(_orientation(orientation));
                                        }
                                      },
                                      // 保留平台提供有效 URL 的用户点击回调。
                                      // 官方异步 window.open 由主宿主适配接管，
                                      // 不依赖 Android 弹窗回调的 URL/手势信息。
                                      onCreateWindow: (_, request) async {
                                        if (mounted &&
                                            viewEpoch == _viewEpoch &&
                                            request.hasGesture != false &&
                                            request.request.url != null) {
                                          unawaited(
                                            _openLink(
                                              request.request.url.toString(),
                                            ),
                                          );
                                        }
                                        return false;
                                      },
                                      shouldOverrideUrlLoading:
                                          (_, action) async {
                                            if (!mounted ||
                                                viewEpoch != _viewEpoch) {
                                              return NavigationActionPolicy
                                                  .CANCEL;
                                            }
                                            final uri = action.request.url;
                                            if (uri == null) {
                                              return NavigationActionPolicy
                                                  .ALLOW;
                                            }
                                            if (!{
                                              'https',
                                              'http',
                                              'about',
                                              'blob',
                                              'data',
                                            }.contains(uri.scheme)) {
                                              return NavigationActionPolicy
                                                  .CANCEL;
                                            }
                                            if (action.isForMainFrame != true) {
                                              return NavigationActionPolicy
                                                  .ALLOW;
                                            }
                                            final appUri = MiniAppUrl.parse(
                                              uri.toString(),
                                              AppConstants.baseUrl,
                                            );
                                            if (appUri != null &&
                                                MiniAppUrl.appId(appUri) ==
                                                    _details.app.id) {
                                              return NavigationActionPolicy
                                                  .ALLOW;
                                            }
                                            if (uri.toString() ==
                                                'about:blank') {
                                              return NavigationActionPolicy
                                                  .ALLOW;
                                            }
                                            if (mounted &&
                                                {
                                                  'https',
                                                  'http',
                                                }.contains(uri.scheme)) {
                                              unawaited(
                                                _openLink(uri.toString()),
                                              );
                                            }
                                            return NavigationActionPolicy
                                                .CANCEL;
                                          },
                                    ),
                                  ),
                                ),
                              if (_minimizePreview != null)
                                Positioned.fill(
                                  child: Image.memory(
                                    _minimizePreview!,
                                    fit: BoxFit.fill,
                                    gaplessPlayback: true,
                                    excludeFromSemantics: true,
                                  ),
                                ),
                              if (_error != null)
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surface,
                                    child:
                                        _engine == MiniAppEngine.lightweight &&
                                            AuthSession().isValid(_generation)
                                        ? MiniAppLaunchSurface(
                                            app: _details.app,
                                            failed: true,
                                            detail: _bootErrorDetail(),
                                            onRetry: () =>
                                                _restartEngine(_engine),
                                            onUseWebEngine: () =>
                                                _restartEngine(
                                                  MiniAppEngine.web,
                                                ),
                                          )
                                        : ErrorView(
                                            error: _error!,
                                            onRetry: () {
                                              if (!AuthSession().isValid(
                                                _generation,
                                              )) {
                                                if (widget.onMinimize != null) {
                                                  widget.onMinimize!();
                                                } else {
                                                  Navigator.pop(context);
                                                }
                                              } else if (!_active) {
                                                _activate();
                                              } else {
                                                setState(() => _error = null);
                                                _controller?.reload();
                                              }
                                            },
                                          ),
                                  ),
                                ),
                              if (_active &&
                                  _error == null &&
                                  (_loading || _hostLoading) &&
                                  (!_webPermission || _permission != null))
                                MiniAppLaunchSurface(
                                  app: _details.app,
                                  stage: _hostStage,
                                  detail: _hostDetail,
                                  progress: _hostProgress,
                                  failed: _hostFailed,
                                  onRetry: _retryHost,
                                  onUseWebEngine:
                                      _engine == MiniAppEngine.lightweight
                                      ? () => _restartEngine(MiniAppEngine.web)
                                      : null,
                                ),
                              if (_active && _permission != null)
                                MiniAppPermissionSurface(
                                  app: _details.app,
                                  request: _permission!,
                                  busy: _permissionBusy,
                                  onAnswer: _answerPermission,
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (_fullscreen)
                        Positioned.fill(
                          child: MiniAppFullscreenDock(
                            samplingEnabled:
                                !_covered &&
                                _nativeOverlays == 0 &&
                                !_pointerActive &&
                                widget.visible,
                            captureBackdrop: _canSampleSurface
                                ? _captureDockBackdrop
                                : null,
                            onExit: _leaveFullscreen,
                            onMenu: (anchor) => _menu(loggedIn, anchor),
                            onRotate: PlatformUtils.isMobile ? _rotate : null,
                            landscape: landscape,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(child: MiniAppModalFrame(blur: _modalBlur)),
          ],
        ),
      ),
    );
  }

  /// 只有网页交互需要等待滚动空闲；原生圆弧自己管理按住/吸附期间停采，
  /// 点击展开不能再被页面级的 500ms 等待挡住第一张玻璃背景。
  Widget _trackSurfacePointers(Widget child) => Listener(
    onPointerDown: (event) {
      _surfacePointers.add(event.pointer);
      _pointerIdle?.cancel();
      if (!_pointerActive) setState(() => _pointerActive = true);
      _syncSurfaceSampling();
    },
    onPointerUp: (event) {
      _surfacePointers.remove(event.pointer);
      _resumeSurfaceSampling();
    },
    onPointerCancel: (event) {
      _surfacePointers.remove(event.pointer);
      _resumeSurfaceSampling();
    },
    child: child,
  );

  void _resumeSurfaceSampling() {
    _pointerIdle?.cancel();
    if (_surfacePointers.isNotEmpty) return;
    _pointerIdle = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() => _pointerActive = false);
      _syncSurfaceSampling();
    });
  }

  Future<ui.Image?> _composeModalFrame(ui.Image webImage) async {
    // 只在弹层期间合成一张完整底图。平台视图与顶栏不再跨两个合成层取模糊。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return null;
    final page = _pageKey.currentContext?.findRenderObject();
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (page is! RenderBox ||
        viewport is! RenderBox ||
        !page.hasSize ||
        !viewport.hasSize) {
      return null;
    }
    final pageSize = page.size;
    final origin = page.localToGlobal(Offset.zero);
    final content =
        (viewport.localToGlobal(Offset.zero) - origin) & viewport.size;
    final scale = 360 / pageSize.width;
    ui.Image? toolbar;
    final bar = _toolbarKey.currentContext?.findRenderObject();
    if (!_fullscreen) {
      if (bar is! RenderRepaintBoundary || bar.debugNeedsPaint) return null;
      toolbar = await bar.toImage(pixelRatio: scale);
    }
    if (!mounted || page.size != pageSize) {
      toolbar?.dispose();
      return null;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    final fallback = Theme.of(context).colorScheme.surface;
    canvas.drawColor(_surfaceTheme.bottom ?? fallback, BlendMode.src);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, pageSize.width, content.top),
      Paint()..color = _surfaceTheme.top ?? fallback,
    );
    if (toolbar != null && bar is RenderBox) {
      canvas.drawImageRect(
        toolbar,
        Rect.fromLTWH(
          0,
          0,
          toolbar.width.toDouble(),
          toolbar.height.toDouble(),
        ),
        (bar.localToGlobal(Offset.zero) - origin) & bar.size,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    canvas.drawImageRect(
      webImage,
      Rect.fromLTWH(
        0,
        0,
        webImage.width.toDouble(),
        webImage.height.toDouble(),
      ),
      content,
      Paint()..filterQuality = FilterQuality.low,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(360, (pageSize.height * scale).ceil());
    } finally {
      picture.dispose();
      toolbar?.dispose();
    }
  }
}
