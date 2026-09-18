import 'package:flutter/widgets.dart';

/// 上传插入点不写入正文；同位置的任务按创建顺序排列。
class MarkdownInsertionAnchor {
  MarkdownInsertionAnchor._(this.offset, this.order);
  int offset;
  final int order;
}

class MarkdownInsertionAnchors {
  MarkdownInsertionAnchors(this.controller) : _text = controller.text {
    controller.addListener(_onChanged);
  }

  final TextEditingController controller;
  final List<MarkdownInsertionAnchor> _anchors = [];
  String _text;
  int _order = 0;
  bool _inserting = false;
  bool _disposed = false;

  /// 正文监听器可据此跳过仅针对键入的自动续行。
  bool get isInserting => _inserting;

  MarkdownInsertionAnchor capture() {
    final selection = controller.selection;
    final anchor = MarkdownInsertionAnchor._(
      selection.isValid ? selection.start : controller.text.length,
      _order++,
    );
    _anchors.add(anchor);
    return anchor;
  }

  MarkdownInsertionAnchor fork(MarkdownInsertionAnchor source) {
    final anchor = MarkdownInsertionAnchor._(source.offset, _order++);
    _anchors.add(anchor);
    return anchor;
  }

  void release(MarkdownInsertionAnchor anchor) => _anchors.remove(anchor);

  void _onChanged() {
    if (_disposed || _inserting) return;
    final next = controller.text;
    if (_text == next) return;
    var start = 0;
    while (start < _text.length &&
        start < next.length &&
        _text.codeUnitAt(start) == next.codeUnitAt(start)) {
      start++;
    }
    var oldEnd = _text.length;
    var newEnd = next.length;
    while (oldEnd > start &&
        newEnd > start &&
        _text.codeUnitAt(oldEnd - 1) == next.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    for (final anchor in _anchors) {
      if (anchor.offset > start) {
        anchor.offset = anchor.offset >= oldEnd
            ? anchor.offset + newEnd - oldEnd
            : start;
      }
    }
    _text = next;
  }

  /// 保留用户当前选区和输入法组合区；从不请求焦点。
  void insertBlock(MarkdownInsertionAnchor anchor, String markdown) {
    if (_disposed || !_anchors.contains(anchor)) return;
    _onChanged();
    final value = controller.value;
    final offset = anchor.offset.clamp(0, value.text.length);
    final prefix = offset > 0 && value.text[offset - 1] != '\n' ? '\n' : '';
    final insertion = '$prefix$markdown\n';
    int shift(int position) =>
        position > offset ? position + insertion.length : position;
    for (final other in _anchors) {
      if (other.offset > offset ||
          (other.offset == offset && other.order > anchor.order)) {
        other.offset += insertion.length;
      }
    }
    release(anchor);
    _text = value.text.replaceRange(offset, offset, insertion);
    _inserting = true;
    try {
      controller.value = value.copyWith(
        text: _text,
        selection: value.selection.isValid
            ? value.selection.copyWith(
                baseOffset: shift(value.selection.baseOffset),
                extentOffset: shift(value.selection.extentOffset),
              )
            : value.selection,
        composing: value.composing.isValid
            ? (offset > value.composing.start && offset < value.composing.end
                  ? TextRange.empty
                  : TextRange(
                      start: value.composing.start >= offset
                          ? value.composing.start + insertion.length
                          : value.composing.start,
                      end:
                          value.composing.end > offset ||
                              value.composing.start >= offset
                          ? value.composing.end + insertion.length
                          : value.composing.end,
                    ))
            : value.composing,
      );
    } finally {
      _inserting = false;
      // 其他正文监听器可能同步执行自动排版。
      _onChanged();
    }
  }

  void dispose() {
    _disposed = true;
    controller.removeListener(_onChanged);
    _anchors.clear();
  }
}
