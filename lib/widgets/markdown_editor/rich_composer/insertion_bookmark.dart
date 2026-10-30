import 'package:fluxdo_render/editor.dart';

/// 异步转换期间追踪原选区。目标块被删除或选中文字被修改时失效，
/// 不把迟到内容插到用户的新光标，也不覆盖用户在等待期间修改的文字。
class InsertionBookmark {
  InsertionBookmark(this.editor, {EditorSelection? selection})
    : selection = selection ?? editor.selection {
    _capture();
    editor.addListener(_update);
  }
  final EditorState editor;
  EditorSelection? selection;
  Map<String, EditorBlock> _previous = {};
  bool valid = true;
  bool _disposed = false;

  void _capture() =>
      _previous = {for (final block in editor.blocks) block.id: block};

  void _update() {
    final selected = selection;
    if (!valid || selected == null) return;
    EditorPosition? map(EditorPosition pos) {
      final index = editor.indexOfBlock(pos.blockId);
      if (index < 0) return null;
      final old = _previous[pos.blockId];
      final next = editor.blocks[index];
      if (old == next) return pos;
      if (old is! TextBlock || next is! TextBlock) return null;
      final a = old.content.text;
      final b = next.content.text;
      if (a == b) return pos;
      var start = 0;
      while (start < a.length && start < b.length && a[start] == b[start]) {
        start++;
      }
      var endA = a.length;
      var endB = b.length;
      while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
        endA--;
        endB--;
      }
      if (!selected.isCollapsed && selected.isSingleBlock) {
        final from = selected.base.offset < selected.extent.offset
            ? selected.base.offset
            : selected.extent.offset;
        final to = selected.base.offset > selected.extent.offset
            ? selected.base.offset
            : selected.extent.offset;
        if (start < to && endA > from) return null;
      } else if (!selected.isCollapsed) {
        // 跨块替换期间任一端点块被编辑，保守取消，避免吞掉新输入。
        return null;
      }
      if (pos.offset <= start) return pos;
      if (pos.offset < endA) return null;
      return pos.copyWith(offset: pos.offset + endB - endA);
    }

    final base = map(selected.base);
    final extent = map(selected.extent);
    valid = base != null && extent != null;
    if (valid) selection = EditorSelection(base: base!, extent: extent!);
    _capture();
  }

  void moveTo(EditorSelection? value) {
    selection = value;
    valid = value != null;
    _capture();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    editor.removeListener(_update);
  }
}
