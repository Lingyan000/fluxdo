import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/network/fingerprint/fingerprint_presets.dart';

/// 自动档独立展示，手动档按平台浏览；选择仍直接返回稳定 ID。
class FingerprintPresetDialog extends StatefulWidget {
  const FingerprintPresetDialog({super.key, required this.selected});
  final String selected;

  @override
  State<FingerprintPresetDialog> createState() =>
      _FingerprintPresetDialogState();
}

class _FingerprintPresetDialogState extends State<FingerprintPresetDialog> {
  static const _platforms = {
    'android': 'Android',
    'ios': 'iOS',
    'macos': 'macOS',
    'windows': 'Windows',
  };
  late String _platform;

  @override
  void initState() {
    super.initState();
    final selectedPlatform = widget.selected.split('-').first;
    _platform = _platforms.containsKey(selectedPlatform)
        ? selectedPlatform
        : switch (defaultTargetPlatform) {
            TargetPlatform.iOS => 'ios',
            TargetPlatform.macOS => 'macos',
            TargetPlatform.windows => 'windows',
            _ => 'android',
          };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Translations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.networkStatus_template,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.common_close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Symbols.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _option(
                      FingerprintPreset.automatic,
                      l10n.fingerprintPreset_auto,
                      subtitle: l10n.fingerprintPreset_autoDescription,
                      automatic: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
                      child: Text(
                        l10n.fingerprintPreset_manual,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final platform in _platforms.entries)
                            ChoiceChip(
                              label: Text(platform.value),
                              selected: _platform == platform.key,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setState(() => _platform = platform.key),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final preset in FingerprintPreset.values.where(
                      (preset) => preset.id.startsWith('$_platform-'),
                    ))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _option(preset.id, preset.label),
                      ),
                    const SizedBox(height: 8),
                    ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                      childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      shape: const Border(),
                      collapsedShape: const Border(),
                      title: Text(
                        l10n.fingerprintPreset_scopeTitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      children: [
                        Text(
                          l10n.fingerprintPreset_scope,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(
    String id,
    String title, {
    String? subtitle,
    bool automatic = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.selected == id;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected
            ? colors.secondaryContainer
            : automatic
            ? colors.surfaceContainerHighest
            : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          selected: selected,
          selectedColor: colors.onSecondaryContainer,
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          onTap: () => Navigator.of(context).pop(id),
        ),
      ),
    );
  }
}
