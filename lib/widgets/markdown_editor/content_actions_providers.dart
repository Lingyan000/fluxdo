/// [ContentActionsProvider] 的两个实现：源码模式与富文本模式。
///
/// 两种模式的内容操作语义相同、实现路径完全不同：
/// - 源码模式是原生 [TextField]，撤销走 [UndoHistoryController]、剪贴板走
///   系统 [Clipboard] 的纯文本通道；
/// - 富文本是自绘编辑器，撤销走 EditorState 历史栈、剪贴板要经 markdown
///   序列化与 cook 导入链（见 fluxdo_render 的 FluxdoEditorContentActions）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo_render/editor.dart' show FluxdoEditorContentActions;

import 'content_actions_button.dart';

/// 源码模式：TextField + UndoHistoryController。
class SourceContentActions implements ContentActionsProvider {
  SourceContentActions({
    required this.controller,
    required this.undoController,
    required this.focusNode,
  });

  final TextEditingController controller;
  final UndoHistoryController undoController;
  final FocusNode focusNode;

  @override
  bool get isAvailable => true;

  @override
  bool get canUndo => undoController.value.canUndo;

  @override
  bool get canRedo => undoController.value.canRedo;

  @override
  bool get hasSelection {
    final sel = controller.selection;
    return sel.isValid && !sel.isCollapsed;
  }

  @override
  void undo() {
    undoController.undo();
    focusNode.requestFocus();
  }

  @override
  void redo() {
    undoController.redo();
    focusNode.requestFocus();
  }

  @override
  void selectAll() {
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    focusNode.requestFocus();
  }

  @override
  void copy() {
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    Clipboard.setData(ClipboardData(text: sel.textInside(controller.text)));
  }

  @override
  void cut() {
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final text = controller.text;
    Clipboard.setData(ClipboardData(text: sel.textInside(text)));
    // 一次性写回 value：文本与选区同帧更新，避免 selection 越界
    final next = sel.textBefore(text) + sel.textAfter(text);
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start),
    );
    focusNode.requestFocus();
  }

  @override
  Future<void> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final clip = data?.text;
    if (clip == null || clip.isEmpty) return;
    final text = controller.text;
    var sel = controller.selection;
    // 选区无效（如刚 flush 过）时退化为「插到末尾」，不能拿 -1 去切字符串
    if (!sel.isValid) {
      sel = TextSelection.collapsed(offset: text.length);
    }
    final next = sel.textBefore(text) + clip + sel.textAfter(text);
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + clip.length),
    );
    focusNode.requestFocus();
  }
}

/// 富文本模式：转发到编辑器内核句柄。
class RichContentActions implements ContentActionsProvider {
  RichContentActions(this.actions);

  final FluxdoEditorContentActions actions;

  @override
  bool get isAvailable => actions.isAttached;

  @override
  bool get canUndo => actions.canUndo;

  @override
  bool get canRedo => actions.canRedo;

  @override
  bool get hasSelection => actions.hasSelection;

  @override
  void undo() => actions.undo();

  @override
  void redo() => actions.redo();

  @override
  void selectAll() => actions.selectAll();

  @override
  void copy() => actions.copy();

  @override
  void cut() => actions.cut();

  @override
  void paste() => actions.paste();
}
