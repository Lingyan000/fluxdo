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
    required this.row,
    required this.target,
  });
  final ValueListenable<EditorTableContext?> contextListenable;
  final VoidCallback onClose;
  final bool row;
  final EditorTableContext target;
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
          final valid =
              table != null &&
              table.tableId == widget.target.tableId &&
              table.cell == widget.target.cell &&
              table.revision == widget.target.revision;
          final confirming =
              valid &&
              _confirmation != null &&
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
            onPressed: !valid || _busy || !table.enabled(action)
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
          return TextFieldTapRegion(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.row
                            ? t.table_row_target(
                                number: widget.target.cell.$1 + 1,
                              )
                            : t.table_column_target(
                                number: widget.target.cell.$2 + 1,
                              ),
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
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_failed || !valid) Text(t.table_changed),
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
                            if (widget.row) ...[
                              button(EditorTableAction.rowBefore),
                              button(EditorTableAction.rowAfter),
                              const Divider(),
                              button(EditorTableAction.deleteRow),
                              if (table.rows <= 1) Text(t.table_keep_row),
                            ] else ...[
                              button(EditorTableAction.columnBefore),
                              button(EditorTableAction.columnAfter),
                              const Divider(),
                              button(EditorTableAction.deleteColumn),
                              if (table.columns <= 1) Text(t.table_keep_column),
                            ],
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

/// 表格自身的结构入口，不占用工具岛格式行，也不随宽表横向滚走。
class ComposerTableControls extends StatelessWidget {
  const ComposerTableControls({
    super.key,
    required this.cell,
    required this.onOpen,
  });
  final (int, int)? cell;
  final void Function(bool row, Rect anchor) onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.editor;
    Widget control(bool row) => Builder(
      builder: (context) => TextButton.icon(
        key: ValueKey(row ? 'table-row-operations' : 'table-column-operations'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: cell == null
            ? null
            : () {
                final box = context.findRenderObject() as RenderBox;
                onOpen(row, box.localToGlobal(Offset.zero) & box.size);
              },
        icon: Icon(
          row ? Icons.table_rows_outlined : Icons.view_column_outlined,
          size: 20,
        ),
        label: Text(
          row
              ? t.table_row_target(number: (cell?.$1 ?? 0) + 1)
              : t.table_column_target(number: (cell?.$2 ?? 0) + 1),
        ),
      ),
    );
    return Wrap(spacing: 8, children: [control(true), control(false)]);
  }
}
