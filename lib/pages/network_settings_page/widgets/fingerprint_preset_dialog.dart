import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../services/network/fingerprint/fingerprint_presets.dart';

/// 高度由对话框约束，选项可滚动；整行是选择目标，支持大字体和窄屏。
class FingerprintPresetDialog extends StatelessWidget {
  const FingerprintPresetDialog({super.key, required this.selected});
  final String selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget option(String id, String title, {String? subtitle}) => ListTile(
      selected: selected == id,
      leading: Icon(
        selected == id
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked,
      ),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => Navigator.of(context).pop(id),
    );
    return SimpleDialog(
      title: Text(l10n.fingerprintPreset_title),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(l10n.fingerprintPreset_scope),
        ),
        option(
          FingerprintPreset.automatic,
          l10n.fingerprintPreset_auto,
          subtitle: l10n.fingerprintPreset_autoDescription,
        ),
        for (final preset in FingerprintPreset.values)
          option(preset.id, preset.label),
      ],
    );
  }
}
