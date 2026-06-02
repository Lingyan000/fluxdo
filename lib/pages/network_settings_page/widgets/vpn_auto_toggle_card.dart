import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';

/// VPN 自动切换设置卡片
class VpnAutoToggleCard extends StatelessWidget {
  const VpnAutoToggleCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = VpnAutoToggleService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        service.enabledNotifier,
        service.vpnActiveNotifier,
      ]),
      builder: (context, _) {
        final enabled = service.enabled;
        final vpnActive = service.vpnActive;
        final dohSuppressed = enabled && service.isDohSuppressed;
        final proxySuppressed = enabled && service.isProxySuppressed;
        final hasSuppressed = dohSuppressed || proxySuppressed;

        return Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              SwitchListTile(
                title: Text(context.l10n.vpnToggle_title),
                subtitle: Text(context.l10n.vpnToggle_subtitle),
                secondary: Icon(
                  enabled ? Icons.swap_horiz : Icons.swap_horiz_outlined,
                  color: enabled ? theme.colorScheme.primary : null,
                ),
                value: enabled,
                onChanged: (value) => service.setEnabled(value),
              ),
              if (enabled) ...[
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        vpnActive ? Icons.vpn_lock : Icons.vpn_lock_outlined,
                        size: 16,
                        color: vpnActive
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        vpnActive ? context.l10n.vpnToggle_connected : context.l10n.vpnToggle_disconnected,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: vpnActive
                              ? theme.colorScheme.tertiary
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: vpnActive ? FontWeight.w500 : null,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasSuppressed) ...[
                  Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _buildSuppressedText(dohSuppressed, proxySuppressed),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  String _buildSuppressedText(bool dohSuppressed, bool proxySuppressed) {
    final items = <String>[];
    if (dohSuppressed) items.add('DOH');
    if (proxySuppressed) items.add(S.current.vpnToggle_upstreamProxy);
    return '${items.join(S.current.vpnToggle_and)}${S.current.vpnToggle_suppressedSuffix}';
  }
}
