import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
// 真实 cook 严格相等，不放宽门禁或将支持项退回源码。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import '../../helpers/discourse_cook_node.dart';

final codec = SemanticComposerCodec(
  cook: cookWithNode,
  tokenize: parseWithNode,
);

void main() {
  for (final raw in [
    '[date=2027-03-12 recurring="1.months" timezone="Asia/Shanghai"]',
    '[date=2027-03-12 countdown=false]',
    '[date-range from=2027-03-12T10:20:30 to=2027-03-15T12:34:56 timezone="Asia/Shanghai" countdown=false]',
    '[b]mock[/b]',
    '[i]mock[/i]',
    '[u]mock[/u]',
    '[s]mock[/s]',
    '[b]甲[i]乙[/i]丙[/b]',
    '[i]甲[b]乙[/b]丙[/i]',
    '前 <u>mock</u> 后',
    '前 [spoiler]mock[/spoiler] 后',
  ]) {
    test('日期样式真实三轮严格往返：$raw', () async {
      final cooked = await cookWithNode(raw);
      var current = raw;
      for (var round = 0; round < 3; round++) {
        final result = await codec.import(current);
        expect(result.failure, isNull);
        current = codec.export(result.document!);
        expect(await cookWithNode(current), cooked);
      }
    });
  }
  for (final tag in ['b', 'i', 'u', 's']) {
    testWidgets('IR 点击物化后保留 $tag 来源', (tester) async {
      final raw = '[$tag]mock[/$tag]';
      final dto = await tester.runAsync(() => parseWithNode(raw));
      final tree = const SemanticDocumentCodec().parseTokens(
        dto!['tokens'] as List,
      );
      final session = SemanticEditorSession(tree);
      addTearDown(session.dispose);
      final state = session.editor..mode = EditorMode.ir;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FluxdoEditor(state: state)),
        ),
      );
      state.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: state.blocks.first.id, offset: 2),
        ),
      );
      await tester.pump();
      expect(codec.export(session.exportTree()), raw);
      state.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: state.blocks.first.id, offset: 0),
        ),
      );
      await tester.pump();
      expect(codec.export(session.exportTree()), raw);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  test('marks 转回 inlines 并编辑仍保定界符来源', () {
    final content = EditableTextContent.fromInlines(const [
      StrongRun(editorSyntax: 'b', children: [TextRun('粗')]),
      EmRun(editorSyntax: 'i', children: [TextRun('斜')]),
      StyledRun(
        kind: InlineStyleKind.underline,
        editorSyntax: 'u',
        children: [TextRun('线')],
      ),
    ]);
    final rebuilt = EditableTextContent.fromInlines(
      content.insert(1, '新').toInlines(),
    );
    expect(
      rebuilt.marks.where((m) => m.kind == MarkKind.strong).first.attr,
      'b',
    );
    expect(rebuilt.marks.where((m) => m.kind == MarkKind.em).first.attr, 'i');
    expect(
      rebuilt.marks.where((m) => m.kind == MarkKind.underline).first.attr,
      'u',
    );
  });
}
