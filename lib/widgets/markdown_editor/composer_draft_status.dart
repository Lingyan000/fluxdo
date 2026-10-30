import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/draft_controller.dart';
import '../../utils/dialog_utils.dart';

enum _DraftConflictChoice { reload, overwrite }

Future<bool> confirmComposerDraftOverwrite(
  BuildContext context, {
  Future<void> Function()? onReload,
}) async {
  final choice = await showAppDialog<_DraftConflictChoice>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(context.l10n.composer_draftConflictTitle),
      content: Text(context.l10n.composer_draftConflictBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.common_cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, _DraftConflictChoice.overwrite),
          child: Text(context.l10n.composer_draftOverwrite),
        ),
        if (onReload != null)
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _DraftConflictChoice.reload),
            child: Text(context.l10n.composer_draftUseRemote),
          ),
      ],
    ),
  );
  if (choice == _DraftConflictChoice.reload) await onReload?.call();
  return choice == _DraftConflictChoice.overwrite;
}

String composerDraftStatusLabel(BuildContext context, DraftSaveStatus status) =>
    switch (status) {
      DraftSaveStatus.idle => context.l10n.composer_draftAutoSave,
      DraftSaveStatus.pending => context.l10n.composer_draftPending,
      DraftSaveStatus.saving => context.l10n.composer_draftSaving,
      DraftSaveStatus.saved => context.l10n.composer_draftSaved,
      DraftSaveStatus.local => context.l10n.composer_draftLocal,
      DraftSaveStatus.conflict => context.l10n.composer_draftConflict,
      DraftSaveStatus.error => context.l10n.composer_draftError,
    };

/// 草稿状态只在菜单中展示，打开菜单期间继续跟随真实保存结果。
class ComposerDraftMenuEntry<T> extends PopupMenuEntry<T> {
  const ComposerDraftMenuEntry({
    super.key,
    required this.status,
    required this.retryValue,
    this.canRetry = true,
  });

  final ValueListenable<DraftSaveStatus> status;
  final T retryValue;
  final bool canRetry;

  @override
  double get height => 48;

  @override
  bool represents(T? value) => false;

  @override
  State<ComposerDraftMenuEntry<T>> createState() =>
      _ComposerDraftMenuEntryState<T>();
}

class _ComposerDraftMenuEntryState<T> extends State<ComposerDraftMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DraftSaveStatus>(
    valueListenable: widget.status,
    builder: (context, status, _) {
      final colors = Theme.of(context).colorScheme;
      final error =
          status == DraftSaveStatus.error || status == DraftSaveStatus.conflict;
      final retryable = error || status == DraftSaveStatus.local;
      final label = composerDraftStatusLabel(context, status);
      final color = error ? colors.error : colors.onSurfaceVariant;
      final icon = switch (status) {
        DraftSaveStatus.error => Symbols.cloud_off_rounded,
        DraftSaveStatus.saved => Symbols.cloud_done_rounded,
        _ => Symbols.cloud_upload_rounded,
      };
      return PopupMenuItem<T>(
        key: const ValueKey('composer-draft-status-item'),
        value: widget.retryValue,
        enabled: retryable && widget.canRetry,
        height: 48,
        child: Row(
          children: [
            if (status == DraftSaveStatus.saving &&
                !MediaQuery.disableAnimationsOf(context))
              SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: color,
                ),
              )
            else
              Icon(icon, size: 21, color: color),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                retryable && widget.canRetry
                    ? '$label · ${status == DraftSaveStatus.conflict ? context.l10n.composer_draftResolve : context.l10n.common_retry}'
                    : label,
                style: TextStyle(color: color),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 失败只标记既有的更多入口，不占新栏位，也不触发正文的布局变化。
class ComposerDraftAttention extends StatelessWidget {
  const ComposerDraftAttention({
    super.key,
    required this.status,
    required this.child,
  });

  final ValueListenable<DraftSaveStatus> status;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DraftSaveStatus>(
    valueListenable: status,
    builder: (context, value, _) => Semantics(
      value: value == DraftSaveStatus.error || value == DraftSaveStatus.conflict
          ? composerDraftStatusLabel(context, value)
          : null,
      liveRegion:
          value == DraftSaveStatus.error || value == DraftSaveStatus.conflict,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (value == DraftSaveStatus.error ||
              value == DraftSaveStatus.conflict)
            Positioned(
              right: -3,
              top: -1,
              child: DecoratedBox(
                key: const ValueKey('composer-draft-attention'),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox.square(dimension: 6),
              ),
            ),
        ],
      ),
    ),
  );
}
