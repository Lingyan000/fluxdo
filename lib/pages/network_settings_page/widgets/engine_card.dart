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
import 'doh_settings_card.dart';
import 'http_proxy_card.dart';
import 'network_connection_overview.dart';

/// 网络状态卡片
///
/// 首块是当前生效的网络栈与出站路径（指纹、DNS、代理、WebView 是否经核心），
/// 启动失败、自动降级等异常就地给出原因与恢复入口，配置集中在图中节点。
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ConnectionOverview(
              status: NetCoreService.instance.status,
              applying: settings.isApplying.value || settings.pendingStart,
            ),
            if (startFailed ||
                autoFellBack ||
                webview.sessionFallbackEnabled) ...[
              const SizedBox(height: 3),
              SegmentedCardGroup(
                children: [
                  if (startFailed) const _StartFailedRow(),
                  if (autoFellBack && !startFailed) const _FallbackRow(),
                  if (webview.sessionFallbackEnabled) const _SessionCompatRow(),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 每次服务通知都传入完整快照，避免状态卡保留旧的生效信息。
class _ConnectionOverview extends StatelessWidget {
  const _ConnectionOverview({required this.status, required this.applying});

  final NetCoreStatus status;
  final bool applying;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = NetworkSettingsService.instance;
    final settings = service.current;
    final effective = resolveEffectiveAdapter();
    final fallback = effective.reason == AdapterReason.fallback;
    final webview = WebViewAdapterSettingsService.instance;
    final useDoh =
        (!fallback || (webview.effectiveEnabled && status.webViewMitm)) &&
        settings.dohEnabled;
    final server = service.servers
        .where((server) => server.url == settings.selectedServerUrl)
        .firstOrNull;
    final dns = useDoh
        ? '${server?.name ?? Uri.tryParse(settings.selectedServerUrl)?.host ?? "DoH"} · DoH'
        : l10n.networkStatus_dnsSystem;
    // 应急适配器不使用应用代理；其出口由系统决定，不能沿用核心的标签。
    final coreOutbound = ProxySettingsService.instance.current.isValid
        ? l10n.networkStatus_proxyApp
        : status.systemProxy
        ? l10n.networkStatus_systemRules
        : l10n.networkStatus_direct;

    return NetworkConnectionOverview(
      phase: applying
          ? ConnectionPhase.applying
          : fallback
          ? ConnectionPhase.fallback
          : effective.reason == AdapterReason.coreWarmingUp
          ? ConnectionPhase.warming
          : ConnectionPhase.running,
      engine: getAdapterDisplayName(effective.type),
      dns: dns,
      outbound: fallback ? l10n.networkStatus_systemNetwork : coreOutbound,
      webViewOutbound: coreOutbound,
      compatibility: webview.effectiveEnabled,
      webViewViaCore: status.running && status.webViewMitm,
      onRestart: service.restartProxy,
      templateName:
          FingerprintPreset.labelFor(settings.fingerprintPreset) ??
          l10n.fingerprintPreset_auto,
      templateDetail: status.running
          ? l10n.fingerprintPreset_active(
              FingerprintPreset.labelFor(status.templatePreset) ??
                  switch (status.templateSource) {
                    'sampled' => l10n.fingerprintPreset_sampled,
                    'cached' => l10n.fingerprintPreset_cached,
                    _ => l10n.fingerprintPreset_standard,
                  },
            )
          : l10n.networkStatus_fallbackScope,
      onTemplate: () async {
        final result = await showAppDialog<String>(
          context: context,
          builder: (_) =>
              FingerprintPresetDialog(selected: settings.fingerprintPreset),
        );
        if (result == null) return;
        try {
          await service.setFingerprintPreset(result);
        } catch (_) {
          ToastService.showError(l10n.fingerprintPreset_saveFailed);
        }
      },
      onDns: () =>
          _showNodeSettings(context, 'DNS / ECH', const DohSettingsCard()),
      onProxy: () => _showNodeSettings(
        context,
        l10n.networkMap_outbound,
        const HttpProxyCard(),
      ),
      onCompatibility: () => _showNodeSettings(
        context,
        l10n.webviewAdapter_title,
        AnimatedBuilder(
          animation: Listenable.merge([
            webview.notifier,
            webview.effectiveNotifier,
          ]),
          builder: (context, _) => _WebViewSwitch(webview: webview),
        ),
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
      actions: [
        if (error != null)
          TextButton(
            onPressed: () => showAppDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Text(l10n.networkStatus_startFailed),
                content: SingleChildScrollView(child: SelectableText(error)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(l10n.common_close),
                  ),
                  TextButton(
                    onPressed: () => _copy(error),
                    child: Text(l10n.common_copy),
                  ),
                ],
              ),
            ),
            child: Text(l10n.common_details),
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
    this.isError = false,
    this.actions = const [],
  });

  final IconData icon;
  final String message;
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

/// 配置复用原有控件与保存流程；小屏底部面板，大屏居中面板。
Future<void> _showNodeSettings(
  BuildContext context,
  String title,
  Widget child,
) async {
  Widget content(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: context.l10n.common_close,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Symbols.close_rounded),
              ),
            ],
          ),
          Flexible(child: SingleChildScrollView(child: child)),
        ],
      ),
    ),
  );
  if (MediaQuery.sizeOf(context).width < 600) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      builder: content,
    );
  } else {
    await showAppDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 500,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: content(context),
        ),
      ),
    );
  }
}
