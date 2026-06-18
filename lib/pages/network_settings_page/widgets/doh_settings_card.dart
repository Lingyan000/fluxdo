import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/doh_proxy/cert_preference_service.dart';
import '../../../services/network/doh_proxy/per_device_cert_service.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import '../../../services/toast_service.dart';
import '../doh_detail_settings_page.dart';
import 'ios_cert_install_dialog.dart';

/// DOH 设置卡片（简化版：开关 + 状态 + "更多设置"入口）
class DohSettingsCard extends StatelessWidget {
  const DohSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final service = NetworkSettingsService.instance;
    final vpnService = VpnAutoToggleService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        service.notifier,
        service.isApplying,
        vpnService.enabledNotifier,
        vpnService.vpnActiveNotifier,
        vpnService.suppressionNotifier,
      ]),
      builder: (context, _) {
        final settings = service.notifier.value;
        final isApplying = service.isApplying.value;
        final isSuppressedByVpn = vpnService.enabled && vpnService.isDohSuppressed;
        return _DohSettingsCardInner(
          settings: settings,
          isApplying: isApplying,
          isSuppressedByVpn: isSuppressedByVpn,
        );
      },
    );
  }
}

class _DohSettingsCardInner extends StatelessWidget {
  const _DohSettingsCardInner({
    required this.settings,
    required this.isApplying,
    this.isSuppressedByVpn = false,
  });

  final NetworkSettings settings;
  final bool isApplying;
  final bool isSuppressedByVpn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = NetworkSettingsService.instance;
    final proxyService = service.proxyService;
    final isRunning = proxyService.isRunning;
    final port = settings.proxyPort;
    final showLoading = isApplying ||
        service.pendingStart ||
        (settings.dohEnabled && !isRunning && !service.lastStartFailed);
    // VPN 活跃 + 自动切换开启 = 接管期，DOH 开关在此期间一律锁定
    final vpnLocked = VpnAutoToggleService.instance.enabled &&
        VpnAutoToggleService.instance.vpnActive;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: settings.dohEnabled
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: settings.dohEnabled
            ? BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.3))
            : BorderSide.none,
      ),
      child: Column(
        children: [
          // DOH 开关
          SwitchListTile(
            title: const Text('DNS over HTTPS'),
            subtitle: Text(
              vpnLocked
                  ? (isSuppressedByVpn
                      ? context.l10n.dohSettings_suppressedByVpn
                      : context.l10n.vpnToggle_lockedHint)
                  : settings.dohEnabled
                      ? context.l10n.dohSettings_enabledDesc
                      : context.l10n.dohSettings_disabledDesc,
            ),
            secondary: Icon(
              (vpnLocked ? isSuppressedByVpn : settings.dohEnabled)
                  ? Icons.shield
                  : Icons.shield_outlined,
              color: (vpnLocked ? isSuppressedByVpn : settings.dohEnabled)
                  ? theme.colorScheme.primary
                  : null,
            ),
            // VPN 接管期间：开关照常可拨，但操作的是"VPN 断开后是否启用"的意图标记，
            // 不立即生效（功能仍由自动切换接管，subtitle 说明当前状态）。
            value: vpnLocked ? isSuppressedByVpn : settings.dohEnabled,
            onChanged: vpnLocked
                ? (value) =>
                    VpnAutoToggleService.instance.setDohSuppressed(value)
                : (value) async {
                    await service.setDohEnabled(value);
                  },
          ),

          // 仅在开启 DOH 后显示以下内容
          if (settings.dohEnabled) ...[
            // 证书引导（iOS: 安装引导，其他平台: per-device 开关）
            _CertGuide(isApplying: isApplying),

            // 状态区域
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            _buildStatusArea(context, theme, service, proxyService, isRunning, port, showLoading),

            // 启动失败提示
            if (!isRunning && !isApplying && service.lastStartFailed)
              _buildFailureHint(context, theme, service, proxyService),

            // 更多设置入口
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            ListTile(
              leading: const Icon(Icons.tune),
              title: Text(context.l10n.dohSettings_moreSettings),
              subtitle: Text(context.l10n.dohSettings_moreSettingsDesc),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DohDetailSettingsPage(),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusArea(
    BuildContext context,
    ThemeData theme,
    NetworkSettingsService service,
    dynamic proxyService,
    bool isRunning,
    int? port,
    bool showLoading,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: showLoading
                ? _buildStatusChip(
                    theme,
                    key: const ValueKey('applying'),
                    customIcon: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    label: service.wasRunningBeforeApply ? context.l10n.dohSettings_restarting : context.l10n.dohSettings_starting,
                    color: theme.colorScheme.primary,
                  )
                : _buildStatusChip(
                    theme,
                    key: ValueKey('status_${isRunning}_${service.lastStartFailed}'),
                    icon: isRunning
                        ? Icons.check_circle
                        : service.lastStartFailed
                            ? Icons.error
                            : Icons.hourglass_top,
                    label: isRunning ? context.l10n.dohSettings_proxyRunning : context.l10n.dohSettings_proxyNotStarted,
                    color: isRunning ? Colors.green : theme.colorScheme.error,
                  ),
          ),
          const SizedBox(width: 12),
          if (port != null && isRunning)
            _buildStatusChip(
              theme,
              icon: Icons.lan,
              label: context.l10n.dohSettings_port(port),
              color: theme.colorScheme.secondary,
            ),
          if (isRunning) ...[
            const Spacer(),
            IconButton(
              onPressed: isApplying ? null : service.restartProxy,
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: context.l10n.dohSettings_restartProxy,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFailureHint(
    BuildContext context,
    ThemeData theme,
    NetworkSettingsService service,
    dynamic proxyService,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.dohSettings_proxyStartFailed,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              TextButton(
                onPressed: isApplying ? null : service.restartProxy,
                child: Text(context.l10n.common_retry),
              ),
            ],
          ),
          if (proxyService.lastError != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      proxyService.lastError!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: proxyService.lastError!));
                      ToastService.showInfo(S.current.dohSettings_errorCopied);
                    },
                    child: Icon(
                      Icons.copy,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(
    ThemeData theme, {
    Key? key,
    IconData? icon,
    Widget? customIcon,
    required String label,
    required Color color,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (customIcon != null)
            customIcon
          else if (icon != null)
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// 证书引导 Widget
///
/// iOS（强制 per-device）：显示安装引导
/// 其他平台：显示 per-device 证书开关
class _CertGuide extends StatefulWidget {
  const _CertGuide({required this.isApplying});

  final bool isApplying;

  @override
  State<_CertGuide> createState() => _CertGuideState();
}

class _CertGuideState extends State<_CertGuide> {
  bool _installed = false;
  bool _loading = true;
  bool _perDeviceEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    if (CertPreferenceService.isPerDeviceRequired) {
      // iOS: 需要安装引导; macOS: 钥匙串自动处理，无需引导
      if (Platform.isIOS) {
        final installed = await PerDeviceCertService.instance.isCertInstalled();
        if (mounted) setState(() { _installed = installed; _loading = false; });
      } else {
        // macOS: per-device 强制启用，钥匙串自动添加，不显示引导
        if (mounted) setState(() { _loading = false; });
      }
    } else {
      final usePerDevice = await CertPreferenceService.usePerDevice();
      if (mounted) setState(() { _perDeviceEnabled = usePerDevice; _loading = false; });
    }
  }

  Future<void> _showIosDialog() async {
    final result = await showIosCertInstallDialog(context);
    if (result == true && mounted) {
      setState(() => _installed = true);
    }
  }

  Future<void> _togglePerDevice(bool value) async {
    await CertPreferenceService.setUsePerDevice(value);
    setState(() => _perDeviceEnabled = value);
    // 重启代理以应用新证书
    await NetworkSettingsService.instance.restartProxy();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    final theme = Theme.of(context);

    final l10n = context.l10n;

    // macOS: per-device 强制但钥匙串自动处理，不显示引导
    if (Platform.isMacOS) {
      return const SizedBox.shrink();
    }

    // iOS: 强制 per-device，显示安装引导
    if (Platform.isIOS) {
      return Column(
        children: [
          Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
          ListTile(
            leading: Icon(
              _installed ? Icons.verified_user : Icons.security,
              color: _installed ? Colors.green : theme.colorScheme.error,
            ),
            title: Text(_installed ? l10n.dohSettings_certInstalled : l10n.dohSettings_certRequired),
            subtitle: Text(
              _installed ? l10n.dohSettings_certReinstallHint : l10n.dohSettings_certInstallHint,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
            ),
            trailing: _installed
                ? OutlinedButton(
                    onPressed: _showIosDialog,
                    child: Text(l10n.dohSettings_certReinstall),
                  )
                : FilledButton(
                    onPressed: _showIosDialog,
                    child: Text(l10n.dohSettings_certInstall),
                  ),
          ),
        ],
      );
    }

    // 其他平台: per-device 证书开关
    return Column(
      children: [
        Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
        SwitchListTile(
          secondary: Icon(
            _perDeviceEnabled ? Icons.verified_user : Icons.security,
            color: _perDeviceEnabled ? Colors.green : null,
          ),
          title: Text(l10n.dohSettings_perDeviceCert),
          subtitle: Text(
            _perDeviceEnabled
                ? l10n.dohSettings_perDeviceCertEnabledDesc
                : l10n.dohSettings_perDeviceCertDisabledDesc,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
          ),
          value: _perDeviceEnabled,
          onChanged: widget.isApplying ? null : _togglePerDevice,
        ),
      ],
    );
  }
}
