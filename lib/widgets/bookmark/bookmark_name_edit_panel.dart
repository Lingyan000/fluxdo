import 'package:flutter/material.dart';

import 'bookmark_name_editor.dart';

/// 统一的书签名称编辑面板，负责复用缓存候选并后台刷新完整补全列表。
class BookmarkNameEditPanel extends StatefulWidget {
  const BookmarkNameEditPanel({
    super.key,
    required this.controller,
    this.initialSuggestions = const <String>[],
    this.suggestionsLoader,
    this.onSave,
    this.isSaving = false,
  });

  final TextEditingController controller;
  final List<String> initialSuggestions;
  final Future<List<String>> Function()? suggestionsLoader;
  final Future<void> Function(String? value)? onSave;
  final bool isSaving;

  @override
  State<BookmarkNameEditPanel> createState() => _BookmarkNameEditPanelState();
}

class _BookmarkNameEditPanelState extends State<BookmarkNameEditPanel> {
  late List<String> _suggestions;

  @override
  void initState() {
    super.initState();
    _suggestions = [...widget.initialSuggestions];
    if (widget.suggestionsLoader != null || _suggestions.isEmpty) {
      _loadSuggestions();
    }
  }

  Future<void> _loadSuggestions() async {
    final loader = widget.suggestionsLoader;
    if (loader == null) {
      return;
    }

    try {
      final suggestions = await loader();
      if (!mounted) return;
      setState(() {
        _suggestions = suggestions;
      });
    } catch (_) {
      // 候选加载失败不阻断编辑，继续使用已有缓存。
    }
  }

  @override
  Widget build(BuildContext context) {
    return BookmarkNameEditor(
      controller: widget.controller,
      suggestions: _suggestions,
      onSave: widget.onSave,
      isSaving: widget.isSaving,
    );
  }
}
