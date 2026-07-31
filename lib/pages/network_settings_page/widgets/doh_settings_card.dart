import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/doh/webview_mitm_policy.dart';
import '../../../services/network/doh_proxy/cert_preference_service.dart';
import '../../../services/network/doh_proxy/per_device_cert_service.dart';
import '../../../services/network/doh_proxy/windows_cert_trust_service.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import '../../../services/network/webview/webview_adapter_settings_service.dart';
import '../../../services/toast_service.dart';
import '../../../services/windows_webview_environment_service.dart';
import 'package:m3e_ui/m3e_ui.dart';
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
        WebViewAdapterSettingsService.instance.notifier,
        WindowsWebViewEnvironmentService.instance.proxyRestartRequiredNotifier,
      ]),
      builder: (context, _) {
        final settings = service.notifier.value;
        final isApplying = service.isApplying.value;
        final isSuppressedByVpn =
            vpnService.enabled && vpnService.isDohSuppressed;
        return _DohSettingsCardInner(
          settings: settings,
          isApplying: isApplying,
          isSuppressedByVpn: isSuppressedByVpn,
          webViewEnabled: WebViewAdapterSettingsService.instance.enabled,
        );
      },
    );
  }
}

class _DohSettingsCardInner extends StatelessWidget {
  const _DohSettingsCardInner({
    required this.settings,
    required this.isApplying,
    required this.webViewEnabled,
    this.isSuppressedByVpn = false,
  });

  final NetworkSettings settings;
  final bool isApplying;
  final bool webViewEnabled;
  final bool isSuppressedByVpn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = NetworkSettingsService.instance;
    final proxyService = service.proxyService;
    final isRunning = proxyService.isRunning;
    final port = settings.proxyPort;
    final showLoading =
        isApplying ||
        service.pendingStart ||
        (settings.dohEnabled && !isRunning && !service.lastStartFailed);
    // VPN 活跃 + 自动切换开启 = 接管期，DOH 开关在此期间一律锁定
    final vpnLocked =
        VpnAutoToggleService.instance.enabled &&
        VpnAutoToggleService.instance.vpnActive;

    return SegmentedCardGroup(
      color: settings.dohEnabled
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
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
                ? Symbols.shield_rounded
                : Symbols.shield_rounded,
            color: (vpnLocked ? isSuppressedByVpn : settings.dohEnabled)
                ? theme.colorScheme.primary
                : null,
          ),
          // VPN 接管期间：开关照常可拨，但操作的是"VPN 断开后是否启用"的意图标记，
          // 不立即生效（功能仍由自动切换接管，subtitle 说明当前状态）。
          value: vpnLocked ? isSuppressedByVpn : settings.dohEnabled,
          onChanged: vpnLocked
              ? (value) => VpnAutoToggleService.instance.setDohSuppressed(value)
              : (value) async {
                  final requiresCa = WebViewMitmPolicy.requiresTrustedCa(
                    isWindows: Platform.isWindows,
                    dohEnabled: value,
                    webViewAdapterEnabled: webViewEnabled,
                  );
                  // Windows 仅 WebView 网络引擎经 DoH 时需要 MITM CA；
                  // 高性能 rhttp 保持端到端 TLS，不弹证书安装窗口。
                  if (requiresCa && !await ensureWindowsCertTrusted(context)) {
                    return;
                  }
                  await service.setDohEnabled(value);
                },
        ),

        // Windows WebView2 的代理只能在 Environment 创建时确定。
        if (Platform.isWindows &&
            WindowsWebViewEnvironmentService.instance.proxyRestartRequired)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Symbols.restart_alt_rounded,
                  size: 18,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.dohSettings_webViewRestartRequired,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 仅在开启 DOH 后显示以下内容
        if (settings.dohEnabled) ...[
          // 证书引导（iOS: 安装引导，其他平台: per-device 开关；macOS 钥匙串自动处理）
          if (!Platform.isMacOS) _CertGuide(isApplying: isApplying),

          // 状态区域（含启动失败提示）
          Column(
            children: [
              _buildStatusArea(
                context,
                theme,
                service,
                proxyService,
                isRunning,
                port,
                showLoading,
              ),
              if (!isRunning && !isApplying && service.lastStartFailed)
                _buildFailureHint(context, theme, service, proxyService),
            ],
          ),

          // 更多设置入口
          ListTile(
            leading: const Icon(Symbols.tune_rounded),
            title: Text(context.l10n.dohSettings_moreSettings),
            subtitle: Text(context.l10n.dohSettings_moreSettingsDesc),
            trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
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
                    label: service.wasRunningBeforeApply
                        ? context.l10n.dohSettings_restarting
                        : context.l10n.dohSettings_starting,
                    color: theme.colorScheme.primary,
                  )
                : _buildStatusChip(
                    theme,
                    key: ValueKey(
                      'status_${isRunning}_${service.lastStartFailed}',
                    ),
                    icon: isRunning
                        ? Symbols.check_circle_rounded
                        : service.lastStartFailed
                        ? Symbols.error_rounded
                        : Symbols.hourglass_top_rounded,
                    label: isRunning
                        ? context.l10n.dohSettings_proxyRunning
                        : context.l10n.dohSettings_proxyNotStarted,
                    color: isRunning ? Colors.green : theme.colorScheme.error,
                  ),
          ),
          const SizedBox(width: 12),
          if (port != null && isRunning)
            _buildStatusChip(
              theme,
              icon: Symbols.lan_rounded,
              label: context.l10n.dohSettings_port(port),
              color: theme.colorScheme.secondary,
            ),
          if (isRunning) ...[
            const Spacer(),
            IconButton(
              onPressed: isApplying ? null : service.restartProxy,
              icon: const Icon(Symbols.refresh_rounded, size: 20),
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
              Icon(
                Symbols.warning_amber_rounded,
                size: 16,
                color: theme.colorScheme.error,
              ),
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
                      Clipboard.setData(
                        ClipboardData(text: proxyService.lastError!),
                      );
                      ToastService.showInfo(S.current.dohSettings_errorCopied);
                    },
                    child: Icon(
                      Symbols.content_copy_rounded,
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

/// Windows: 确保网关 MITM 的 CA 已进入用户根信任库
///
/// 未安装时弹对话框引导安装(certutil 用户级,系统弹框二次确认)。
/// 返回 false 表示仍未信任,调用方应放弃开启依赖网关的功能。
Future<bool> ensureWindowsCertTrusted(BuildContext context) async {
  if (!Platform.isWindows) return true;
  final trustService = WindowsCertTrustService.instance;
  if (await trustService.isInstalled()) return true;
  if (!context.mounted) return false;

  final l10n = context.l10n;
  final shouldInstall = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.dohSettings_certDialogTitle),
      content: Text(l10n.dohSettings_certDialogDesc),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.dohSettings_certInstall),
        ),
      ],
    ),
  );
  if (shouldInstall != true) return false;

  final installed = await trustService.install();
  if (!installed && context.mounted) {
    ToastService.show(context.l10n.dohSettings_certRequired);
  }
  return installed;
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
        if (mounted) {
          setState(() {
            _installed = installed;
            _loading = false;
          });
        }
      } else if (Platform.isWindows) {
        // Windows: per-device 强制(共享内置 CA 绝不进系统信任库),
        // 仍需检测设备 CA 是否已进用户根信任库并给出安装引导
        final installed = await WindowsCertTrustService.instance.isInstalled();
        if (mounted) {
          setState(() {
            _installed = installed;
            _loading = false;
          });
        }
      } else {
        // macOS: per-device 强制启用，钥匙串自动添加，不显示引导
        if (mounted) {
          setState(() {
            _loading = false;
          });
        }
      }
    } else {
      final usePerDevice = await CertPreferenceService.usePerDevice();
      if (mounted) {
        setState(() {
          _perDeviceEnabled = usePerDevice;
          _loading = false;
        });
      }
    }
  }

  Future<void> _installWindowsCert() async {
    final ok = await WindowsCertTrustService.instance.install();
    if (!mounted) return;
    if (ok) {
      setState(() => _installed = true);
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
    if (mounted) setState(() => _perDeviceEnabled = value);

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
      return ListTile(
        leading: Icon(
          _installed ? Symbols.verified_user_rounded : Symbols.security_rounded,
          color: _installed ? Colors.green : theme.colorScheme.error,
        ),
        title: Text(
          _installed
              ? l10n.dohSettings_certInstalled
              : l10n.dohSettings_certRequired,
        ),
        subtitle: Text(
          _installed
              ? l10n.dohSettings_certReinstallHint
              : l10n.dohSettings_certInstallHint,
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
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
      );
    }

    // Windows: per-device 强制,不显示开关;网关 MITM 依赖系统信任库,
    // 未安装 CA 时 WebView2 全部握手失败,必须给出安装引导
    // (certutil 用户级安装,系统弹框确认)
    if (Platform.isWindows) {
      return ListTile(
        leading: Icon(
          _installed ? Symbols.verified_user_rounded : Symbols.security_rounded,
          color: _installed ? Colors.green : theme.colorScheme.error,
        ),
        title: Text(
          _installed
              ? l10n.dohSettings_certInstalled
              : l10n.dohSettings_certRequired,
        ),
        subtitle: Text(
          _installed
              ? l10n.dohSettings_certReinstallHint
              : l10n.dohSettings_certInstallHint,
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        trailing: _installed
            ? OutlinedButton(
                onPressed: _installWindowsCert,
                child: Text(l10n.dohSettings_certReinstall),
              )
            : FilledButton(
                onPressed: _installWindowsCert,
                child: Text(l10n.dohSettings_certInstall),
              ),
      );
    }

    // 其他平台: per-device 证书开关
    return SwitchListTile(
      secondary: Icon(
        _perDeviceEnabled
            ? Symbols.verified_user_rounded
            : Symbols.security_rounded,
        color: _perDeviceEnabled ? Colors.green : null,
      ),
      title: Text(l10n.dohSettings_perDeviceCert),
      subtitle: Text(
        _perDeviceEnabled
            ? l10n.dohSettings_perDeviceCertEnabledDesc
            : l10n.dohSettings_perDeviceCertDisabledDesc,
        style: TextStyle(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      value: _perDeviceEnabled,
      onChanged: widget.isApplying ? null : _togglePerDevice,
    );
  }
}
