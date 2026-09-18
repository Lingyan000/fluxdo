import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  test('富文本宿主可构造', () {
    expect(RichComposerEditor, isNotNull);
  });
  test('上传完成撤销不恢复空占位，重做恢复正式内容', () {
    final editor = EditorState(
      blocks: [
        TextBlock(
          id: 'body',
          content: EditableTextContent(text: '正文'),
        ),
      ],
    );
    addTearDown(editor.dispose);
    editor.insertIslandAfter(
      'body',
      const ParagraphNode(id: 'upload-1', inlines: []),
    );
    final id = editor.selection!.extent.blockId;
    final index = editor.indexOfBlock(id);
    editor.replaceBlockRange(index, index, [
      TextBlock(
        id: 'result',
        content: EditableTextContent(text: '附件'),
      ),
    ]);
    editor.forgetTransientBlockInHistory(id);
    editor.undo();
    expect(editor.blocks.any((b) => b.id == id), false);
    expect(editor.exportMarkdown(), '正文');
    editor.redo();
    expect(editor.exportMarkdown(), contains('附件'));
  });

  test('空岛占位不会序列化路径，撤销插入可按块 ID 检出删除', () {
    final editor = EditorState(
      blocks: [
        TextBlock(
          id: 'body',
          content: EditableTextContent(text: '正文'),
        ),
      ],
    );
    addTearDown(editor.dispose);
    editor.insertIslandAfter(
      'body',
      const ParagraphNode(id: 'upload-1', inlines: []),
    );
    final placeholder = editor.selection!.extent.blockId;
    expect(editor.indexOfBlock(placeholder), greaterThanOrEqualTo(0));
    final raw = editor.exportMarkdown(
      fragment: editor.blocks
          .where(
            (block) => block is! IslandBlock || block.node.id != 'upload-1',
          )
          .toList(),
    );
    expect(raw, '正文');
    expect(editor.exportMarkdown(), isNot(contains('upload-1')));
    editor.undo();
    expect(editor.indexOfBlock(placeholder), -1);
    editor.redo();
    expect(editor.indexOfBlock(placeholder), greaterThanOrEqualTo(0));
    expect(editor.exportMarkdown(), isNot(contains('upload-1')));
  });
}
