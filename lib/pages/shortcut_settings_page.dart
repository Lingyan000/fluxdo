import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart' show showInteractionDialog;
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../providers/shortcut_provider.dart';
import '../settings/definitions/shortcut_defs.dart';
import '../widgets/settings/settings_group_page.dart';

class ShortcutSettingsPage extends ConsumerWidget {
  final String? highlightId;

  const ShortcutSettingsPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    return SettingsGroupPage(
      title: l10n.settings_shortcuts,
      groupsBuilder: buildShortcutGroups,
      highlightId: highlightId,
      maxContentWidth: 860,
      actions: [
        IconButton(
          icon: const Icon(Symbols.restore_rounded),
          tooltip: l10n.shortcuts_resetAll,
          onPressed: () async {
            final confirmed = await showInteractionDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(l10n.shortcuts_resetAll),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l10n.common_cancel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l10n.common_confirm),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await ref.read(shortcutProvider.notifier).resetAll();
            }
          },
        ),
      ],
    );
  }
}
