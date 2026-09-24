import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluxdo_render/editor.dart';

import '../../l10n/s.dart';

/// 保留输入焦点的工具岛内容，确认也在同一面板内进行。
class ComposerTablePanel extends StatefulWidget {
  const ComposerTablePanel({
    super.key,
    required this.contextListenable,
    required this.onClose,
  });
  final ValueListenable<EditorTableContext?> contextListenable;
  final VoidCallback onClose;
  @override
  State<ComposerTablePanel> createState() => _ComposerTablePanelState();
}

class _ComposerTablePanelState extends State<ComposerTablePanel> {
  EditorTableAction? _confirmation;
  EditorTableContext? _confirmedContext;
  bool _busy = false;
  bool _failed = false;

  Future<void> _execute(
    EditorTableContext table,
    EditorTableAction action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final result = await table.execute(action);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _confirmation = null;
    });
    if (result == EditorTableActionResult.success) {
      widget.onClose();
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<EditorTableContext?>(
        valueListenable: widget.contextListenable,
        builder: (context, table, _) {
          final t = context.l10n.editor;
          final confirming =
              _confirmation != null &&
              table != null &&
              _confirmedContext?.tableId == table.tableId &&
              _confirmedContext?.cell == table.cell &&
              _confirmedContext?.revision == table.revision;
          String label(EditorTableAction action) => switch (action) {
            EditorTableAction.rowBefore => t.table_row_before,
            EditorTableAction.rowAfter => t.table_row_after,
            EditorTableAction.columnBefore => t.table_column_before,
            EditorTableAction.columnAfter => t.table_column_after,
            EditorTableAction.deleteRow => t.table_delete_row,
            EditorTableAction.deleteColumn => t.table_delete_column,
          };
          Widget button(EditorTableAction action) => TextButton.icon(
            key: ValueKey('table-action-${action.name}'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor:
                  action == EditorTableAction.deleteRow ||
                      action == EditorTableAction.deleteColumn
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            icon: Icon(switch (action) {
              EditorTableAction.rowBefore => Icons.arrow_upward,
              EditorTableAction.rowAfter => Icons.arrow_downward,
              EditorTableAction.columnBefore => Icons.arrow_back,
              EditorTableAction.columnAfter => Icons.arrow_forward,
              _ => Icons.delete_outline,
            }),
            label: Text(label(action)),
            onPressed: table == null || _busy || !table.enabled(action)
                ? null
                : () {
                    if (table.needsConfirmation(action)) {
                      setState(() {
                        _confirmation = action;
                        _confirmedContext = table;
                      });
                    } else {
                      _execute(table, action);
                    }
                  },
          );
          Widget pair(EditorTableAction first, EditorTableAction second) =>
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 320 ||
                      MediaQuery.textScalerOf(context).scale(14) > 18) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        button(first),
                        const SizedBox(height: 8),
                        button(second),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: button(first)),
                      const SizedBox(width: 8),
                      Expanded(child: button(second)),
                    ],
                  );
                },
              );
          return TextFieldTapRegion(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.table_operations,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: t.table_close,
                      onPressed: _busy ? null : widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (table != null)
                            Text(
                              t.table_position(
                                row: table.cell.$1 + 1,
                                column: table.cell.$2 + 1,
                              ),
                            ),
                          if (_failed || (_confirmation != null && !confirming))
                            Text(t.table_changed),
                          if (_busy) const LinearProgressIndicator(),
                          if (confirming) ...[
                            Text('${label(_confirmation!)}？'),
                            Text(t.table_delete_warning),
                            TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => setState(() => _confirmation = null),
                              child: Text(t.table_cancel),
                            ),
                            TextButton(
                              key: const ValueKey('table-confirm-delete'),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                foregroundColor: Theme.of(context)
                                    .colorScheme
                                    .error,
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _execute(table, _confirmation!),
                              child: Text(t.table_confirm_delete),
                            ),
                          ] else if (table != null) ...[
                            const SizedBox(height: 8),
                            pair(
                              EditorTableAction.rowBefore,
                              EditorTableAction.rowAfter,
                            ),
                            const SizedBox(height: 8),
                            button(EditorTableAction.deleteRow),
                            if (table.rows <= 1) Text(t.table_keep_row),
                            const Divider(),
                            pair(
                              EditorTableAction.columnBefore,
                              EditorTableAction.columnAfter,
                            ),
                            const SizedBox(height: 8),
                            button(EditorTableAction.deleteColumn),
                            if (table.columns <= 1) Text(t.table_keep_column),
                          ] else
                            Text(t.table_select_cell),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
}
