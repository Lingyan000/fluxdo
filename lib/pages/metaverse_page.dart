import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/theme_provider.dart';
import '../services/ldc_oauth_service.dart';
import '../services/cdk_oauth_service.dart';
import '../l10n/s.dart';
import '../services/toast_service.dart';
import '../providers/ldc_providers.dart';
import '../providers/cdk_providers.dart';
import '../widgets/ldc_balance_card.dart';
import '../widgets/cdk_balance_card.dart';
import '../modules/ldc_reward/ldc_reward.dart';

class MetaversePage extends ConsumerStatefulWidget {
  const MetaversePage({super.key});

  @override
  ConsumerState<MetaversePage> createState() => _MetaversePageState();
}

class _MetaversePageState extends ConsumerState<MetaversePage> {
  static const String _ldcEnabledKey = 'ldc_enabled';
  static const String _cdkEnabledKey = 'cdk_enabled';
  bool _ldcEnabled = false;
  bool _cdkEnabled = false;
  bool _ldcProcessing = false;
  bool _cdkProcessing = false;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(sharedPreferencesProvider);
    _ldcEnabled = prefs.getBool(_ldcEnabledKey) ?? false;
    _cdkEnabled = prefs.getBool(_cdkEnabledKey) ?? false;

    // 每次进入页面时刷新已启用服务的数据
    _refreshEnabledServices();
  }

  /// 先等 build() 完成，再调 refresh()，避免并发导致 build() 结果覆盖 refresh() 的错误状态
  Future<void> _refreshEnabledServices() async {
    if (_ldcEnabled) {
      await ref.read(ldcUserInfoProvider.future).catchError((_) => null);
      ref.read(ldcUserInfoProvider.notifier).refresh();
    }
    if (_cdkEnabled) {
      await ref.read(cdkUserInfoProvider.future).catchError((_) => null);
      ref.read(cdkUserInfoProvider.notifier).refresh();
    }
  }

  Future<void> _toggleLdc(bool value) async {
    if (_ldcProcessing) return;
    setState(() => _ldcProcessing = true);
    try {
      if (value) {
        await _enableLdc();
      } else {
        await _disableLdc();
      }
    } finally {
      if (mounted) {
        setState(() => _ldcProcessing = false);
      }
    }
  }

  Future<void> _enableLdc() async {
    try {
      final service = LdcOAuthService();
      final result = await service.authorize(context);

      if (result && mounted) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_ldcEnabledKey, true);
        setState(() => _ldcEnabled = true);
        ref.read(ldcUserInfoProvider.notifier).refresh();
        if (mounted) {
          ToastService.showSuccess(S.current.metaverse_ldcAuthSuccess);
        }
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.metaverse_authFailed(e.toString()));
      }
    }
  }

  Future<void> _disableLdc() async {
    try {
      final service = LdcOAuthService();
      await service.logout();
    } catch (e) {
      // 忽略登出错误
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ldcEnabledKey, false);
    setState(() => _ldcEnabled = false);
    ref.read(ldcUserInfoProvider.notifier).clear();
  }

  Future<void> _toggleCdk(bool value) async {
    if (_cdkProcessing) return;
    setState(() => _cdkProcessing = true);
    try {
      if (value) {
        await _enableCdk();
      } else {
        await _disableCdk();
      }
    } finally {
      if (mounted) {
        setState(() => _cdkProcessing = false);
      }
    }
  }

  Future<void> _enableCdk() async {
    try {
      final service = CdkOAuthService();
      final result = await service.authorize(context);

      if (result && mounted) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_cdkEnabledKey, true);
        setState(() => _cdkEnabled = true);
        ref.read(cdkUserInfoProvider.notifier).refresh();
        if (mounted) {
          ToastService.showSuccess(S.current.metaverse_cdkAuthSuccess);
        }
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.metaverse_authFailed(e.toString()));
      }
    }
  }

  Future<void> _disableCdk() async {
    try {
      final service = CdkOAuthService();
      await service.logout();
    } catch (e) {
      // 忽略登出错误
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cdkEnabledKey, false);
    setState(() => _cdkEnabled = false);
    ref.read(cdkUserInfoProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: CustomScrollView(
              slivers: [
                SliverAppBar.large(
                  title: Text(context.l10n.metaverse_title),
                  centerTitle: false,
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(
                      [
                        // 服务列表标题
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16, top: 8),
                          child: Text(
                            context.l10n.metaverse_myServices,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                        // LDC 服务卡片
                        _buildLdcServiceItem(theme),
                        const SizedBox(height: 16),
                        // CDK 服务卡片
                        _buildCdkServiceItem(theme),
                        const SizedBox(height: 16),
                        // LDC 打赏配置（仅在 LDC 已开启时显示）
                        if (_ldcEnabled) ...[
                          const LdcRewardConfigTile(),
                          const SizedBox(height: 16),
                        ],
                        // 更多服务占位符
                        _buildComingSoonItem(theme),
                        const SizedBox(height: 100), // 底部留白
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _reauthorizeLdc() async {
    if (_ldcProcessing) return;
    setState(() => _ldcProcessing = true);
    try {
      final service = LdcOAuthService();
      try {
        await service.logout();
      } catch (_) {
        // 忽略登出错误
      }
      if (!mounted) return;
      final result = await service.authorize(context);
      if (result && mounted) {
        ref.read(ldcUserInfoProvider.notifier).refresh();
        ToastService.showSuccess(S.current.metaverse_ldcReauthSuccess);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.metaverse_authFailed(e.toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _ldcProcessing = false);
      }
    }
  }

  Future<void> _reauthorizeCdk() async {
    if (_cdkProcessing) return;
    setState(() => _cdkProcessing = true);
    try {
      final service = CdkOAuthService();
      try {
        await service.logout();
      } catch (_) {
        // 忽略登出错误
      }
      if (!mounted) return;
      final result = await service.authorize(context);
      if (result && mounted) {
        ref.read(cdkUserInfoProvider.notifier).refresh();
        ToastService.showSuccess(S.current.metaverse_cdkReauthSuccess);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.metaverse_authFailed(e.toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _cdkProcessing = false);
      }
    }
  }

  Widget _buildLdcServiceItem(ThemeData theme) {
    if (_ldcEnabled) {
      return LdcBalanceCard(
        onDisable: _ldcProcessing ? null : () => _toggleLdc(false),
        onReauthorize: _ldcProcessing ? null : _reauthorizeLdc,
      );
    }

    // 未开启状态：展示连接卡片
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      child: InkWell(
        onTap: _ldcProcessing ? null : () => _toggleLdc(true),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.storefront_rounded,
                  size: 32,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.metaverse_ldcService,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.metaverse_ldcDesc,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_ldcProcessing)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton(
                  onPressed: () => _toggleLdc(true),
                   style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(context.l10n.common_enable),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCdkServiceItem(ThemeData theme) {
    if (_cdkEnabled) {
      return CdkBalanceCard(
        onDisable: _cdkProcessing ? null : () => _toggleCdk(false),
        onReauthorize: _cdkProcessing ? null : _reauthorizeCdk,
      );
    }

    // 未开启状态：展示连接卡片
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      child: InkWell(
        onTap: _cdkProcessing ? null : () => _toggleCdk(true),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.token_rounded,
                  size: 32,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.metaverse_cdkService,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.metaverse_cdkDesc,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_cdkProcessing)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton(
                  onPressed: () => _toggleCdk(true),
                   style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(context.l10n.common_enable),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComingSoonItem(ThemeData theme) {
    return Card(
      color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.hub_rounded,
                size: 32,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.metaverse_comingSoon,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
