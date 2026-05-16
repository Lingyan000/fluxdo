import 'package:flutter/material.dart';

import 'bookmark_name_edit_panel.dart';

class BookmarkPreviewQuickEditor extends StatefulWidget {
  const BookmarkPreviewQuickEditor({
    super.key,
    required this.onSave,
    this.initialName,
    this.suggestions = const <String>[],
    this.suggestionsLoader,
  });

  final String? initialName;
  final List<String> suggestions;
  final Future<List<String>> Function()? suggestionsLoader;
  final Future<bool> Function(String? value) onSave;

  @override
  State<BookmarkPreviewQuickEditor> createState() =>
      _BookmarkPreviewQuickEditorState();
}

class _BookmarkPreviewQuickEditorState
    extends State<BookmarkPreviewQuickEditor> {
  late final TextEditingController _controller;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(String? value) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final saved = await widget.onSave(value);
      if (saved && mounted) {
        Navigator.maybePop(context);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BookmarkNameEditPanel(
      controller: _controller,
      initialSuggestions: widget.suggestions,
      suggestionsLoader: widget.suggestionsLoader,
      isSaving: _isSaving,
      onSave: _save,
    );
  }
}
