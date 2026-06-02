import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/s.dart';
import '../services/network/adapters/cronet_fallback_service.dart';
import '../utils/dialog_utils.dart';
import '../services/network/adapters/platform_adapter.dart';
import '../services/toast_service.dart';

class NetworkAdapterSettingsPage extends StatefulWidget {
  const NetworkAdapterSettingsPage({super.key});

  @override
  State<NetworkAdapterSettingsPage> createState() =>
      _NetworkAdapterSettingsPageState();
}

class _NetworkAdapterSettingsPageState
    extends State<NetworkAdapterSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: CronetFallbackService.instance,
      builder: (context, _) {
        final fallbackService = CronetFallbackService.instance;
        final adapterType = getCurrentAdapterType();
        final hasFallenBack = fallbackService.hasFallenBack;
        final forceFallback = fallbackService.forceFallback;
        final failureReason = fallbackService.fallbackReason;

        return Scaffold(
          appBar: AppBar(title: Text(context.l10n.networkAdapter_title)),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // 当前适配器状态卡片
              _buildCurrentAdapterCard(theme, adapterType),
              const SizedBox(height: 16),

              // 控制选项卡片
              if (Platform.isAndroid) ...[
                _buildControlCard(theme, forceFallback, fallbackService),
                const SizedBox(height: 16),
              ],

              // 降级状态卡片
              if (Platform.isAndroid && hasFallenBack && !forceFallback) ...[
                _buildFallbackStatusCard(theme, failureReason, fallbackService),
                const SizedBox(height: 16),
              ],

              // 开发者测试工具（仅 DEBUG 模式）
              if (kDebugMode && Platform.isAndroid && !hasFallenBack) ...[
                _buildTestCard(theme, fallbackService),
                const SizedBox(height: 16),
              ],

              // 说明
              _buildHint(theme),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCurrentAdapterCard(ThemeData theme, AdapterType? adapterType) {
    final fallbackService = CronetFallbackService.instance;
    final hasFallenBack = fallbackService.hasFallenBack;

    // 如果已降级，显示备用适配器状态
    final displayType = hasFallenBack ? AdapterType.network : adapterType;
    final isNative = displayType == AdapterType.native;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  context.l10n.networkAdapter_currentStatus,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: Text(context.l10n.networkAdapter_adapterType),
            subtitle: Text(
              displayType != null
                  ? getAdapterDisplayName(displayType)
                  : context.l10n.common_unknown,
            ),
            trailing: _buildStatusChip(
              theme,
              icon: isNative ? Icons.check_circle : Icons.info,
              label: isNative
                  ? context.l10n.networkAdapter_native
                  : context.l10n.networkAdapter_fallback,
              color: isNative ? Colors.green : theme.colorScheme.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlCard(
    ThemeData theme,
    bool forceFallback,
    CronetFallbackService fallbackService,
  ) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.tune, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  context.l10n.networkAdapter_controlOptions,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.swap_horiz),
            title: Text(context.l10n.networkAdapter_forceFallback),
            subtitle: Text(context.l10n.networkAdapter_forceFallbackDesc),
            value: forceFallback,
            onChanged: (value) async {
              await fallbackService.setForceFallback(value);
              if (mounted) {
                ToastService.showSuccess(S.current.networkAdapter_settingSaved);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackStatusCard(
    ThemeData theme,
    String? failureReason,
    CronetFallbackService fallbackService,
  ) {
    return Card(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: theme.colorScheme.error),
                const SizedBox(width: 12),
                Text(
                  context.l10n.networkAdapter_fallbackStatus,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.error.withValues(alpha: 0.2),
          ),
          ListTile(
            leading: Icon(Icons.info_outline, color: theme.colorScheme.error),
            title: Text(context.l10n.networkAdapter_autoFallback),
            subtitle: Text(context.l10n.networkAdapter_autoFallbackDesc),
          ),
          if (failureReason != null) ...[
            Divider(
              height: 1,
              indent: 56,
              color: theme.colorScheme.error.withValues(alpha: 0.2),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report),
              title: Text(context.l10n.networkAdapter_viewReason),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => _showFailureReasonDialog(failureReason),
            ),
          ],
          Divider(
            height: 1,
            indent: 56,
            color: theme.colorScheme.error.withValues(alpha: 0.2),
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(context.l10n.networkAdapter_resetFallback),
            subtitle: Text(context.l10n.networkAdapter_resetFallbackDesc),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _resetFallbackState(fallbackService),
          ),
        ],
      ),
    );
  }

  Widget _buildTestCard(
    ThemeData theme,
    CronetFallbackService fallbackService,
  ) {
    return Card(
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.science, color: theme.colorScheme.tertiary),
                const SizedBox(width: 12),
                Text(
                  context.l10n.networkAdapter_devTest,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.tertiary.withValues(alpha: 0.2),
          ),
          ListTile(
            leading: Icon(Icons.bug_report, color: theme.colorScheme.tertiary),
            title: Text(context.l10n.networkAdapter_simulateError),
            subtitle: Text(context.l10n.networkAdapter_simulateErrorDesc),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _simulateCronetError(fallbackService),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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

  Widget _buildHint(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              Platform.isAndroid
                  ? 'Cronet 适配器性能更好，但在某些设备上可能不兼容。如遇问题，系统会自动降级到备用适配器。'
                  : 'iOS/macOS 使用 Cupertino 适配器，性能优异且稳定。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showFailureReasonDialog(String reason) async {
    await showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.networkAdapter_degradeReason),
        content: SingleChildScrollView(
          child: SelectableText(
            reason,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_close),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: reason));
              ToastService.showSuccess(S.current.common_copiedToClipboard);
            },
            child: Text(context.l10n.common_copy),
          ),
        ],
      ),
    );
  }

  Future<void> _resetFallbackState(
    CronetFallbackService fallbackService,
  ) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.networkAdapter_resetFallback),
        content: Text(context.l10n.networkAdapter_resetFallbackDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.common_reset),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await fallbackService.reset();
      if (mounted) {
        ToastService.showSuccess(S.current.networkAdapter_resetSuccess);
      }
    }
  }

  Future<void> _simulateCronetError(
    CronetFallbackService fallbackService,
  ) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.networkAdapter_simulateError),
        content: const Text(
          '这将模拟一个 Cronet 错误并触发降级流程。\n\n'
          '降级后，应用将使用 NetworkHttpAdapter 作为备用适配器。\n\n'
          '确定要继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.tertiary,
            ),
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await fallbackService.simulateCronetError();
      if (mounted) {
        ToastService.showInfo(S.current.networkAdapter_simulateSuccess);
      }
    }
  }
}
