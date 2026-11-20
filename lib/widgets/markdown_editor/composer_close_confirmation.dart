import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';

/// 关闭时由用户决定是否放弃尚未保存的修改。
Future<bool> confirmComposerDiscard(
  BuildContext context, {
  required bool synchronizationFailed,
}) async {
  final discard = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dialogContext.l10n.composer_discardChangesTitle),
      content: Text(
        synchronizationFailed
            ? dialogContext.l10n.composer_closeSyncFailed
            : dialogContext.l10n.composer_discardChangesBody,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(dialogContext.l10n.createTopic_continueEditing),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(dialogContext.l10n.composer_discardAndClose),
        ),
      ],
    ),
  );
  return discard == true;
}
