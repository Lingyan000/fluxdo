import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/shortcut_binding.dart';
import '../../providers/shortcut_provider.dart';
import '../../utils/dialog_utils.dart';
import '../../widgets/shortcut/shortcut_ui.dart';
import '../settings_model.dart';

/// 快捷键设置数据声明
List<SettingsGroup> buildShortcutGroups(BuildContext context) {
  final l10n = context.l10n;

  return [
    SettingsGroup(
      title: l10n.shortcuts_navigation,
      icon: Icons.navigation_rounded,
      items: [
        _maybeShortcutCustomModel(ShortcutAction.navigateBack, l10n),
        _maybeShortcutCustomModel(ShortcutAction.navigateBackAlt, l10n),
        _maybeShortcutCustomModel(ShortcutAction.openSearch, l10n),
        _maybeShortcutCustomModel(ShortcutAction.openSettings, l10n),
        _maybeShortcutCustomModel(ShortcutAction.toggleNotifications, l10n),
        _maybeShortcutCustomModel(ShortcutAction.switchToTopics, l10n),
        _maybeShortcutCustomModel(ShortcutAction.switchToProfile, l10n),
        _maybeShortcutCustomModel(ShortcutAction.previousTab, l10n),
        _maybeShortcutCustomModel(ShortcutAction.nextTab, l10n),
        _maybeShortcutCustomModel(ShortcutAction.switchPane, l10n),
      ].whereType<CustomModel>().toList(),
    ),
    SettingsGroup(
      title: l10n.shortcuts_content,
      icon: Icons.article_rounded,
      items: [
        _maybeShortcutCustomModel(ShortcutAction.closeOverlay, l10n),
        _maybeShortcutCustomModel(ShortcutAction.refresh, l10n),
        _maybeShortcutCustomModel(ShortcutAction.createTopic, l10n),
        _maybeShortcutCustomModel(ShortcutAction.nextItem, l10n),
        _maybeShortcutCustomModel(ShortcutAction.previousItem, l10n),
        _maybeShortcutCustomModel(ShortcutAction.openItem, l10n),
        _maybeShortcutCustomModel(ShortcutAction.toggleAiPanel, l10n),
        _maybeShortcutCustomModel(ShortcutAction.showShortcutHelp, l10n),
      ].whereType<CustomModel>().toList(),
    ),
    SettingsGroup(
      title: l10n.shortcuts_topic,
      icon: Icons.topic_outlined,
      items: [
        _maybeShortcutCustomModel(ShortcutAction.jumpToPost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.goToUnreadPost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.replyTopic, l10n),
        _maybeShortcutCustomModel(ShortcutAction.shareTopic, l10n),
        _maybeShortcutCustomModel(ShortcutAction.bookmarkTopic, l10n),
      ].whereType<CustomModel>().toList(),
    ),
    SettingsGroup(
      title: l10n.shortcuts_post,
      icon: Icons.forum_outlined,
      items: [
        _maybeShortcutCustomModel(ShortcutAction.replyPost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.quotePost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.likePost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.sharePost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.bookmarkPost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.editPost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.flagPost, l10n),
        _maybeShortcutCustomModel(ShortcutAction.deletePost, l10n),
      ].whereType<CustomModel>().toList(),
    ),
  ];
}

CustomModel? _maybeShortcutCustomModel(
  ShortcutAction action,
  AppLocalizations l10n,
) {
  if (!shortcutActionSupported(action)) return null;
  return _shortcutCustomModel(action, l10n);
}

CustomModel _shortcutCustomModel(ShortcutAction action, AppLocalizations l10n) {
  final label = shortcutActionLabel(action, l10n);
  return CustomModel(
    id: 'shortcut_${action.name}',
    title: label,
    builder: (context, ref) => _ShortcutTile(action: action, label: label),
  );
}

class _ShortcutTile extends ConsumerWidget {
  final ShortcutAction action;
  final String label;

  const _ShortcutTile({required this.action, required this.label});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bindings = ref.watch(shortcutProvider);
    final binding = bindings.firstWhere((b) => b.action == action);
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showRecordKeyDialog(context, ref, binding),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.end,
                    children: [
                      if (binding.isCustomized)
                        _ShortcutMetaChip(
                          label: l10n.common_custom,
                          color: theme.colorScheme.primary,
                        ),
                      ShortcutActivatorCaps(
                        activator: binding.activator,
                        alignment: WrapAlignment.end,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.outline.withValues(alpha: 0.42),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRecordKeyDialog(
    BuildContext context,
    WidgetRef ref,
    ShortcutBinding binding,
  ) {
    showAppDialog(
      context: context,
      builder: (dialogContext) =>
          _RecordKeyDialog(binding: binding, parentRef: ref),
    );
  }
}

/// 录键对话框
class _RecordKeyDialog extends StatefulWidget {
  final ShortcutBinding binding;
  final WidgetRef parentRef;

  const _RecordKeyDialog({required this.binding, required this.parentRef});

  @override
  State<_RecordKeyDialog> createState() => _RecordKeyDialogState();
}

class _RecordKeyDialogState extends State<_RecordKeyDialog> {
  SingleActivator? _recorded;
  ShortcutAction? _conflict;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: AlertDialog(
        title: Text(shortcutActionLabel(widget.binding.action, l10n)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 当前/录入的按键显示
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _conflict != null
                      ? theme.colorScheme.error.withValues(alpha: 0.5)
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Center(
                child: _recorded != null
                    ? ShortcutActivatorCaps(
                        activator: _recorded!,
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        minKeyWidth: 36,
                        fontSize: 14,
                        keyPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      )
                    : Text(
                        l10n.shortcuts_recordKey,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            // 冲突提示
            if (_conflict != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: theme.colorScheme.error,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.shortcuts_conflict(
                        shortcutActionLabel(_conflict!, l10n),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          // 恢复默认
          TextButton(
            onPressed: () async {
              await widget.parentRef
                  .read(shortcutProvider.notifier)
                  .resetBinding(widget.binding.action);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(l10n.shortcuts_resetOne),
          ),
          // 取消
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          // 确认
          FilledButton(
            onPressed: _recorded != null && _conflict == null
                ? () async {
                    await widget.parentRef
                        .read(shortcutProvider.notifier)
                        .updateBinding(widget.binding.action, _recorded!);
                    if (context.mounted) Navigator.pop(context);
                  }
                : null,
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final key = event.logicalKey;

    // 忽略单独的修饰键
    if (_isModifierKey(key)) return;

    final activator = SingleActivator(
      key,
      control: HardwareKeyboard.instance.isControlPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      meta: HardwareKeyboard.instance.isMetaPressed,
    );

    // 检查冲突
    final conflict = widget.parentRef
        .read(shortcutProvider.notifier)
        .findConflict(activator, excludeAction: widget.binding.action);

    setState(() {
      _recorded = activator;
      _conflict = conflict;
    });
  }

  bool _isModifierKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }
}

class _ShortcutMetaChip extends StatelessWidget {
  final String label;
  final Color color;

  const _ShortcutMetaChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
