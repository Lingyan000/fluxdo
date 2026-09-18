import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/widget/editor_table_grid.dart';

import 'composer_token_codec_test.dart' show parseWithNode, cookWithNode;

const _raw = '| 甲 | 乙 |\n| ---: | :---: |\n| 原值 | 保留 |';

/// 与生产宿主相同：文本走正式 codec 再局部合并，结构直接更新会话。
/// 手动放行回声，避免依赖真实进程耗时制造竞态。
class _Host {
  final codec = SemanticComposerCodec(
    cook: cookWithNode,
    tokenize: parseWithNode,
  );
  late SemanticEditorSession session;
  String? pending;
  IslandBlock? origin;
  int structures = 0;

  IslandBlock get block =>
      session.editor.blocks.whereType<IslandBlock>().single;
  TableNode get table => block.node as TableNode;

  Future<void> init() async {
    final result = await codec.import(_raw);
    expect(result.failure, isNull);
    // 未知属性进入正式语义来源，而非塞进不承载这些属性的 TableNode。
    SemanticNode decorate(SemanticNode node) => node.copyWith(
      attrs: {...node.attrs, 'data-regression': '来源-${node.type}'},
      content: node.content.map(decorate).toList(),
    );
    session = SemanticEditorSession(decorate(result.document!));
  }

  Widget build() => MaterialApp(
    home: Scaffold(
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) => EditorTableGrid(
          node: table,
          selected: true,
          onChanged: (markdown) {
            pending = markdown;
            origin = block;
          },
          onNodeChanged: (node) {
            structures++;
            session.editor.updateIslandNode(block.id, node);
          },
        ),
      ),
    ),
  );

  Future<void> echo({bool fail = false}) async {
    final result = await codec.import(pending!);
    expect(result.failure, isNull);
    if (fail || !identical(block.node, origin!.node)) return;
    final parsed =
        SemanticEditorProjection.project(result.document!).blocks
                .whereType<IslandBlock>()
                .single
                .node
            as TableNode;
    session.editor.updateIslandNode(
      block.id,
      TableNode(
        id: table.id,
        rows: parsed.rows,
        columnCount: parsed.columnCount,
        hasHeader: parsed.hasHeader,
        textAlign: table.textAlign,
      ),
    );
  }
}

Future<void> _editAndInsert(WidgetTester tester, _Host host) async {
  await tester.tap(find.text('原值'));
  await tester.pump();
  await tester.pump();
  await tester.enterText(find.byType(TextField), '用户新文字');
  expect(
    tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
    isTrue,
  );
  // 不发送 done、不手动失焦：直接点网格的加列入口。
  await tester.tap(find.byTooltip('添加列'));
  await tester.pump();
  expect(host.pending, contains('用户新文字'));
  expect(host.structures, 0, reason: '文本回声之前不能拿旧表做结构操作');
  expect(host.table.columnCount, 2);
}

void main() {
  testWidgets('未失焦编辑后加列：延迟真实 codec 回声保留文字、来源属性、对齐和撤销', (tester) async {
    final host = _Host();
    await tester.runAsync(host.init);
    addTearDown(host.session.dispose);
    final before = host.session.tree.toJson();
    await tester.pumpWidget(host.build());
    await _editAndInsert(tester, host);
    await tester.pump(const Duration(seconds: 1));
    expect(host.structures, 0);
    await tester.runAsync(host.echo);
    final afterText = host.session.tree.toJson();
    await tester.pump();
    await tester.pump();
    expect(host.structures, 1);
    expect(host.table.columnCount, 3);
    expect(tableCellToMarkdown(host.table.rows[1][0]), '用户新文字');
    expect(host.table.rows[0].map((c) => c.alignment), [
      TextAlign.right,
      TextAlign.center,
      null,
    ]);
    expect(host.table.rows[1].map((c) => c.alignment), [
      TextAlign.right,
      TextAlign.center,
      null,
    ]);
    final afterStructure = host.session.tree.toJson();
    // 原有各级来源属性仍在；新列不应复制旧单元格的未知属性。
    final oldTable = host.session.tree.content.single;
    expect(oldTable.attrs['data-regression'], '来源-table');
    void checkOriginal(SemanticNode node) {
      expect(node.attrs['data-regression'], '来源-${node.type}');
      for (final child in node.content) {
        checkOriginal(child);
      }
    }

    final rows = <SemanticNode>[];
    for (final child in oldTable.content) {
      expect(child.attrs['data-regression'], '来源-${child.type}');
      rows.addAll(child.type == 'table_row' ? [child] : child.content);
    }
    for (final row in rows) {
      expect(row.attrs['data-regression'], '来源-table_row');
      for (final cell in row.content.take(2)) {
        checkOriginal(cell);
      }
      expect(row.content.last.attrs['data-regression'], isNull);
    }
    await tester.runAsync(() async {
      final exported = host.codec.export(host.session.tree);
      final imported = await host.codec.import(exported);
      expect(imported.failure, isNull);
      final table =
          SemanticEditorProjection.project(imported.document!).blocks
                  .whereType<IslandBlock>()
                  .single
                  .node
              as TableNode;
      expect(table.columnCount, 3);
      expect(tableCellToMarkdown(table.rows[1][0]), '用户新文字');
      expect(table.rows.first[0].alignment, TextAlign.right);
      expect(table.rows.first[1].alignment, TextAlign.center);
    });
    host.session.editor.undo();
    expect(host.session.tree.toJson(), afterText);
    expect(tableCellToMarkdown(host.table.rows[1][0]), '用户新文字');
    host.session.editor.undo();
    expect(host.session.tree.toJson(), before);
    host.session.editor.redo();
    host.session.editor.redo();
    expect(host.session.tree.toJson(), afterStructure);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fail in [false, true]) {
    testWidgets('${fail ? "回声失败后" : "回声到达前"}外部替换不把待执行加列套到新表', (tester) async {
      final host = _Host();
      await tester.runAsync(host.init);
      addTearDown(host.session.dispose);
      await tester.pumpWidget(host.build());
      await _editAndInsert(tester, host);
      if (fail) {
        await tester.runAsync(() => host.echo(fail: true));
        await tester.pump(const Duration(seconds: 1));
        expect(host.structures, 0);
      }
      // 外部更新同一岛，不能只测换 key / 销毁 widget 的平凡清理。
      await tester.runAsync(() async {
        final result = await host.codec.import('| 外部 |\n| :--- |\n| 新表 |');
        expect(result.failure, isNull);
        final table =
            SemanticEditorProjection.project(result.document!).blocks
                    .whereType<IslandBlock>()
                    .single
                    .node
                as TableNode;
        host.session.editor.updateIslandNode(host.block.id, table);
      });
      final replacement = host.session.tree.toJson();
      await tester.pump();
      await tester.runAsync(host.echo);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(host.structures, 0);
      expect(host.session.tree.toJson(), replacement);
      expect(host.table.columnCount, 1);
      expect(find.text('新表'), findsOneWidget);
      // 新表的操作也不能继续被旧 pending echo 卡住。
      await tester.tap(find.byTooltip('添加列'));
      await tester.pump();
      expect(host.structures, 1);
      expect(host.table.columnCount, 2);
      expect(tableCellToMarkdown(host.table.rows[1][0]), '新表');
      host.session.editor.undo();
      expect(host.session.tree.toJson(), replacement);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
