import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/insertion_bookmark.dart';

void main() {
  test('替换选区一次撤销恢复原文和选区', () {
    final editor = EditorState.fromTexts(['abcdef']);
    addTearDown(editor.dispose);
    final id = editor.blocks.first.id;
    final selected = EditorSelection(
      base: EditorPosition(blockId: id, offset: 1),
      extent: EditorPosition(blockId: id, offset: 4),
    );
    editor.updateSelection(selected);
    var notifications = 0;
    editor.addListener(() => notifications++);
    editor.pasteBlocks([
      TextBlock(
        id: 'insert',
        content: EditableTextContent(text: '图片'),
      ),
    ]);
    expect(editor.exportMarkdown(), 'a图片ef');
    expect(notifications, 1);
    editor.undo();
    expect(editor.exportMarkdown(), 'abcdef');
    expect(editor.selection, selected);
    expect(editor.canUndo, false);
    editor.redo();
    expect(editor.exportMarkdown(), 'a图片ef');
  });
  test('引用内插入块保留前后引用文字，撤销一步还原', () {
    final editor = EditorState.fromTexts(['前文后文']);
    addTearDown(editor.dispose);
    final id = editor.blocks.first.id;
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 2)),
    );
    editor.toggleQuote();
    final original = editor.exportMarkdown();
    editor.pasteBlocks([
      IslandBlock(
        id: 'new',
        node: const ParagraphNode(id: 'node', inlines: []),
      ),
    ]);
    final textBlocks = editor.blocks.whereType<TextBlock>().toList();
    expect(textBlocks.first.content.text, '前文');
    expect(textBlocks.last.content.text, '后文');
    expect(textBlocks.first.containers, isNotEmpty);
    expect(textBlocks.last.containers, textBlocks.first.containers);
    editor.undo();
    expect(editor.exportMarkdown(), original);
  });

  test('异步锚点跟随前方输入，不跟随光标移动', () {
    final editor = EditorState.fromTexts(['abcdef']);
    addTearDown(editor.dispose);
    final id = editor.blocks.first.id;
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 4)),
    );
    final bookmark = InsertionBookmark(editor);
    addTearDown(bookmark.dispose);
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 0)),
    );
    editor.pastePlainText('XX');
    expect(bookmark.valid, true);
    expect(bookmark.selection!.extent.offset, 6);
  });
  test('被替换的选区内容遭修改则取消迟到插入', () {
    final editor = EditorState.fromTexts(['abcdef']);
    addTearDown(editor.dispose);
    final id = editor.blocks.first.id;
    editor.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: id, offset: 1),
        extent: EditorPosition(blockId: id, offset: 4),
      ),
    );
    final bookmark = InsertionBookmark(editor);
    addTearDown(bookmark.dispose);
    editor.pastePlainText('用户新文字');
    expect(bookmark.valid, false);
  });
}
