import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

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
        service.detectionModeNotifier,
      ]),
      builder: (context, _) {
        final enabled = service.enabled;
        final vpnActive = service.vpnActive;
        final dohSuppressed = enabled && service.isDohSuppressed;
        final proxySuppressed = enabled && service.isProxySuppressed;
        final hasSuppressed = dohSuppressed || proxySuppressed;

        return SegmentedCardGroup(
          children: [
            SwitchListTile(
              title: Text(context.l10n.vpnToggle_title),
              subtitle: Text(context.l10n.vpnToggle_subtitle),
              secondary: Icon(
                Symbols.swap_horiz_rounded,
                fill: enabled ? 1 : 0,
                color: enabled ? theme.colorScheme.primary : null,
              ),
              value: enabled,
              onChanged: (value) => service.setEnabled(value),
            ),
            if (enabled)
              ListTile(
                leading: const Icon(Symbols.rule_rounded),
                title: Text(context.l10n.vpnToggle_detectionMode),
                subtitle: Text(_detectionDescription(context, service)),
                trailing: SwipeDismissiblePopupMenuButton<VpnDetectionMode>(
                  tooltip: context.l10n.vpnToggle_detectionMode,
                  offset: const Offset(0, 36),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: service.setDetectionMode,
                  itemBuilder: (context) => [
                    for (final mode in VpnDetectionMode.values)
                      PopupMenuItem(
                        value: mode,
                        child: Row(
                          children: [
                            if (mode == service.detectionMode)
                              Icon(
                                Symbols.check_rounded,
                                size: 18,
                                color: theme.colorScheme.primary,
                              )
                            else
                              const SizedBox(width: 18),
                            const SizedBox(width: 8),
                            Text(_detectionLabel(context, mode)),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_detectionLabel(context, service.detectionMode)),
                        const SizedBox(width: 4),
                        const Icon(Symbols.arrow_drop_down_rounded, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            if (enabled)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Symbols.vpn_lock_rounded,
                      fill: vpnActive ? 1 : 0,
                      size: 16,
                      color: vpnActive
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      vpnActive
                          ? context.l10n.vpnToggle_connected
                          : context.l10n.vpnToggle_disconnected,
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
            if (enabled && hasSuppressed)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Symbols.info_rounded,
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
        );
      },
    );
  }

  String _detectionLabel(BuildContext context, VpnDetectionMode mode) {
    return switch (mode) {
      VpnDetectionMode.automatic => context.l10n.vpnToggle_detectionAutomatic,
      VpnDetectionMode.forceActive =>
        context.l10n.vpnToggle_detectionForceActive,
      VpnDetectionMode.forceInactive =>
        context.l10n.vpnToggle_detectionForceInactive,
    };
  }

  String _detectionDescription(
    BuildContext context,
    VpnAutoToggleService service,
  ) {
    return switch (service.detectionMode) {
      VpnDetectionMode.automatic =>
        context.l10n.vpnToggle_detectionAutomaticDesc,
      VpnDetectionMode.forceActive =>
        context.l10n.vpnToggle_detectionForceActiveDesc,
      VpnDetectionMode.forceInactive =>
        context.l10n.vpnToggle_detectionForceInactiveDesc,
    };
  }

  String _buildSuppressedText(bool dohSuppressed, bool proxySuppressed) {
    final items = <String>[];
    if (dohSuppressed) items.add('DOH');
    if (proxySuppressed) items.add(S.current.vpnToggle_upstreamProxy);
    return '${items.join(S.current.vpnToggle_and)}${S.current.vpnToggle_suppressedSuffix}';
  }
}
