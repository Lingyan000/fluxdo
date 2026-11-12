import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/user_group.dart';
import '../../providers/core_providers.dart';
import '../../utils/error_utils.dart';

class GroupMembershipRequestDialog extends ConsumerStatefulWidget {
  const GroupMembershipRequestDialog({super.key, required this.group});

  final UserGroupDetail group;

  @override
  ConsumerState<GroupMembershipRequestDialog> createState() =>
      _GroupMembershipRequestDialogState();
}

class _GroupMembershipRequestDialogState
    extends ConsumerState<GroupMembershipRequestDialog> {
  late final _controller = TextEditingController(
    text: widget.group.requestTemplate,
  );
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_sending &&
      _controller.text.trim().isNotEmpty &&
      _controller.text.length <= 5000;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final url = await ref
          .read(discourseServiceProvider)
          .requestGroupMembership(
            widget.group.group.name,
            _controller.text.trim(),
          );
      if (mounted) Navigator.of(context).pop((url: url));
    } catch (error) {
      if (mounted) {
        setState(() => _error = ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: AlertDialog(
      title: Text(context.l10n.group_request),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.group.displayName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              InputFieldShell(
                child: TextField(
                  controller: _controller,
                  enabled: !_sending,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: 5000,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: context.l10n.group_requestReason,
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: _sending
              ? const LoadingSpinner(size: 20)
              : Text(context.l10n.common_send),
        ),
      ],
    ),
  );
}
