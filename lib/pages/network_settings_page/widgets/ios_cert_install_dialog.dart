import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh_proxy/per_device_cert_service.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../widgets/common/app_bottom_sheet.dart';

/// 打开 iOS CA 证书安装引导对话框
///
/// 可从任何地方调用：
/// ```dart
/// if (Platform.isIOS) {
///   showIosCertInstallDialog(context);
/// }
/// ```
Future<bool?> showIosCertInstallDialog(BuildContext context) {
  return showAppBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _IosCertInstallSheet(),
  );
}

class _IosCertInstallSheet extends StatefulWidget {
  const _IosCertInstallSheet();

  @override
  State<_IosCertInstallSheet> createState() => _IosCertInstallSheetState();
}

class _IosCertInstallSheetState extends State<_IosCertInstallSheet> {
  int _currentStep = 0;
  bool _installing = false;
  bool _regenerating = false;

  static const _browserChannel = MethodChannel(
    'com.github.lingyan000.fluxdo/browser',
  );

  Future<void> _downloadProfile() async {
    setState(() => _installing = true);
    try {
      final ok = await PerDeviceCertService.instance.installProfile();
      if (mounted) {
        if (ok) {
          setState(() => _currentStep = 1);
        } else {
          ToastService.showError(S.current.dohSettings_certDownloadFailed);
        }
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _regenerateAndDownload() async {
    setState(() => _regenerating = true);
    try {
      final certService = PerDeviceCertService.instance;
      await certService.clearCertInstalled();
      await certService.reset();
      final ok = await certService.installProfile();
      if (mounted) {
        if (ok) {
          setState(() => _currentStep = 1);
          ToastService.showInfo(S.current.dohSettings_certRegenerated);
        } else {
          ToastService.showError(S.current.dohSettings_certRegenerateFailed);
        }
      }
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  Future<void> _openSettings() async {
    try {
      await _browserChannel.invokeMethod('launchAppLink', {
        'url': 'App-prefs:',
      });
    } catch (_) {}
  }

  void _finish() {
    PerDeviceCertService.instance.markCertInstalled();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return AppSheetScaffold(
      contentPadding: EdgeInsets.zero,
      titleWidget: Row(
        children: [
          Icon(Symbols.security_rounded, color: context.emphasis.accent),
          const SizedBox(width: 8),
          Text(
            l10n.dohSettings_certDialogTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              l10n.dohSettings_certDialogDesc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 步骤指示器
          _buildStepIndicator(theme, l10n),
          const SizedBox(height: 20),

          // 步骤内容
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _buildStepContent(theme, l10n),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(ThemeData theme, AppLocalizations l10n) {
    final steps = [
      l10n.dohSettings_certStepDownload,
      l10n.dohSettings_certStepInstall,
      l10n.dohSettings_certStepTrust,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: List.generate(steps.length * 2 - 1, (index) {
          if (index.isOdd) {
            // 连接线
            final stepBefore = index ~/ 2;
            return Expanded(
              child: Container(
                height: 2,
                color: stepBefore < _currentStep
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
            );
          }

          final step = index ~/ 2;
          final isActive = step == _currentStep;
          final isDone = step < _currentStep;

          return GestureDetector(
            onTap: () => setState(() => _currentStep = step),
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone
                        ? theme.colorScheme.primary
                        : isActive
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    border: isActive && !isDone
                        ? Border.all(color: theme.colorScheme.primary, width: 2)
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: isDone
                      ? Icon(
                          Symbols.check_rounded,
                          size: 16,
                          color: theme.colorScheme.onPrimary,
                        )
                      : Text(
                          '${step + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: isActive
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(height: 4),
                Text(
                  steps[step],
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isActive || isDone
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: isActive ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildStepContent(ThemeData theme, AppLocalizations l10n) {
    switch (_currentStep) {
      case 0:
        return _buildStep0(theme, l10n);
      case 1:
        return _buildStep1(theme, l10n);
      case 2:
        return _buildStep2(theme, l10n);
      default:
        return const SizedBox.shrink();
    }
  }

  /// 步骤 1：下载描述文件
  Widget _buildStep0(ThemeData theme, AppLocalizations l10n) {
    return Column(
      key: const ValueKey(0),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoCard(
          theme,
          icon: Symbols.info_rounded,
          text: l10n.dohSettings_certDownloadHint,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _installing || _regenerating ? null : _downloadProfile,
            icon: _installing
                ? const _MiniSpinner()
                : const Icon(Symbols.download_rounded, size: 18),
            label: Text(
              _installing
                  ? l10n.dohSettings_certPreparing
                  : l10n.dohSettings_certDownloadProfile,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: _installing || _regenerating
                ? null
                : _regenerateAndDownload,
            icon: _regenerating
                ? const _MiniSpinner()
                : const Icon(Symbols.refresh_rounded, size: 16),
            label: Text(
              l10n.dohSettings_certRegenerate,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 步骤 2：安装描述文件
  Widget _buildStep1(ThemeData theme, AppLocalizations l10n) {
    return Column(
      key: const ValueKey(1),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoCard(
          theme,
          icon: Symbols.smartphone_rounded,
          text: l10n.dohSettings_certInstallProfileHint,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _openSettings,
            icon: const Icon(Symbols.settings_rounded, size: 18),
            label: Text(l10n.dohSettings_certOpenSettings),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => setState(() => _currentStep = 2),
            child: Text(l10n.dohSettings_certInstalledNext),
          ),
        ),
      ],
    );
  }

  /// 步骤 3：信任证书
  Widget _buildStep2(ThemeData theme, AppLocalizations l10n) {
    return Column(
      key: const ValueKey(2),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoCard(
          theme,
          icon: Symbols.verified_user_rounded,
          text: l10n.dohSettings_certTrustHint,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _openSettings,
            icon: const Icon(Symbols.settings_rounded, size: 18),
            label: Text(l10n.dohSettings_certOpenSettings),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: _finish,
            child: Text(l10n.dohSettings_certAllDone),
          ),
        ),
      ],
    );
  }

  Widget _infoCard(
    ThemeData theme, {
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.emphasis.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
