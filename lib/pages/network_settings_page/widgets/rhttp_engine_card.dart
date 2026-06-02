import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../services/network/adapters/cronet_fallback_service.dart';
import '../../../services/network/adapters/platform_adapter.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/rhttp/rhttp_settings_service.dart';

/// rhttp 引擎设置卡片
class RhttpEngineCard extends StatelessWidget {
  const RhttpEngineCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rhttpService = RhttpSettingsService.instance;
    final networkService = NetworkSettingsService.instance;
    final proxyService = ProxySettingsService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        rhttpService.notifier,
        networkService.notifier,
        proxyService.notifier,
        CronetFallbackService.instance,
      ]),
      builder: (context, _) {
        final settings = rhttpService.current;
        final enabled = settings.enabled;
        final ns = networkService.current;
        final ps = proxyService.current;

        // 从当前设置直接推算适配器类型（不依赖全局变量，避免滞后）
        final wouldUseRhttp = rhttpService.shouldUseRhttp(ns, ps);
        final echFallback = enabled && ns.dohEnabled && ns.echServerUrl != null;

        // 推算当前实际适配器类型（对齐 _resolveAdapterType() 完整链路）
        final AdapterType effectiveType;
        if (wouldUseRhttp) {
          effectiveType = AdapterType.rhttp;
        } else if (networkService.isGatewayMode &&
            !CronetFallbackService.instance.hasFallenBack) {
          effectiveType = AdapterType.native;
        } else if (networkService.shouldRunLocalProxy ||
            CronetFallbackService.instance.hasFallenBack) {
          effectiveType = AdapterType.network;
        } else {
          effectiveType = AdapterType.native;
        }

        return Card(
          clipBehavior: Clip.antiAlias,
          color: enabled
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: enabled
                ? BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  )
                : BorderSide.none,
          ),
          child: Column(
            children: [
              SwitchListTile(
                title: Text(context.l10n.rhttpEngine_title),
                subtitle: Text(
                  enabled
                      ? context.l10n.rhttpEngine_enabledDesc
                      : context.l10n.rhttpEngine_disabledDesc,
                ),
                secondary: Icon(
                  enabled ? Icons.rocket_launch : Icons.rocket_launch_outlined,
                  color: enabled ? theme.colorScheme.primary : null,
                ),
                value: enabled,
                onChanged: (value) => rhttpService.setEnabled(value),
              ),

              if (enabled) ...[
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.2,
                  ),
                ),

                // 模式选择
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.rhttpEngine_useMode,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<RhttpMode>(
                          segments: [
                            ButtonSegment(
                              value: RhttpMode.always,
                              label: Text(context.l10n.rhttpEngine_alwaysUse),
                            ),
                            ButtonSegment(
                              value: RhttpMode.proxyOnly,
                              label: Text(
                                context.l10n.rhttpEngine_proxyDohOnly,
                              ),
                            ),
                          ],
                          selected: {settings.mode},
                          onSelectionChanged: (modes) {
                            rhttpService.setMode(modes.first);
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                // 当前适配器状态
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.2,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        wouldUseRhttp ? Icons.check_circle : Icons.info_outline,
                        size: 16,
                        color: wouldUseRhttp
                            ? Colors.green
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        context.l10n.rhttpEngine_currentAdapter(
                          getAdapterDisplayName(effectiveType),
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),

                // ECH 回退提示
                if (echFallback)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 14,
                          color: theme.colorScheme.tertiary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.l10n.rhttpEngine_echFallbackHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.tertiary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // rhttp 初始化失败警告
                if (settings.forceDisabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          size: 14,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.l10n.rhttpEngine_initFailedHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
