import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../utils/dialog_utils.dart';
import '../../../widgets/post/pm_recipient_field.dart';

/// 邀请结果:选中的用户名与群组名分开回传。
///
/// 官方 invite 分两个端点(用户 `POST /t/:id/invite`、群组
/// `POST /t/:id/invite-group`),所以名单必须在这里就分好类,不能像新建
/// 私信的 `target_recipients` 那样混成一串。
class InvitePrivateMessageResult {
  const InvitePrivateMessageResult({
    required this.usernames,
    required this.groupNames,
  });

  final List<String> usernames;
  final List<String> groupNames;

  bool get isEmpty => usernames.isEmpty && groupNames.isEmpty;
}

/// 弹出私信邀请弹窗;取消或未选任何收件人返回 null。
Future<InvitePrivateMessageResult?> showInvitePrivateMessageDialog({
  required BuildContext context,
}) {
  return showAppDialog<InvitePrivateMessageResult>(
    context: context,
    builder: (dialogContext) => const _InvitePrivateMessageDialog(),
  );
}

class _InvitePrivateMessageDialog extends StatefulWidget {
  const _InvitePrivateMessageDialog();

  @override
  State<_InvitePrivateMessageDialog> createState() =>
      _InvitePrivateMessageDialogState();
}

class _InvitePrivateMessageDialogState
    extends State<_InvitePrivateMessageDialog> {
  List<String> _recipients = const [];
  Set<String> _groupNames = const {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.pm_inviteParticipants),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.pm_inviteParticipantsHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            PmRecipientField(
              recipients: _recipients,
              groupNames: _groupNames,
              autofocus: true,
              onChanged: (value) => setState(() => _recipients = value),
              onGroupNamesChanged: (value) =>
                  setState(() => _groupNames = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          key: const ValueKey('pm-invite-confirm'),
          onPressed: _recipients.isEmpty ? null : _submit,
          child: Text(context.l10n.common_confirm),
        ),
      ],
    );
  }

  void _submit() {
    // 群组名从已选名单里剔掉,剩下的即用户名(候选只能从搜索结果里挑,
    // 所以每一项的类别都是确定的)。
    Navigator.pop(
      context,
      InvitePrivateMessageResult(
        usernames: _recipients
            .where((name) => !_groupNames.contains(name))
            .toList(growable: false),
        groupNames: _recipients
            .where((name) => _groupNames.contains(name))
            .toList(growable: false),
      ),
    );
  }
}
