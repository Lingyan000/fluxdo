import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/widgets/markdown_editor/editor_tools.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/editor.dart' show IslandBlock;
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/semantic_editor.dart';

import '../../helpers/discourse_cook_node.dart';

import 'composer_interaction_test.dart' show pumpApp;

void main() {
  testWidgets('源码工具只给选中的多行内容加 AI 引用标识', (tester) async {
    final key = GlobalKey<MarkdownToolbarState>();
    final controller = TextEditingController(text: 'before first\nsecond after')
      ..selection = const TextSelection(baseOffset: 7, extentOffset: 19);
    addTearDown(controller.dispose);
    await pumpApp(tester, Scaffold(body: MarkdownToolbar(
      key: key, controller: controller, visibleToolIds: const ['aiContent'],
    )));
    final tool = editorTools.singleWhere((tool) => tool.id == 'aiContent');
    tool.onMenuSelected!(key.currentState!, 'quote');
    expect(controller.text, 'before \n\n> [!AI]\n> first\n> second\n\n after');
  });
  final codec = SemanticComposerCodec(
    cook: cookWithNode,
    tokenize: parseWithNode,
  );
  final parser = ParagraphParser();
  for (final raw in [
    '``` ai\nexample\n```',
    '```dart ai\nexample\n```',
    '> [!AI]\n> example',
    '[quote ai]\nexample\n[/quote]',
    '[quote="sam, post:1, topic:2" ai]\nexample\n[/quote]',
    '[details="Summary" open ai]\nexample\n[/details]',
  ]) {
    test('AI 内容在阅读、富文本导入和导出时保留标识 $raw', () async {
      final cooked = await cookWithNode(raw);
      final block = parser.parse(cooked).single;
      switch (block) {
        case CodeBlockNode():
          expect(block.aiGenerated, isTrue);
          expect(block.code, 'example');
        case BlockquoteNode():
          expect(block.aiGenerated, isTrue);
        case QuoteCardNode():
          expect(block.aiGenerated, isTrue);
        case DetailsNode():
          expect(block.aiGenerated, isTrue);
          expect(block.summary, 'Summary');
          expect(block.initiallyOpen, isTrue);
        default:
          fail('意外的节点 $block');
      }
      final imported = await codec.import(raw);
      expect(imported.failure, isNull);
      expect(
        SemanticEditorProjection.project(imported.document!).blocks,
        isNotEmpty,
      );
      expect(await cookWithNode(codec.export(imported.document!)), cooked);
    });
  }
  test('修改 AI 代码的语言仍保留围栏的其他选项', () async {
    const raw = '```dart wrap=lines,ai\nexample\n```';
    final imported = await codec.import(raw);
    expect(imported.failure, isNull);
    final session = SemanticEditorSession(imported.document!);
    addTearDown(session.dispose);
    final island = session.editor.blocks.whereType<IslandBlock>().single;
    final code = island.node as CodeBlockNode;
    expect(code.language, 'dart');
    expect(code.aiGenerated, isTrue);
    session.editor.updateIslandNode(island.id, CodeBlockNode(
      id: code.id, code: 'edited', language: null, aiGenerated: code.aiGenerated,
    ));
    final output = codec.export(session.tree);
    expect(output, contains('```auto wrap=lines,ai\nedited'));
    expect((parser.parse(await cookWithNode(output)).single as CodeBlockNode).aiGenerated, isTrue);
  });
  test('语言名 ai 和代码正文中的标记均不触发标识', () async {
    final cooked = await cookWithNode('```ai\n> [!AI]\n```');
    final block = parser.parse(cooked).single as CodeBlockNode;
    expect(block.aiGenerated, isFalse);
    expect(block.code, '> [!AI]');
  });
}
