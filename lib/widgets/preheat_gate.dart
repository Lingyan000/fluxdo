import 'package:common_ui/common_ui.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

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

  /// 退场：部件融合 → 圆体蓄力 → 化作窗口放大露出首页
  late final AnimationController _exit = AnimationController(
    duration: _ExitTimeline.duration,
    vsync: this,
  );

  /// logo 已完整呈现给用户：描线完成，且原生启动屏已撤下。
  /// 光晕、角标衍生与退场都以此为起点，避免在原生屏底下悄悄播完
  final ValueNotifier<bool> _logoShown = ValueNotifier(false);

  _GatePhase _phase = _GatePhase.loading;
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
    LaunchSplashHandoff.nativeSplashVisible.addListener(_updateLogoShown);
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

  void _updateLogoShown() {
    _logoShown.value =
        _entry.isCompleted && !LaunchSplashHandoff.nativeSplashVisible.value;
  }

  @override
  void dispose() {
    LaunchSplashHandoff.nativeSplashVisible.removeListener(_updateLogoShown);
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
    await _waitLogoShown();
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
    setState(() => _phase = _GatePhase.loading);
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

  /// 首页在底层，启动页在上层；退场时启动页在底色上开出窗口露出首页。
  /// 首页始终挂在同一位置，退场结束移除上层时不会重建。
  Widget _buildLaunch() {
    final showHome = _phase == _GatePhase.exiting || _phase == _GatePhase.done;
    return Stack(
      key: const ValueKey('launch'),
      fit: StackFit.expand,
      children: [
        if (showHome)
          KeyedSubtree(
            key: const ValueKey('content'),
            child: AnimatedBuilder(
              animation: _exit,
              child: widget.child,
              builder: (context, child) => Transform.scale(
                scale: _ExitTimeline.windowReveal
                    ? _ExitTimeline.homeScale(_exit.value)
                    : 1,
                child: child,
              ),
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

/// 退场时间线（占 [duration] 的比例）：
/// 0 ~ [mergeEnd] 内部部件并入圆体、角标缩回、文字淡出；
/// ~ [squeezeEnd] 圆体收缩蓄力；之后圆体化作窗口加速放大，首页从窗内显现。
abstract final class _ExitTimeline {
  static Duration get duration =>
      Duration(milliseconds: windowReveal ? 900 : 650);
  static const mergeDuration = Duration(milliseconds: 180);
  static double get mergeEnd =>
      mergeDuration.inMicroseconds / duration.inMicroseconds;
  static const squeezeEnd = 0.33;
  static const squeezeScale = 0.85;

  /// 桌面亚克力窗口底色透明，开窗无从遮挡，退场改为整体淡出
  static bool get windowReveal =>
      defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.windows;

  static double _seg(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  static double grow(double t) => _seg(t, squeezeEnd, 1);

  /// 窗口半径（圆体半径 [r] 的倍数换算前，单位与 [r]、[maxR] 一致）
  static double windowRadius(double t, double r, double maxR) {
    if (t < squeezeEnd) {
      final s = Curves.easeOut.transform(_seg(t, mergeEnd, squeezeEnd));
      return r * (1 - (1 - squeezeScale) * s);
    }
    final r0 = r * squeezeScale;
    return r0 + (maxR - r0) * Curves.easeIn.transform(grow(t));
  }

  /// 窗内圆体色的不透明度：放大初段淡出，首页显现
  static double bodyAlpha(double t) => 1 - _seg(grow(t), 0.15, 0.3);

  /// 首页从微放大回落到 1:1
  static double homeScale(double t) =>
      1.1 - 0.1 * Curves.easeOut.transform(grow(t));

  /// 标题、状态、版本号等文字的不透明度
  static double uiOpacity(double t) =>
      1 - _seg(t, 0, 135 / duration.inMilliseconds);
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

class _PreheatLoadingState extends State<_PreheatLoading>
    with SingleTickerProviderStateMixin {
  /// 与原生启动屏 logo 等大（规格单一来源）
  static const double _logoSize = logoMotionLogoSize;

  static const double _badgeSize = _BadgeGeometry.radius * 2 * _logoSize;

  /// 快路径不出任何状态，超过该时长仍在加载才展示
  static const Duration _statusDelay = Duration(milliseconds: 1200);

  /// 同一阶段停留超过该时长，提示网络较慢
  static const Duration _slowAfter = Duration(seconds: 8);

  final _coordinator = BrowserTrustCoordinator.instance;
  final _cf = CfChallengeService();

  /// 角标衍生进度：从圆体鼓出 → 拉到停靠位 → 液颈断开
  late final AnimationController _badge = AnimationController(
    duration: const Duration(milliseconds: 600),
    vsync: this,
  );
  late final Animation<double> _merge = widget.exit.drive(
    CurveTween(curve: Interval(0, _ExitTimeline.mergeEnd)),
  );
  late final Animation<double> _notch = _badge.drive(const _NotchRadius());

  bool _showSkip = false;
  bool _statusRevealed = false;
  bool _slow = false;
  bool _offline = false;
  Timer? _skipTimer;
  Timer? _revealTimer;
  Timer? _slowTimer;
  StreamSubscription<bool>? _connectivitySub;
  String? _version;
  ui.FragmentProgram? _budProgram;

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
    _BadgeBudPainter.load().then((program) {
      if (mounted) setState(() => _budProgram = program);
    }, onError: (Object e) => debugPrint('[PreheatGate] badge shader: $e'));
    widget.logoShown.addListener(_syncBadge);
    _syncBadge();
  }

  @override
  void didUpdateWidget(covariant _PreheatLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 退场时角标沿液颈缩回圆体，与部件融合同步
    if (widget.exiting && !oldWidget.exiting) {
      _badge.animateBack(0, duration: _ExitTimeline.mergeDuration);
    }
  }

  @override
  void dispose() {
    _cf.unregisterStatusHost();
    _cf.presentationNotifier.removeListener(_onStatusInputChanged);
    _coordinator.preloadStage.removeListener(_onStageChanged);
    widget.logoShown.removeListener(_syncBadge);
    _connectivitySub?.cancel();
    _skipTimer?.cancel();
    _revealTimer?.cancel();
    _slowTimer?.cancel();
    _badge.dispose();
    super.dispose();
  }

  void _update(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _syncBadge();
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

  /// 角标从圆体衍生而出，logo 完整呈现（描线画完、原生屏撤下）后才开始
  void _syncBadge() {
    if (widget.exiting) return;
    if (!_statusVisible) {
      _badge.reverse();
    } else if (widget.logoShown.value) {
      _badge.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final brightness = theme.brightness;
    final windowReveal = _ExitTimeline.windowReveal;
    final status = _status;
    final statusVisible = _statusVisible;
    final spec = PreheatLogo.specOf(widget.iconStyle);
    final bodyColor = spec.body.fillFor(brightness)!;
    // 与原生启动屏同一底色：主题底色只从退场窗口里透进来
    final background = brightness == Brightness.dark
        ? logoMotionBackgroundDark
        : logoMotionBackgroundLight;
    // 角标停靠位：沿右下 45° 落在圆体外缘
    final badgeCenter =
        _BadgeGeometry.center(spec.bodyRadiusRatio) * _logoSize +
        const Offset(_logoSize / 2, _logoSize / 2);
    final budColor = status.alert
        ? colorScheme.errorContainer
        // 品牌标志自带颜色，衬中性底，避免与主题色撞色
        : status.icon == null
        ? colorScheme.surfaceContainerHighest
        : colorScheme.primaryContainer;
    final iconColor = status.alert
        ? colorScheme.onErrorContainer
        : colorScheme.onPrimaryContainer;

    Widget fadeWithExit(Widget child) => AnimatedBuilder(
      animation: widget.exit,
      child: child,
      builder: (context, child) => Opacity(
        opacity: _ExitTimeline.uiOpacity(widget.exit.value),
        child: child,
      ),
    );

    final page = Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (windowReveal)
            CustomPaint(
              painter: _LaunchBackdropPainter(
                exit: widget.exit,
                background: background,
                body: bodyColor,
                bodyRadius: spec.bodyRadiusRatio * _logoSize,
              ),
            ),
          // 上下等分留白，logo 严格居中，与原生启动屏同位；
          // 标题与状态挂在下半区，出现/变化都不推动 logo
          Column(
            children: [
              const Spacer(),
              SizedBox.square(
                dimension: _logoSize,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 部件融合完成后圆体交给底层画布，作为窗口继续动画
                    AnimatedBuilder(
                      animation: widget.exit,
                      // 角标停靠后在 logo 上挖出透明缺口：只在与 logo
                      // 重叠处可见，不给角标描整圈边
                      child: PreheatLogo(
                        style: widget.iconStyle,
                        entry: widget.entry,
                        shown: widget.logoShown,
                        merge: _merge,
                        notch: _notch,
                        notchCenter: _BadgeGeometry.center(
                          spec.bodyRadiusRatio,
                        ),
                        size: _logoSize,
                      ),
                      builder: (context, child) => Opacity(
                        opacity:
                            windowReveal &&
                                widget.exit.value >= _ExitTimeline.mergeEnd
                            ? 0
                            : 1,
                        child: child,
                      ),
                    ),
                    Positioned(
                      left: -_logoSize * 0.2,
                      top: -_logoSize * 0.2,
                      right: -_logoSize * 0.2,
                      bottom: -_logoSize * 0.2,
                      child: TweenAnimationBuilder<Color?>(
                        tween: ColorTween(end: budColor),
                        duration: const Duration(milliseconds: 250),
                        builder: (context, color, _) => CustomPaint(
                          painter: _BadgeBudPainter(
                            program: _budProgram,
                            progress: _badge,
                            logoSize: _logoSize,
                            bodyRadius: spec.bodyRadiusRatio,
                            body: bodyColor,
                            badge: color ?? budColor,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: badgeCenter.dx - _badgeSize / 2,
                      top: badgeCenter.dy - _badgeSize / 2,
                      width: _badgeSize,
                      height: _badgeSize,
                      child: AnimatedBuilder(
                        animation: _badge,
                        builder: (context, child) => Opacity(
                          // 断开停靠后图标才浮现
                          opacity: ((_badge.value - 0.75) / 0.2).clamp(
                            0.0,
                            1.0,
                          ),
                          child: child,
                        ),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: animation,
                                    child: child,
                                  ),
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
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
                    child: fadeWithExit(
                      Column(
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
                                  duration: const Duration(milliseconds: 500),
                                  curve: Curves.easeOut,
                                  builder: (context, value, child) =>
                                      Opacity(opacity: value, child: child),
                                  child: child,
                                ),
                            child: Text(
                              'FluxDO',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          AnimatedOpacity(
                            opacity: statusVisible ? 1.0 : 0.0,
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
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: fadeWithExit(
                Column(
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
          ),
        ],
      ),
    );

    // 退场期间不再接收点击（下层首页尚未完全显现）
    final interactive = IgnorePointer(ignoring: widget.exiting, child: page);
    if (windowReveal) return interactive;
    // 桌面亚克力：用平缓曲线衔接融合与整体淡出。
    return AnimatedBuilder(
      animation: widget.exit,
      child: interactive,
      builder: (context, child) => Opacity(
        opacity: 1 - Curves.easeInOutSine.transform(widget.exit.value),
        child: child,
      ),
    );
  }
}

/// 启动页底色。退场时圆体化作窗口：底色上开出圆洞，洞内先是圆体色，
/// 随后淡出露出下层首页。底色与原生启动屏一致。
class _LaunchBackdropPainter extends CustomPainter {
  _LaunchBackdropPainter({
    required this.exit,
    required this.background,
    required this.body,
    required this.bodyRadius,
  }) : super(repaint: exit);

  final Animation<double> exit;
  final Color background;
  final Color body;
  final double bodyRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final t = exit.value;
    final rect = Offset.zero & size;
    if (t < _ExitTimeline.mergeEnd) {
      canvas.drawRect(rect, Paint()..color = background);
      return;
    }
    final center = size.center(Offset.zero);
    final maxR = size.center(Offset.zero).distance;
    final r = _ExitTimeline.windowRadius(t, bodyRadius, maxR);
    final window = Rect.fromCircle(center: center, radius: r);
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect)
        ..addOval(window),
      Paint()..color = background,
    );
    final alpha = _ExitTimeline.bodyAlpha(t);
    if (alpha > 0) {
      canvas.drawOval(window, Paint()..color = body.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(covariant _LaunchBackdropPainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.body != body ||
      oldDelegate.bodyRadius != bodyRadius;
}

/// 状态角标几何（logo 边长归一化），Dart 与 preheat_badge.frag 共用这一份
abstract final class _BadgeGeometry {
  /// 角标半径（logo 108 时为 15）
  static const double radius = 15 / 108;

  /// 停靠位：角标中心距圆体边缘的外移量
  static const double dock = 0.02;

  /// 停靠后角标与 logo 之间的透明缝宽
  static const double gap = 2.5 / 108;

  /// 停靠位中心（相对 logo 中心，沿右下 45°）
  static Offset center(double bodyRadius) =>
      Offset.fromDirection(math.pi / 4, bodyRadius + dock);

  /// logo 上挖出的缺口半径：角标到位、液颈断开后才出现，缝宽渐显
  static double notchRadius(double progress) {
    final t = ((progress - 0.7) / 0.22).clamp(0.0, 1.0);
    if (t <= 0) return 0;
    return radius + gap * Curves.easeInOut.transform(t);
  }
}

/// 角标进度 → logo 上缺口半径（归一化）
class _NotchRadius extends Animatable<double> {
  const _NotchRadius();

  @override
  double transform(double t) => _BadgeGeometry.notchRadius(t);
}

/// 状态角标的衍生效果（preheat_badge.frag）：从圆体右下鼓出、拉到停靠位后断开。
/// 画布以 logo 中心为中心；shader 未就绪时退化为普通圆形角标。
class _BadgeBudPainter extends CustomPainter {
  _BadgeBudPainter({
    required this.program,
    required this.progress,
    required this.logoSize,
    required this.bodyRadius,
    required this.body,
    required this.badge,
  }) : super(repaint: progress);

  static Future<ui.FragmentProgram>? _loading;
  static Future<ui.FragmentProgram> load() =>
      _loading ??= ui.FragmentProgram.fromAsset('shaders/preheat_badge.frag');

  final ui.FragmentProgram? program;
  final Animation<double> progress;
  final double logoSize;

  /// 圆体半径占 logo 边长的比例
  final double bodyRadius;
  final Color body;
  final Color badge;

  @override
  void paint(Canvas canvas, Size size) {
    final b = progress.value;
    if (b <= 0) return;
    final center = size.center(Offset.zero);
    final program = this.program;
    if (program == null) {
      canvas.drawCircle(
        center + _BadgeGeometry.center(bodyRadius) * logoSize,
        _BadgeGeometry.radius * logoSize * Curves.easeOut.transform(b),
        Paint()..color = badge,
      );
      return;
    }
    var i = 0;
    final shader = program.fragmentShader();
    void f(double v) => shader.setFloat(i++, v);
    void color(Color c) {
      f(c.r);
      f(c.g);
      f(c.b);
      f(c.a);
    }

    f(size.width);
    f(size.height);
    f(center.dx);
    f(center.dy);
    f(logoSize);
    f(bodyRadius);
    f(b);
    f(_BadgeGeometry.radius);
    f(_BadgeGeometry.dock);
    color(body);
    color(badge);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _BadgeBudPainter oldDelegate) =>
      oldDelegate.program != program ||
      oldDelegate.body != body ||
      oldDelegate.badge != badge ||
      oldDelegate.bodyRadius != bodyRadius;
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
