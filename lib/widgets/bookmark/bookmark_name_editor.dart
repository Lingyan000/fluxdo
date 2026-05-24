import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import 'bookmark_name_autocomplete_field.dart';

class BookmarkNameEditor extends StatefulWidget {
  const BookmarkNameEditor({
    super.key,
    required this.controller,
    required this.suggestions,
    this.onSave,
    this.isSaving = false,
  });

  final TextEditingController controller;
  final Iterable<String> suggestions;
  final Future<void> Function(String? value)? onSave;
  final bool isSaving;

  bool get showInlineSaveButton => onSave != null;

  @override
  State<BookmarkNameEditor> createState() => _BookmarkNameEditorState();
}

class _BookmarkNameEditorState extends State<BookmarkNameEditor> {
  static const double _compactLayoutWidth = 420;

  Future<void> _save() async {
    final save = widget.onSave;
    if (save == null || widget.isSaving) {
      return;
    }
    final value = widget.controller.text.trim();
    await save(value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    final field = BookmarkNameAutocompleteField(
      controller: widget.controller,
      suggestions: widget.suggestions,
      labelText: context.l10n.bookmark_nameLabel,
      hintText: context.l10n.bookmark_nameHint,
    );

    if (!widget.showInlineSaveButton) {
      return field;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compactLayout = constraints.maxWidth < _compactLayoutWidth;
        final saveButton = SizedBox(
          width: compactLayout ? double.infinity : null,
          child: FilledButton(
            onPressed: widget.isSaving ? null : _save,
            child: widget.isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(context.l10n.common_save),
          ),
        );

        return compactLayout
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [field, const SizedBox(height: 12), saveButton],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 12),
                  saveButton,
                ],
              );
      },
    );
  }
}
