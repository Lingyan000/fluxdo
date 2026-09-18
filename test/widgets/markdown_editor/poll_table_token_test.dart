import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:html/parser.dart' as html;
import 'package:fluxdo_render/src/editor/widget/editor_table_grid.dart';

import '../../helpers/discourse_cook_node.dart';
import 'composer_token_codec_test.dart' show fullMockRaw;

final codec = SemanticComposerCodec(
  cook: cookWithNode,
  tokenize: parseWithNode,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实投票 token 多轮保留结构、原文及编辑结果', () async {
    var raw =
        '[poll type=regular dynamic=true order=random]\n# 模拟 **标题**\n* 模拟甲 & <测试>\n* 模拟乙\n[/poll]';
    for (var round = 0; round < 3; round++) {
      final imported = await codec.import(raw);
      expect(imported.failure, isNull);
      expect(imported.document!.content.single.type, 'poll');
      final session = SemanticEditorSession(imported.document!);
      addTearDown(session.dispose);
      final island = session.editor.blocks.whereType<IslandBlock>().single;
      final poll = island.node as PollNode;
      final dom = html.parseFragment(poll.rawHtml);
      expect(dom.querySelectorAll('li[data-poll-option-id]'), hasLength(2));
      expect(dom.querySelector('.poll-title strong')?.text, '标题');
      expect(codec.export(session.exportTree()).trim(), raw.trim());
      final edited = PollNode(
        id: poll.id,
        pollName: poll.pollName,
        title: poll.title,
        rawHtml: poll.rawHtml.replaceAll('模拟乙', '模拟已编辑'),
        rawMarkdown: poll.rawMarkdown,
        rawMarkdownSignature: poll.rawMarkdownSignature,
      );
      session.editor.updateIslandNode(island.id, edited);
      final next = codec.export(session.exportTree());
      expect((await codec.import(next)).failure, isNull);
      expect(next, contains('模拟已编辑'));
      expect(next, contains('dynamic=true'));
      expect(next, contains('order=random'));
      expect(await cookWithNode(next), contains('模拟已编辑'));
      raw = next;
    }
  });

  test('对齐表格 token 多轮及网格编辑保持 separator', () async {
    var raw = '| 模拟左 | 模拟中 | 模拟右 |\n| :--- | :---: | ---: |\n| 甲 | 乙 | 丙 |';
    for (var round = 0; round < 3; round++) {
      final imported = await codec.import(raw);
      expect(imported.failure, isNull);
      final table =
          SemanticEditorProjection.project(imported.document!).blocks
                  .whereType<IslandBlock>()
                  .single
                  .node
              as TableNode;
      final alignments = table.rows.first.map((c) => c.alignment).toList();
      expect(alignments, [TextAlign.left, TextAlign.center, TextAlign.right]);
      expect(
        codec.export(imported.document!),
        contains('| :--- | :---: | ---: |'),
      );
      final cells = table.rows
          .map((r) => r.map(tableCellToMarkdown).toList())
          .toList();
      cells[1][1] = '模拟编辑$round';
      raw = tableGridToMarkdown(cells, alignments: alignments);
      expect(raw, contains('模拟编辑$round'));
      expect(raw, contains('| :--- | :---: | ---: |'));
    }
  });

  test('全模拟媒体正文叠加投票和对齐表格通过真实严格门禁三轮', () async {
    var raw =
        '${fullMockRaw.replaceFirst('| --- | --- |', '| :---: | ---: |')}\n\n[poll]\n# 模拟投票\n* 模拟甲\n* 模拟乙\n[/poll]';
    final pipeline = codec;
    for (var round = 0; round < 3; round++) {
      final result = await pipeline.import(
        raw,
        guarded: true,
        timeout: const Duration(seconds: 20),
      );
      expect(result.failure, isNull);
      final nodes = SemanticEditorProjection.project(result.document!).blocks
          .whereType<IslandBlock>()
          .map((b) => b.node);
      expect(nodes.whereType<PollNode>(), hasLength(1));
      expect(
        nodes.whereType<TableNode>().single.rows.first.first.alignment,
        TextAlign.center,
      );
      raw = codec.export(result.document!);
    }
  });

  testWidgets('对齐单元格实际输入提交不丢列对齐', (tester) async {
    const node = TableNode(
      id: '模拟表',
      columnCount: 1,
      hasHeader: true,
      rows: [
        [
          TableCellData(
            isHeader: true,
            alignment: TextAlign.right,
            children: [
              ParagraphNode(id: '模拟头', inlines: [TextRun('模拟表头')]),
            ],
          ),
        ],
        [
          TableCellData(
            alignment: TextAlign.right,
            children: [
              ParagraphNode(id: '模拟格', inlines: [TextRun('模拟值')]),
            ],
          ),
        ],
      ],
    );
    String? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorTableGrid(
            node: node,
            onChanged: (value) => changed = value,
          ),
        ),
      ),
    );
    await tester.tap(find.text('模拟值'));
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).textAlign,
      TextAlign.right,
    );
    await tester.enterText(find.byType(TextField), '模拟新值');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(changed, contains('| ---: |'));
    expect(changed, contains('模拟新值'));
  });

  test('未知投票 token 不静默忽略', () async {
    const raw = '[poll]\n* 模拟甲\n* 模拟乙\n[/poll]';
    final dto = await parseWithNode(raw);
    final tokens = dto['tokens'] as List;
    final text = tokens.firstWhere((t) => t['type'] == 'inline');
    text['children'] = [
      {'type': 'unknown_mock', 'nesting': 0},
    ];
    final imported = await SemanticComposerCodec(
      cook: cookWithNode,
      tokenize: (_) => dto,
    ).import(raw);
    expect(imported.failure, isNotNull);
  });
}
