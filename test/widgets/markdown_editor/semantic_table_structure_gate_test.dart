import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show TableNode, TableCellData, ParagraphNode;
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

import 'composer_token_codec_test.dart' show parseWithNode, cookWithNode;

void main() {
  test('表格来源结构操作通过正式 codec 严格门禁和撤销', () async {
    final codec = SemanticComposerCodec(
      cook: cookWithNode,
      tokenize: parseWithNode,
    );
    const raw = '| 甲 | 乙 |\n| ---: | :---: |\n| 重复 | 重复 |';
    final imported = await codec.import(
      raw,
      timeout: const Duration(seconds: 20),
    );
    expect(imported.failure, isNull);
    final s = SemanticEditorSession(imported.document!);
    addTearDown(s.dispose);
    final before = s.tree;
    final block = s.editor.blocks.whereType<IslandBlock>().single;
    final old = block.node as TableNode;
    s.editor.updateIslandNode(
      block.id,
      TableNode(
        id: old.id,
        columnCount: 3,
        hasHeader: old.hasHeader,
        rowSourceIds: [...old.rowSourceIds, null],
        rows: [
          for (final row in old.rows)
            [
              ...row,
              TableCellData(
                isHeader: row.every((c) => c.isHeader),
                children: [ParagraphNode(id: '新增格', inlines: const [])],
              ),
            ],
          List.generate(
            3,
            (_) => TableCellData(
              children: [ParagraphNode(id: '新增行', inlines: const [])],
            ),
          ),
        ],
      ),
    );
    final output = codec.export(s.tree);
    final result = await codec.import(
      output,
      timeout: const Duration(seconds: 20),
    );
    expect(result.failure, isNull);
    final restored = SemanticEditorSession(result.document!);
    addTearDown(restored.dispose);
    final table =
        restored.editor.blocks.whereType<IslandBlock>().single.node
            as TableNode;
    expect(table.rows.length, 3);
    expect(table.columnCount, 3);
    expect(table.rows.first.first.alignment, old.rows.first.first.alignment);
    s.editor.undo();
    expect(s.tree.toJson(), before.toJson());
    expect(await cookWithNode(codec.export(s.tree)), await cookWithNode(raw));
  });
}
