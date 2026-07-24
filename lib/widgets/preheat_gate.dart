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
import '../services/discourse/discourse_service.dart';
import '../services/emoji_handler.dart';
import '../services/log/log_writer.dart';
import '../services/migration_service.dart';
import '../utils/dialog_utils.dart';
import '../widgets/common/ambient_background.dart';
import '../widgets/common/error_view.dart';
import 'package:m3e_ui/m3e_ui.dart';
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
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeOut,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.95, end: 1.0).animate(animation),
                child: child,
              ),
            );
          },
          child: currentWidget,
        );
      },
    );
  }
}

class _PreheatLoading extends StatefulWidget {
  final VoidCallback? onSkip;
  final AppIconStyle iconStyle;

  const _PreheatLoading({super.key, this.onSkip, required this.iconStyle});

  @override
  State<_PreheatLoading> createState() => _PreheatLoadingState();
}

class _PreheatLoadingState extends State<_PreheatLoading> {
  bool _showSkip = false;
  Timer? _skipTimer;
  String? _version;

  @override
  void initState() {
    super.initState();
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
    _skipTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasAcrylic = Platform.isMacOS || Platform.isWindows;

    return Scaffold(
      backgroundColor: hasAcrylic ? Colors.transparent : colorScheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PreheatLogo(style: widget.iconStyle, size: 108),
                const SizedBox(height: 24),
                Text(
                  'FluxDO',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 56),
                const LoadingSpinner(size: 40),
              ],
            ),
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

class _PreheatFailed extends StatelessWidget {
  final VoidCallback onRetry;
  final Object? error;

  const _PreheatFailed({super.key, required this.onRetry, this.error});

  void _openAbout(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AboutPage()));
  }

  void _openNetworkSettings(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NetworkSettingsPage()));
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
            // 右上角：关于 + 网络设置 + 退出登录
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
                  const SizedBox(width: 8),
                  AmbientIconButton(
                    icon: Symbols.logout_rounded,
                    tooltip: context.l10n.common_logout,
                    onPressed: () => _confirmLogout(context),
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
          ],
        ),
      ),
    );
  }
}
