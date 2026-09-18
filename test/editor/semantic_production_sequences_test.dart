import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/node/node.dart' show SemanticNode;
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

import '../widgets/markdown_editor/composer_token_codec_test.dart'
    show parseWithNode, cookWithNode;

void main() {
  final codec = SemanticComposerCodec(
    tokenize: parseWithNode,
    cook: cookWithNode,
  );
  for (final type in [
    'blockquote',
    'callout',
    'spoiler',
    'wrap',
    'bullet_list',
  ]) {
    test('结构重建保留未投影空容器 $type', () {
      final empty = SemanticNode(type, attrs: {'plugin': '必须保留'});
      final paragraph = SemanticNode(
        'paragraph',
        attrs: {'plugin': 42},
        content: [SemanticNode('text', text: '甲乙')],
      );
      final original = SemanticNode('doc', content: [empty, paragraph]);
      final session = SemanticEditorSession(original);
      addTearDown(session.dispose);
      final e = session.editor;
      final block = e.blocks.whereType<TextBlock>().firstWhere(
        (b) => b.content.text == '甲乙',
      );
      e.updateSelection(
        EditorSelection.collapsed(EditorPosition(blockId: block.id, offset: 1)),
      );
      e.splitBlock();
      expect(
        session.tree.content.first,
        same(empty),
        reason: '编辑旁段不得吞掉未投影的空容器',
      );
      expect(session.tree.content[1].attrs['plugin'], 42);
      e.undo();
      expect(session.tree, same(original));
    });
  }
  test('真实bundle列表缩进反缩进及跨blockquote删除', () async {
    for (final raw in ['- 甲乙\n- 丙丁', '> 甲乙\n>\n> 丙丁']) {
      final imported = await codec.import(raw);
      expect(imported.failure, isNull);
      final session = SemanticEditorSession(imported.document!);
      addTearDown(session.dispose);
      final e = session.editor;
      final original = session.tree;
      if (raw.startsWith('-')) {
        e.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: e.blocks.last.id, offset: 1),
          ),
        );
        e.indentListItem();
        expect((e.blocks.last as TextBlock).depth, 1);
        expect(
          (await codec.import(codec.export(session.tree))).failure,
          isNull,
        );
        e.outdentListItem();
        expect((e.blocks.last as TextBlock).depth, 0);
        e.undo();
        e.undo();
        expect(session.tree, same(original));
      }
      e.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: e.blocks.first.id, offset: 1),
          extent: EditorPosition(blockId: e.blocks.last.id, offset: 1),
        ),
      );
      e.deleteSelection();
      expect(session.tree.textContent, '甲丁');
      expect((await codec.import(codec.export(session.tree))).failure, isNull);
      e.undo();
      expect(session.tree, same(original));
    }
  });
  final sources = <String, String>{
    '普通': '甲乙\n\n丙丁',
    '引用': '> 甲乙\n>\n> 丙丁',
    '列表': '- 甲乙\n- 丙丁',
    '详情': '[details="摘要"]\n甲乙\n\n丙丁\n[/details]',
    'wrap': '[wrap data-mock="x"]\n保留\n[/wrap]\n\n甲乙\n\n丙丁',
    '脚注': '甲乙[^1]\n\n丙丁\n\n[^1]: 注释',
  };
  final commands = <String, void Function(EditorState)>{
    '标题': (e) => e.toggleHeading(2),
    '无序列表': (e) => e.toggleList(ordered: false),
    '有序列表': (e) => e.toggleList(ordered: true),
    '引用切换': (e) => e.toggleQuote(),
    '输入': (e) => e.insertText('新'),
    '删除前字': (e) => e.backspace(),
    '删除后字': (e) => e.deleteForward(),
    '分段': (e) => e.splitBlock(),
    '粘贴多段': (e) => e.pastePlainText('新一\n\n新二'),
  };
  for (final source in sources.entries) {
    for (final command in commands.entries) {
      test('生产真实bundle ${source.key}/${command.key} 编辑导出撤销重做', () async {
        final imported = await codec.import(source.value);
        expect(imported.failure, isNull);
        final session = SemanticEditorSession(imported.document!);
        addTearDown(session.dispose);
        final e = session.editor;
        final block = e.blocks.whereType<TextBlock>().firstWhere(
          (b) => b.content.text.contains('甲乙'),
        );
        e.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: block.id, offset: 1),
          ),
        );
        final original = session.tree;
        command.value(e);
        final edited = session.tree;
        expect(identical(edited, original), isFalse);
        final exported = codec.export(edited);
        expect(
          (await codec.import(exported)).failure,
          isNull,
          reason: exported,
        );
        expect(edited.textContent, contains('丙丁'));
        if (source.key == 'wrap')
          expect(exported, contains('[wrap data-mock="x"]'));
        e.undo();
        expect(session.tree, same(original));
        expect(
          await cookWithNode(codec.export(session.tree)),
          await cookWithNode(source.value),
        );
        e.redo();
        expect(session.tree, same(edited));
      });
    }
  }
}
