import 'package:common_ui/common_ui.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/s.dart';
import '../pages/about_page.dart';
import '../pages/network_settings_page/network_settings_page.dart';
import '../providers/app_icon_provider.dart';
import '../services/browser_trust_coordinator.dart';
import '../services/cf_challenge_service.dart';
import '../services/connectivity_service.dart';
import '../services/discourse/discourse_service.dart';
import '../services/emoji_handler.dart';
import '../services/log/log_writer.dart';
import '../services/migration_service.dart';
import '../utils/dialog_utils.dart';
import '../widgets/common/ambient_background.dart';
import '../widgets/common/cloudflare_mark.dart';
import '../widgets/common/error_view.dart';

import 'preheat_logo.dart';

class PreheatGate extends StatefulWidget {
  final Widget child;

  const PreheatGate({super.key, required this.child});

  @override
  State<PreheatGate> createState() => _PreheatGateState();
}

class _PreheatGateState extends State<PreheatGate> {
  late Future<bool> _loadFuture;
  Object? _error;
  AppIconStyle _iconStyle = AppIconStyle.classic;

  @override
  void initState() {
    super.initState();
    _readIconStyle();
    // 延迟到下一帧执行，确保 context 可用（_preload 内部可能弹 Dialog）
    _loadFuture = Future.microtask(() => _preload());
  }

  void _readIconStyle() {
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('pref_app_icon');
      final style = saved == 'modern'
          ? AppIconStyle.modern
          : AppIconStyle.classic;
      if (mounted && style != _iconStyle) {
        setState(() => _iconStyle = style);
      }
    });
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
    setState(() {
      _loadFuture = _preload();
    });
  }

  void _skip() {
    setState(() {
      _error ??= TimeoutException(S.current.preheat_userSkipped);
      _loadFuture = Future.value(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _loadFuture,
      builder: (context, snapshot) {
        // 无论加载状态如何，都设置 context
        // 避免 CF 验证等待 context 而 context 等待加载完成导致的死锁
        BrowserTrustCoordinator.instance.setNavigatorContext(context);

        Widget currentWidget;
        if (snapshot.connectionState != ConnectionState.done) {
          currentWidget = _PreheatLoading(
            key: const ValueKey('loading'),
            onSkip: _skip,
            iconStyle: _iconStyle,
          );
        } else if (snapshot.data == true) {
          currentWidget = KeyedSubtree(
            key: const ValueKey('content'),
            child: widget.child,
          );
        } else {
          currentWidget = _PreheatFailed(
            key: const ValueKey('error'),
            error: _error,
            onRetry: _retry,
          );
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchOutCurve: Curves.easeOut,
          // 新页面直接在底层就位，只让旧页面在上层淡出：首页首帧不和
          // 启动页做双页交叉合成，也不做整页缩放
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.center,
            children: [?current, ...previous],
          ),
          transitionBuilder: (child, animation) =>
              _FadeOutOnly(animation: animation, child: child),
          child: currentWidget,
        );
      },
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
  final VoidCallback? onSkip;
  final AppIconStyle iconStyle;

  const _PreheatLoading({super.key, this.onSkip, required this.iconStyle});

  @override
  State<_PreheatLoading> createState() => _PreheatLoadingState();
}

class _PreheatLoadingState extends State<_PreheatLoading> {
  /// 与原生启动屏 logo（splash_logo_*.xml）等大，改动需两边同步
  static const double _logoSize = 108;
  static const double _badgeSize = 30;

  /// 快路径不出任何状态，超过该时长仍在加载才展示
  static const Duration _statusDelay = Duration(milliseconds: 1200);

  /// 同一阶段停留超过该时长，提示网络较慢
  static const Duration _slowAfter = Duration(seconds: 8);

  final _coordinator = BrowserTrustCoordinator.instance;
  final _cf = CfChallengeService();

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
      if (mounted) setState(() => _offline = !connected);
    });

    _revealTimer = Timer(_statusDelay, () {
      if (mounted) setState(() => _statusRevealed = true);
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

  void _onStatusInputChanged() {
    if (mounted) setState(() {});
  }

  void _onStageChanged() {
    _restartSlowTimer();
    _onStatusInputChanged();
  }

  /// 换阶段即重新计时，"较慢"只针对当前阶段的停留时长
  void _restartSlowTimer() {
    _slow = false;
    _slowTimer?.cancel();
    _slowTimer = Timer(_slowAfter, () {
      if (mounted) setState(() => _slow = true);
    });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasAcrylic = Platform.isMacOS || Platform.isWindows;
    final status = _status;
    // 断网与 CF 验证是用户需要知道的，不等延迟直接展示
    final statusVisible =
        _statusRevealed ||
        status == _PreheatStatus.offline ||
        status == _PreheatStatus.verifying;
    // 角标落在 logo 圆周右下 45° 处
    const badgeOffset = _logoSize * 0.8 - _badgeSize / 2;

    return Scaffold(
      backgroundColor: hasAcrylic ? Colors.transparent : colorScheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
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
                    PreheatLogo(style: widget.iconStyle, size: _logoSize),
                    Positioned(
                      left: badgeOffset,
                      top: badgeOffset,
                      child: _PreheatStatusBadge(
                        status: status,
                        visible: statusVisible,
                        size: _badgeSize,
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 原生启动屏只有 logo，标题在接管后淡入
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOut,
                          builder: (context, value, child) =>
                              Opacity(opacity: value, child: child),
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
                    ignoring: !_showSkip,
                    child: AnimatedOpacity(
                      opacity: _showSkip ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                      child: AnimatedSlide(
                        offset: _showSkip ? Offset.zero : const Offset(0, 0.4),
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
    );
  }
}

/// logo 右下角的状态角标：外圈用页面底色描边，像"嵌"在 logo 上
class _PreheatStatusBadge extends StatelessWidget {
  final _PreheatStatus status;
  final bool visible;
  final double size;

  const _PreheatStatusBadge({
    required this.status,
    required this.visible,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = status.icon;
    // 品牌标志自带颜色，衬中性底，避免与主题色撞色
    final background = status.alert
        ? colorScheme.errorContainer
        : icon == null
        ? colorScheme.surfaceContainerHighest
        : colorScheme.primaryContainer;
    final foreground = status.alert
        ? colorScheme.onErrorContainer
        : colorScheme.onPrimaryContainer;

    return AnimatedScale(
      scale: visible ? 1.0 : 0.5,
      duration: const Duration(milliseconds: 300),
      curve: visible ? Curves.easeOutBack : Curves.easeIn,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.surface, width: 2.5),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: icon == null
                ? CloudflareMark(key: ValueKey(status), width: 19)
                : Icon(
                    icon,
                    key: ValueKey(status),
                    size: 16,
                    color: foreground,
                  ),
          ),
        ),
      ),
    );
  }
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
