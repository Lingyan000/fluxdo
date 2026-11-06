import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/adapters/core_fallback_service.dart';
import '../../../services/network/adapters/platform_adapter.dart';
import '../../../services/network/core/net_core_service.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/webview/webview_adapter_settings_service.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/network/fingerprint/fingerprint_presets.dart';
import 'fingerprint_preset_dialog.dart';
import 'doh_settings_card.dart' show ensureWindowsCertTrusted;

/// 网络状态卡片
///
/// 首块是当前生效的网络栈与出站路径（指纹、DNS、代理、WebView 是否经核心），
/// 启动失败、自动降级等异常就地给出原因与恢复入口；末块是兼容模式开关。
class EngineCard extends StatelessWidget {
  const EngineCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = NetworkSettingsService.instance;
    final webview = WebViewAdapterSettingsService.instance;
    final fallback = CoreFallbackService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        settings.notifier,
        settings.isApplying,
        NetCoreService.instance.statusNotifier,
        ProxySettingsService.instance.notifier,
        webview.notifier,
        webview.effectiveNotifier,
        fallback,
      ]),
      builder: (context, _) {
        final startFailed =
            settings.lastStartFailed && !settings.isApplying.value;
        final autoFellBack = fallback.hasFallenBack;
        return SegmentedCardGroup(
          children: [
            // 子组件读取服务状态，必须随通知重建。
            _StatusHeader(),
            _FingerprintPresetRow(),
            if (startFailed) const _StartFailedRow(),
            if (autoFellBack && !startFailed) const _FallbackRow(),
            if (webview.sessionFallbackEnabled) const _SessionCompatRow(),
            _WebViewSwitch(webview: webview),
          ],
        );
      },
    );
  }
}

class _FingerprintPresetRow extends StatelessWidget {
  _FingerprintPresetRow();

  @override
  Widget build(BuildContext context) {
    final settings = NetworkSettingsService.instance;
    final status = NetCoreService.instance.status;
    final l10n = context.l10n;
    final selected = settings.current.fingerprintPreset;
    final selectedName =
        FingerprintPreset.labelFor(selected) ?? l10n.fingerprintPreset_auto;
    final activeName =
        FingerprintPreset.labelFor(status.templatePreset) ??
        switch (status.templateSource) {
          'sampled' => l10n.fingerprintPreset_sampled,
          'cached' => l10n.fingerprintPreset_cached,
          _ => l10n.fingerprintPreset_standard,
        };
    return ListTile(
      leading: const Icon(Symbols.fingerprint_rounded),
      title: Text(l10n.fingerprintPreset_title),
      subtitle: Text(
        '$selectedName${status.running ? '\n${l10n.fingerprintPreset_active(activeName)}' : ''}',
      ),
      trailing: const Icon(Symbols.chevron_right_rounded),
      enabled: !settings.isApplying.value,
      onTap: () async {
        final result = await showAppDialog<String>(
          context: context,
          builder: (_) => FingerprintPresetDialog(selected: selected),
        );
        if (result == null) return;
        try {
          await settings.setFingerprintPreset(result);
        } catch (_) {
          ToastService.showError(l10n.fingerprintPreset_saveFailed);
        }
      },
    );
  }
}

/// 状态头：当前网络栈 + 出站路径摘要 + 重启入口。
class _StatusHeader extends StatelessWidget {
  _StatusHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = context.l10n;
    final settings = NetworkSettingsService.instance;
    final core = NetCoreService.instance;
    final applying = settings.isApplying.value || settings.pendingStart;

    final effective = resolveEffectiveAdapter();
    final engineName = getAdapterDisplayName(effective.type);
    final isFallback = effective.reason == AdapterReason.fallback;
    final webviewEnabled =
        WebViewAdapterSettingsService.instance.effectiveEnabled;

    final IconData icon;
    final Color iconColor;
    final Color iconBackground;
    final String subtitle;
    if (applying) {
      icon = Symbols.sync_rounded;
      iconColor = colors.onSecondaryContainer;
      iconBackground = colors.secondaryContainer;
      subtitle = l10n.networkStatus_applying;
    } else if (isFallback) {
      icon = Symbols.warning_rounded;
      iconColor = colors.onErrorContainer;
      iconBackground = colors.errorContainer;
      subtitle = l10n.engineStatus_reasonFallback;
    } else if (webviewEnabled) {
      // WebView 在最外层分流：主站 API 走 WebView，其余仍走网络核心
      icon = Symbols.call_split_rounded;
      iconColor = colors.onTertiaryContainer;
      iconBackground = colors.tertiaryContainer;
      subtitle = l10n.engineStatus_webviewSplit(engineName);
    } else {
      icon = Symbols.bolt_rounded;
      iconColor = colors.onPrimaryContainer;
      iconBackground = colors.primaryContainer;
      subtitle = effective.reason == AdapterReason.coreWarmingUp
          ? l10n.engineStatus_reasonCoreWarmingUp
          : l10n.engineStatus_reasonCore;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBackground,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 22, fill: 1, color: iconColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(engineName, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (!isFallback && core.isRunning) ...[
                  const SizedBox(height: 10),
                  _RouteChips(status: core.status),
                ],
              ],
            ),
          ),
          SizedBox(
            width: 48,
            height: 40,
            child: Center(
              child: applying
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    )
                  : IconButton(
                      tooltip: l10n.networkStatus_restart,
                      icon: const Icon(Symbols.refresh_rounded, size: 20),
                      onPressed: settings.restartProxy,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 出站路径摘要：DNS、代理、WebView 是否经核心，一眼看清请求怎么出去。
class _RouteChips extends StatelessWidget {
  const _RouteChips({required this.status});

  final NetCoreStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = NetworkSettingsService.instance.current;
    final appProxy = ProxySettingsService.instance.current.isValid;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        settings.dohEnabled
            ? const _RouteChip(icon: Symbols.shield_rounded, label: 'DoH')
            : _RouteChip(
                icon: Symbols.dns_rounded,
                label: l10n.networkStatus_dnsSystem,
              ),
        if (appProxy)
          _RouteChip(
            icon: Symbols.vpn_key_rounded,
            label: l10n.networkStatus_proxyApp,
          )
        else if (status.systemProxy)
          _RouteChip(
            icon: Symbols.settings_ethernet_rounded,
            label: l10n.networkStatus_proxySystem,
          )
        else
          _RouteChip(
            icon: Symbols.arrow_forward_rounded,
            label: l10n.networkStatus_direct,
          ),
        if (status.webViewMitm)
          _RouteChip(
            icon: Symbols.language_rounded,
            label: l10n.networkStatus_webViewViaCore,
          ),
      ],
    );
  }
}

class _RouteChip extends StatelessWidget {
  const _RouteChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 核心启动失败：原因 + 重试。请求此时已改走应急路径。
class _StartFailedRow extends StatelessWidget {
  const _StartFailedRow();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = NetCoreService.instance.lastError;
    return _NoticeRow(
      icon: Symbols.error_rounded,
      isError: true,
      message: l10n.networkStatus_startFailed,
      detail: error,
      actions: [
        if (error != null)
          TextButton(
            onPressed: () => _copy(error),
            child: Text(l10n.common_copy),
          ),
        TextButton(
          onPressed: NetworkSettingsService.instance.restartProxy,
          child: Text(l10n.common_retry),
        ),
      ],
    );
  }
}

/// 运行中自动降级到应急路径：查看原因、重置。
class _FallbackRow extends StatelessWidget {
  const _FallbackRow();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = CoreFallbackService.instance;
    final reason = service.fallbackReason;
    return _NoticeRow(
      icon: Symbols.info_rounded,
      isError: true,
      message: l10n.networkAdapter_autoFallbackDesc,
      actions: [
        if (reason != null)
          TextButton(
            onPressed: () => _showReason(context, reason),
            child: Text(l10n.networkAdapter_viewReason),
          ),
        TextButton(
          onPressed: () => _confirmReset(context, service),
          child: Text(l10n.networkAdapter_resetFallback),
        ),
      ],
    );
  }

  Future<void> _showReason(BuildContext context, String reason) async {
    await showAppDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.networkAdapter_degradeReason),
        content: SingleChildScrollView(
          child: SelectableText(
            reason,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.l10n.common_close),
          ),
          FilledButton(
            onPressed: () => _copy(reason),
            child: Text(dialogContext.l10n.common_copy),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(
    BuildContext context,
    CoreFallbackService service,
  ) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.networkAdapter_resetFallback),
        content: Text(dialogContext.l10n.networkAdapter_resetFallbackDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.common_reset),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await service.reset();
      ToastService.showSuccess(S.current.networkAdapter_resetSuccess);
    }
  }
}

/// CF 恢复期间临时开启的兼容模式（本次会话有效）。
class _SessionCompatRow extends StatelessWidget {
  const _SessionCompatRow();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _NoticeRow(
      icon: Symbols.call_split_rounded,
      message: l10n.cf_sessionCompatEnabled,
      actions: [
        TextButton(
          onPressed:
              WebViewAdapterSettingsService.instance.disableSessionFallback,
          child: Text(l10n.cf_sessionCompatDisable),
        ),
      ],
    );
  }
}

/// 卡片内的提示行：图标 + 说明（可带详情）+ 操作按钮。
class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.icon,
    required this.message,
    this.detail,
    this.isError = false,
    this.actions = const [],
  });

  final IconData icon;
  final String message;
  final String? detail;
  final bool isError;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = isError ? colors.error : colors.tertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: accent,
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          detail!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (actions.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: 4, children: actions),
            ),
        ],
      ),
    );
  }
}

/// 兼容模式开关：主站 API 改由 WebView 代发。
class _WebViewSwitch extends StatelessWidget {
  const _WebViewSwitch({required this.webview});

  final WebViewAdapterSettingsService webview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = webview.enabled;
    return SwitchListTile(
      secondary: Icon(
        Symbols.language_rounded,
        fill: enabled ? 1 : 0,
        color: enabled ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(l10n.webviewAdapter_title),
      subtitle: Text(
        enabled
            ? l10n.webviewAdapter_enabledDesc
            : l10n.webviewAdapter_disabledDesc,
      ),
      value: enabled,
      onChanged: (value) async {
        // Windows 下 DoH 开着时 WebView 经核心 MITM，需要先装好受信任 CA
        if (value &&
            Platform.isWindows &&
            NetworkSettingsService.instance.current.dohEnabled &&
            !await ensureWindowsCertTrusted(context)) {
          return;
        }
        await webview.setEnabled(value);
      },
    );
  }
}

void _copy(String text) {
  Clipboard.setData(ClipboardData(text: text));
  ToastService.showSuccess(S.current.common_copiedToClipboard);
}
