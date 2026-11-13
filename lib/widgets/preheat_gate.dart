import 'package:common_ui/common_ui.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app_icons/app_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/s.dart';
import '../pages/about_page.dart';
import '../pages/network_settings_page/network_settings_page.dart';
import '../providers/app_icon_provider.dart';
import '../providers/theme_provider.dart';
import '../services/browser_trust_coordinator.dart';
import '../services/cf_challenge_service.dart';
import '../services/connectivity_service.dart';
import '../services/discourse/discourse_service.dart';
import '../services/emoji_handler.dart';
import '../services/launch_splash_handoff.dart';
import '../services/log/log_writer.dart';
import '../services/migration_service.dart';
import '../utils/dialog_utils.dart';
import '../utils/responsive.dart' show Breakpoints;
import '../widgets/common/ambient_background.dart';
import '../widgets/common/cloudflare_mark.dart';
import '../widgets/common/error_view.dart';

import 'preheat_logo.dart';
import 'preheat_logo_motion.g.dart';

class PreheatGate extends ConsumerStatefulWidget {
  final Widget child;

  const PreheatGate({super.key, required this.child});

  @override
  ConsumerState<PreheatGate> createState() => _PreheatGateState();
}

enum _GatePhase { loading, exiting, done, failed }

class _PreheatGateState extends ConsumerState<PreheatGate>
    with TickerProviderStateMixin {
  /// 描线入场（时长来自规格，与原生启动屏同源）
  late final AnimationController _entry = AnimationController(
    duration: logoMotionDuration,
    vsync: this,
  );

  /// 退场：logo 收缩蓄力后冲出 → 启动页淡出 → 首页缓缓落位
  late final AnimationController _exit = AnimationController(
    duration: _ExitTimeline.duration,
    vsync: this,
  );

  /// logo 已完整呈现给用户：描线完成，且原生启动屏已撤下。
  /// 光晕、角标衍生与退场都以此为起点，避免在原生屏底下悄悄播完
  final ValueNotifier<bool> _logoShown = ValueNotifier(false);

  _GatePhase _phase = _GatePhase.loading;

  /// 首页已垫在启动页下：退场开始前先完成首次构建
  bool _homeMounted = false;
  Object? _error;
  late final AppIconStyle _iconStyle;

  /// 每次加载的代次：跳过/重试后，过期的加载结果不再推进页面
  int _attempt = 0;

  bool get _reduceMotion => WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .disableAnimations;

  @override
  void initState() {
    super.initState();
    // 同步读取：异步读会让现代图标用户的首帧先闪一下经典 logo
    final saved = ref
        .read(sharedPreferencesProvider)
        .getString('pref_app_icon');
    _iconStyle = saved == 'modern' ? AppIconStyle.modern : AppIconStyle.classic;
    _entry.addStatusListener((_) => _updateLogoShown());
    LaunchSplashHandoff.nativeSplashVisible.addListener(_onNativeSplashChanged);
    LaunchSplashHandoff.nativeLogo.addListener(_onNativeLogoChanged);
    if (LaunchSplashHandoff.nativeDrewLogo) {
      // 原生启动屏已播完同一段描线：首帧直接接手完整 logo
      _entry.value = 1;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => LaunchSplashHandoff.armFallback(),
      );
    } else if (_reduceMotion) {
      _entry.value = 1;
    } else {
      _entry.forward();
    }
    _updateLogoShown();
    // 延迟到下一帧执行，确保 context 可用（_preload 内部可能弹 Dialog）
    Future.microtask(_run);
  }

  /// 原生屏实际没画 logo（系统改用了纯色启动屏）：先清空，撤下后从空白描线
  bool _strokeAfterNative = false;

  void _onNativeLogoChanged() {
    if (LaunchSplashHandoff.nativeLogo.value || _reduceMotion) return;
    _entry.value = 0;
    _strokeAfterNative = true;
  }

  void _onNativeSplashChanged() {
    if (_strokeAfterNative && !LaunchSplashHandoff.nativeSplashVisible.value) {
      _strokeAfterNative = false;
      _entry.forward();
    }
    _updateLogoShown();
  }

  void _updateLogoShown() {
    _logoShown.value =
        _entry.isCompleted && !LaunchSplashHandoff.nativeSplashVisible.value;
  }

  @override
  void dispose() {
    LaunchSplashHandoff.nativeSplashVisible.removeListener(
      _onNativeSplashChanged,
    );
    LaunchSplashHandoff.nativeLogo.removeListener(_onNativeLogoChanged);
    _logoShown.dispose();
    _entry.dispose();
    _exit.dispose();
    super.dispose();
  }

  /// logo 完整呈现后才退场：快路径最多等完描线（≤1 秒），不截断
  Future<void> _waitLogoShown() async {
    if (_logoShown.value) return;
    final shown = Completer<void>();
    void listener() {
      if (_logoShown.value && !shown.isCompleted) shown.complete();
    }

    _logoShown.addListener(listener);
    try {
      await shown.future;
    } finally {
      _logoShown.removeListener(listener);
    }
  }

  Future<void> _run() async {
    final attempt = ++_attempt;
    final ok = await _preload();
    if (!mounted || attempt != _attempt) return;
    if (!ok) {
      setState(() => _phase = _GatePhase.failed);
      return;
    }
    // 首页首次构建很重，与退场同帧会让这一帧吞掉动画开头：
    // 先垫在启动页下构建，等它画完首帧再开始计时
    setState(() => _homeMounted = true);
    await _waitLogoShown();
    if (!mounted || attempt != _attempt) return;
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || attempt != _attempt) return;
    try {
      setState(() => _phase = _GatePhase.exiting);
      if (_reduceMotion) {
        _exit.value = 1;
      } else {
        await _exit.forward().orCancel;
      }
    } on TickerCanceled {
      return;
    }
    if (mounted && attempt == _attempt) {
      setState(() => _phase = _GatePhase.done);
    }
  }

  Future<bool> _preload() async {
    try {
      // 迁移已在 main() 中执行完毕，这里展示提示
      if (MigrationService.requiresRelogin && mounted) {
        await _showReloginDialog();
      }

      await BrowserTrustCoordinator.instance.ensurePreloaded(
        reason: 'preheat_gate',
      );

      DiscourseService().getEnabledReactions();
      EmojiHandler().init();

      _error = null;
      return true;
    } catch (e) {
      debugPrint('[PreheatGate] Preload failed: $e');
      _error = e;
      return false;
    }
  }

  /// 弹出重新登录提示，用户确认后继续
  Future<void> _showReloginDialog() async {
    MigrationService.requiresRelogin = false; // 只弹一次
    await showAppDialog(
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.migration_title),
        content: Text(S.current.migration_reloginRequired),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  void _retry() {
    _exit.value = 0;
    setState(() {
      _phase = _GatePhase.loading;
      _homeMounted = false;
    });
    _run();
  }

  void _skip() {
    _attempt++;
    setState(() {
      _error ??= TimeoutException(S.current.preheat_userSkipped);
      _phase = _GatePhase.failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 无论加载状态如何，都设置 context
    // 避免 CF 验证等待 context 而 context 等待加载完成导致的死锁
    BrowserTrustCoordinator.instance.setNavigatorContext(context);

    final Widget current = _phase == _GatePhase.failed
        ? _PreheatFailed(
            key: const ValueKey('error'),
            error: _error,
            onRetry: _retry,
          )
        : _buildLaunch();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchOutCurve: Curves.easeOut,
      // 新页面直接在底层就位，只让旧页面在上层淡出：首页首帧不和
      // 启动页做双页交叉合成，也不做整页缩放
      layoutBuilder: (current, previous) =>
          Stack(alignment: Alignment.center, children: [?current, ...previous]),
      transitionBuilder: (child, animation) =>
          _FadeOutOnly(animation: animation, child: child),
      child: current,
    );
  }

  /// 首页在底层，启动页在上层；退场时启动页淡出露出首页。
  /// 首页始终挂在同一位置，退场结束移除上层时不会重建。
  Widget _buildLaunch() {
    return Stack(
      key: const ValueKey('launch'),
      fit: StackFit.expand,
      children: [
        if (_homeMounted)
          KeyedSubtree(
            key: const ValueKey('content'),
            // 垫在启动页下等待期间不接收输入
            child: IgnorePointer(
              ignoring: _phase == _GatePhase.loading,
              child: _ExitHome(exit: _exit, child: widget.child),
            ),
          ),
        if (_phase != _GatePhase.done)
          _PreheatLoading(
            key: const ValueKey('loading'),
            entry: _entry,
            logoShown: _logoShown,
            exit: _exit,
            exiting: _phase == _GatePhase.exiting,
            onSkip: _skip,
            iconStyle: _iconStyle,
          ),
      ],
    );
  }
}

/// 退场时间线：三条曲线同时开始。
/// - logo 先收缩蓄力，随后加速冲向镜头，冲出途中淡出；
/// - 启动页（底色、文字）在中段短促淡出；
/// - 首页始终不透明地垫在底层，从略大的尺寸缓缓落位到原尺寸。
/// 桌面亚克力窗口底色透明，没有可淡出的底色：改为首页同步淡入。
abstract final class _ExitTimeline {
  static bool get opaqueBackdrop =>
      defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.windows;

  static const duration = Duration(milliseconds: 1200);

  /// 以下区间均以加速曲线后的进度计
  static const _anticipateEnd = 0.08;
  static const _anticipateScale = 0.8;
  static const _veilStart = 0.1;
  static const _veilEnd = 0.2;

  /// 冲出段：彩色 logo 不能放大到铺满屏幕，只冲到数倍大小，
  /// 并在底色淡完之前先行消失
  static const _burstScale = 4.0;
  static const _logoFadeEnd = 0.14;

  /// 首页落位前的起始缩放
  static const _homeStartScale = 1.1;

  static double _accel(double t) => Curves.easeInCubic.transform(t);

  static double _segment(double u, double start, double end) =>
      ((u - start) / (end - start)).clamp(0.0, 1.0);

  static double logoScale(double t) {
    final u = _accel(t);
    if (u <= _anticipateEnd) {
      return 1 - (1 - _anticipateScale) * u / _anticipateEnd;
    }
    return _anticipateScale +
        (_burstScale - _anticipateScale) *
            _segment(u, _anticipateEnd, _veilEnd);
  }

  static double logoOpacity(double t) =>
      1 - _segment(_accel(t), _anticipateEnd, _logoFadeEnd);

  /// 启动页（底色与文字）的不透明度
  static double veil(double t) => 1 - _segment(_accel(t), _veilStart, _veilEnd);

  static double homeScale(double t) =>
      _homeStartScale -
      (_homeStartScale - 1) * Curves.easeInOutCubic.transform(t);
}

/// 退场时垫在启动页下的首页：从略大缓缓落位；桌面同时随启动页淡出而淡入。
/// 宽屏不缩放，大窗口里整页缩放的位移过于明显。
class _ExitHome extends StatelessWidget {
  final Animation<double> exit;
  final Widget child;

  const _ExitHome({required this.exit, required this.child});

  @override
  Widget build(BuildContext context) {
    final scaled = MediaQuery.sizeOf(context).width < Breakpoints.mobile;
    final opaqueBackdrop = _ExitTimeline.opaqueBackdrop;
    return AnimatedBuilder(
      animation: exit,
      child: child,
      builder: (context, child) => Transform.scale(
        scale: scaled ? _ExitTimeline.homeScale(exit.value) : 1,
        child: Opacity(
          opacity: opaqueBackdrop ? 1 : 1 - _ExitTimeline.veil(exit.value),
          child: child,
        ),
      ),
    );
  }
}

/// 只在退场（动画反向）时淡出，入场直接不透明。
///
/// 结构始终是 IgnorePointer + Opacity，避免进退场切换时子树被重建；
/// Opacity 为 1 时不产生图层。
class _FadeOutOnly extends AnimatedWidget {
  final Widget child;

  const _FadeOutOnly({
    required Animation<double> animation,
    required this.child,
  }) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    final animation = listenable as Animation<double>;
    final leaving =
        animation.status == AnimationStatus.reverse ||
        animation.status == AnimationStatus.dismissed;
    return IgnorePointer(
      ignoring: leaving,
      child: Opacity(opacity: leaving ? animation.value : 1.0, child: child),
    );
  }
}

/// 启动页等待状态，同一时刻只展示优先级最高的一个
enum _PreheatStatus {
  connecting(Symbols.cloud_sync_rounded),
  slow(Symbols.hourglass_top_rounded),
  browser(Symbols.language_rounded),
  fallback(Symbols.alt_route_rounded),
  verifying(null),
  offline(Symbols.wifi_off_rounded, alert: true);

  const _PreheatStatus(this.icon, {this.alert = false});

  /// 为 null 时角标改用品牌标志（CF 验证显示 Cloudflare 云朵）
  final IconData? icon;

  /// 需要用户介入的状态，角标用错误色；其余一律常规色
  final bool alert;

  String label(BuildContext context) => switch (this) {
    connecting => context.l10n.preheat_statusConnecting,
    slow => context.l10n.preheat_statusSlow,
    browser => context.l10n.preheat_statusBrowser,
    fallback => context.l10n.preheat_statusFallback,
    verifying => context.l10n.preheat_cfVerifying,
    offline => context.l10n.preheat_statusOffline,
  };
}

class _PreheatLoading extends StatefulWidget {
  final Animation<double> entry;
  final ValueListenable<bool> logoShown;
  final Animation<double> exit;
  final bool exiting;
  final VoidCallback? onSkip;
  final AppIconStyle iconStyle;

  const _PreheatLoading({
    super.key,
    required this.entry,
    required this.logoShown,
    required this.exit,
    required this.exiting,
    this.onSkip,
    required this.iconStyle,
  });

  @override
  State<_PreheatLoading> createState() => _PreheatLoadingState();
}

class _PreheatLoadingState extends State<_PreheatLoading> {
  /// 与原生启动屏 logo 等大（规格单一来源）
  static const double _logoSize = logoMotionLogoSize;

  static const double _badgeSize = 30;
  static const Duration _badgeFadeDuration = Duration(milliseconds: 120);

  /// 快路径不出任何状态，超过该时长仍在加载才展示
  static const Duration _statusDelay = Duration(milliseconds: 1200);

  /// 同一阶段停留超过该时长，提示网络较慢
  static const Duration _slowAfter = Duration(seconds: 8);

  final _coordinator = BrowserTrustCoordinator.instance;
  final _cf = CfChallengeService();

  _PreheatStatus? _paintedStatus;
  _PreheatStatus? _exitStatus;

  bool _showSkip = false;
  bool _statusRevealed = false;
  bool _slow = false;
  bool _offline = false;
  Timer? _skipTimer;
  Timer? _revealTimer;
  Timer? _slowTimer;
  StreamSubscription<bool>? _connectivitySub;
  String? _version;

  @override
  void initState() {
    super.initState();
    // 启动页可见期间由它承接 CF 验证状态，验证页不再显示胶囊
    _cf.registerStatusHost();
    _cf.presentationNotifier.addListener(_onStatusInputChanged);
    _coordinator.preloadStage.addListener(_onStageChanged);

    // 连通性服务正式初始化在 MainPage，启动页先拉起（幂等）以便感知断网
    final connectivity = ConnectivityService()..init();
    _offline = !connectivity.isConnected;
    _connectivitySub = connectivity.connectionStream.listen((connected) {
      _update(() => _offline = !connected);
    });

    _revealTimer = Timer(_statusDelay, () {
      _update(() => _statusRevealed = true);
    });
    _restartSlowTimer();
    if (widget.onSkip != null) {
      _skipTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _showSkip = true);
      });
    }
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  @override
  void didUpdateWidget(covariant _PreheatLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting && !oldWidget.exiting) {
      // 保留上一帧的状态：预加载完成会清空阶段，不能在退场时闪回“连接中”。
      _exitStatus = _paintedStatus ?? _status;
    }
  }

  @override
  void dispose() {
    _cf.unregisterStatusHost();
    _cf.presentationNotifier.removeListener(_onStatusInputChanged);
    _coordinator.preloadStage.removeListener(_onStageChanged);
    _connectivitySub?.cancel();
    _skipTimer?.cancel();
    _revealTimer?.cancel();
    _slowTimer?.cancel();
    super.dispose();
  }

  void _update(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  void _onStatusInputChanged() => _update(() {});

  void _onStageChanged() {
    _restartSlowTimer();
    _onStatusInputChanged();
  }

  /// 换阶段即重新计时，"较慢"只针对当前阶段的停留时长
  void _restartSlowTimer() {
    _slow = false;
    _slowTimer?.cancel();
    _slowTimer = Timer(_slowAfter, () => _update(() => _slow = true));
  }

  _PreheatStatus get _status {
    if (_exitStatus != null) return _exitStatus!;
    if (_offline) return _PreheatStatus.offline;
    final presentation = _cf.presentationNotifier.value;
    if (presentation != null && presentation != CfVerifyPresentation.hidden) {
      return _PreheatStatus.verifying;
    }
    return switch (_coordinator.preloadStage.value) {
      BrowserTrustPreloadStage.fallback => _PreheatStatus.fallback,
      BrowserTrustPreloadStage.webView =>
        _slow ? _PreheatStatus.slow : _PreheatStatus.browser,
      BrowserTrustPreloadStage.native ||
      null => _slow ? _PreheatStatus.slow : _PreheatStatus.connecting,
    };
  }

  /// 断网与 CF 验证是用户需要知道的，不等延迟直接展示
  bool get _statusVisible {
    final status = _status;
    return _statusRevealed ||
        status == _PreheatStatus.offline ||
        status == _PreheatStatus.verifying;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final brightness = theme.brightness;
    final opaqueBackdrop = _ExitTimeline.opaqueBackdrop;
    final status = _status;
    _paintedStatus = status;
    final statusVisible = _statusVisible;
    final spec = PreheatLogo.specOf(widget.iconStyle);
    // 与原生启动屏同一底色：主题底色在退场时随底色淡出透出
    final background = brightness == Brightness.dark
        ? logoMotionBackgroundDark
        : logoMotionBackgroundLight;
    final badgeFadeDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _badgeFadeDuration;
    // 固定在圆体右下角，只做短暂淡入淡出。
    final badgeCenter =
        Offset.fromDirection(
          math.pi / 4,
          spec.bodyRadiusRatio * _logoSize + 2,
        ) +
        const Offset(_logoSize / 2, _logoSize / 2);
    final badgeColor = status.alert
        ? colorScheme.errorContainer
        // 品牌标志自带颜色，衬中性底，避免与主题色撞色
        : status.icon == null
        ? colorScheme.surfaceContainerHighest
        : colorScheme.primaryContainer;
    final iconColor = status.alert
        ? colorScheme.onErrorContainer
        : colorScheme.onPrimaryContainer;

    final page = Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (opaqueBackdrop)
            CustomPaint(
              painter: _LaunchBackdropPainter(
                exit: widget.exit,
                background: background,
              ),
            ),
          // 文字随启动页底色一起淡出
          AnimatedBuilder(
            animation: widget.exit,
            builder: (context, child) => Opacity(
              opacity: _ExitTimeline.veil(widget.exit.value),
              child: child,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 上下等分留白，logo 严格居中，与原生启动屏同位；
                // 标题与状态挂在下半区，出现/变化都不推动 logo
                Column(
                  children: [
                    const Spacer(),
                    // 角标随 logo 一起蓄力、冲出
                    AnimatedBuilder(
                      animation: widget.exit,
                      builder: (context, child) => Transform.scale(
                        scale: _ExitTimeline.logoScale(widget.exit.value),
                        child: Opacity(
                          opacity: _ExitTimeline.logoOpacity(widget.exit.value),
                          child: child,
                        ),
                      ),
                      child: SizedBox.square(
                        dimension: _logoSize,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            PreheatLogo(
                              style: widget.iconStyle,
                              entry: widget.entry,
                              shown: widget.logoShown,
                              size: _logoSize,
                            ),
                            Positioned(
                              left: badgeCenter.dx - _badgeSize / 2,
                              top: badgeCenter.dy - _badgeSize / 2,
                              width: _badgeSize,
                              height: _badgeSize,
                              child: ValueListenableBuilder<bool>(
                                valueListenable: widget.logoShown,
                                builder: (context, shown, child) =>
                                    AnimatedOpacity(
                                      opacity:
                                          shown &&
                                              statusVisible &&
                                              !widget.exiting
                                          ? 1
                                          : 0,
                                      duration: badgeFadeDuration,
                                      curve: Curves.easeInOut,
                                      child: child,
                                    ),
                                child: AnimatedContainer(
                                  duration: badgeFadeDuration,
                                  decoration: BoxDecoration(
                                    color: badgeColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: AnimatedSwitcher(
                                      duration: badgeFadeDuration,
                                      transitionBuilder: (child, animation) =>
                                          FadeTransition(
                                            opacity: animation,
                                            child: child,
                                          ),
                                      child: status.icon == null
                                          ? CloudflareMark(
                                              key: ValueKey(status),
                                              width: 19,
                                            )
                                          : Icon(
                                              status.icon,
                                              key: ValueKey(status),
                                              size: 16,
                                              color: iconColor,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 原生启动屏只有 logo，标题在接管后淡入
                              ValueListenableBuilder<bool>(
                                valueListenable: widget.logoShown,
                                builder: (context, shown, child) =>
                                    TweenAnimationBuilder<double>(
                                      tween: Tween(
                                        begin: 0,
                                        // 快速加载完成时直接退场，避免标题刚出现就消失。
                                        end: shown && !widget.exiting ? 1 : 0,
                                      ),
                                      duration: const Duration(
                                        milliseconds: 500,
                                      ),
                                      curve: Curves.easeOut,
                                      builder: (context, value, child) =>
                                          Opacity(opacity: value, child: child),
                                      child: child,
                                    ),
                                child: Text(
                                  'FluxDO',
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(
                                        color: colorScheme.onSurface,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 1.5,
                                      ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              AnimatedOpacity(
                                opacity: statusVisible && !widget.exiting
                                    ? 1.0
                                    : 0.0,
                                duration: const Duration(milliseconds: 300),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  child: Text(
                                    status.label(context),
                                    key: ValueKey(status),
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 跳过按钮常驻树中,超时后淡入上移出现
                        IgnorePointer(
                          ignoring: !_showSkip || widget.exiting,
                          child: AnimatedOpacity(
                            opacity: _showSkip ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOut,
                            child: AnimatedSlide(
                              offset: _showSkip
                                  ? Offset.zero
                                  : const Offset(0, 0.4),
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeOutCubic,
                              child: TextButton(
                                onPressed: widget.onSkip,
                                child: Text(
                                  context.l10n.common_skip,
                                  style: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _version != null ? 'v$_version' : '',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // 退场期间不再接收点击（下层首页尚未完全显现）
    return IgnorePointer(ignoring: widget.exiting, child: page);
  }
}

/// 启动页底色，与原生启动屏一致；退场时匀速淡出露出下层首页。
class _LaunchBackdropPainter extends CustomPainter {
  _LaunchBackdropPainter({required this.exit, required this.background})
    : super(repaint: exit);

  final Animation<double> exit;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = _ExitTimeline.veil(exit.value);
    if (alpha <= 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = background.withValues(alpha: background.a * alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _LaunchBackdropPainter oldDelegate) =>
      oldDelegate.background != background;
}

class _PreheatFailed extends StatelessWidget {
  final VoidCallback onRetry;
  final Object? error;

  const _PreheatFailed({super.key, required this.onRetry, this.error});

  void _openAbout(BuildContext context) {
    Navigator.of(
      context,
    ).push(InteractionPageRoute(builder: (_) => const AboutPage()));
  }

  void _openNetworkSettings(BuildContext context) {
    Navigator.of(
      context,
    ).push(InteractionPageRoute(builder: (_) => const NetworkSettingsPage()));
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.common_logout),
        content: Text(context.l10n.preheat_logoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.common_exit),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      // 记录主动退出日志（网络错误页面）
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'lifecycle',
        'event': 'logout_active',
        'message': S.current.preheat_logoutMessage,
      });
      await DiscourseService().logout(callApi: false, refreshPreload: false);
      onRetry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasAcrylic = Platform.isMacOS || Platform.isWindows;

    return Scaffold(
      backgroundColor: hasAcrylic ? Colors.transparent : colorScheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            // 右上角：关于 + 网络设置
            Positioned(
              top: 16,
              right: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AmbientIconButton(
                    icon: Symbols.info_rounded,
                    tooltip: context.l10n.common_about,
                    onPressed: () => _openAbout(context),
                  ),
                  const SizedBox(width: 8),
                  AmbientIconButton(
                    icon: Symbols.network_check_rounded,
                    tooltip: context.l10n.preheat_networkSettings,
                    onPressed: () => _openNetworkSettings(context),
                  ),
                ],
              ),
            ),
            // 居中错误内容复用公共 ErrorView(含 CF 手动验证、网络设置、查看详情)
            ErrorView(
              error: error ?? TimeoutException(S.current.preheat_userSkipped),
              onRetry: onRetry,
              retryLabel: context.l10n.preheat_retryConnection,
            ),
            // 退出登录是破坏性的兜底出口，降级为底部低强调文字按钮
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: TextButton.icon(
                  onPressed: () => _confirmLogout(context),
                  icon: const Icon(Symbols.logout_rounded, size: 18),
                  label: Text(context.l10n.common_logout),
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
