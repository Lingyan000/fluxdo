import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/composer_import_pipeline.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/editor.dart';
import 'composer_token_codec_test.dart' show parseWithNode, cookWithNode;

void main() {
  final codec = SemanticComposerCodec(cook: cookWithNode, tokenize: parseWithNode);
  for (final raw in [
    '', '>', '> >', '模拟正文\n\n>',
    '前 [模拟链接](https://example.com "模拟标题") 后',
    '第一行\n第二行',
    '* 父项\n\n  3. 子项\n  4. 末项',
    '[details="模拟摘要"]\n模拟内容\n[/details]',
    '![模拟图片|640x480, 50%](upload://mock.jpeg)',
    '<video width="640" height="360" controls>\n'
        '  <source src="/uploads/short-url/mock.xz" type="video/mp4">\n</video>',
    '模拟首段\n\n> 模拟引用\n\n'
        '<video controls>\n<source src="/uploads/mock.mp4" type="video/mp4">\n</video>\n\n'
        '![模拟图|640x480](upload://mock.jpeg)\n\n>',
  ]) {
    test('语义正式入口完整往返 ${raw.length}: ${raw.split('\n').first}', () async {
      final result = await codec.import(raw, timeout: const Duration(seconds: 20));
      expect(result.failure, isNull);
      final session = SemanticEditorSession(result.document!);
      addTearDown(session.dispose);
      expect(await cookWithNode(codec.export(session.tree)), await cookWithNode(raw));
      if (raw == '第一行\n第二行') {
        expect(session.editor.blocks.whereType<IslandBlock>(), isEmpty);
        expect((session.editor.blocks.single as TextBlock).content.text, raw);
      }
      final block = session.editor.blocks.whereType<TextBlock>().firstOrNull;
      if (block != null && block.content.atoms.isEmpty && block.content.length > 0) {
        final before = session.tree;
        session.editor.imeReplace(block.id, 0, 0, '新增', caretOffset: 2);
        final serialized = codec.export(session.tree);
        expect(serialized, contains('新增'));
        final again = await codec.import(serialized, timeout: const Duration(seconds: 20));
        expect(again.failure, isNull);
        session.editor.undo();
        expect(session.tree, same(before));
      }
    });
  }
  test('正式导出过滤临时节点且替换后撤销不恢复孤儿', () async {
    final result = await codec.import('模拟正文');
    final session = SemanticEditorSession(result.document!);
    addTearDown(session.dispose);
    final token = Object();
    session.insertTransientNodeAtBlock(session.editor.blocks.length, token,
        SemanticNode('pending_upload', attrs: {'mock': '临时'}));
    expect(codec.export(session.exportTree()), '模拟正文');
    session.resolveTransient(token, SemanticNode('paragraph', content: [
      SemanticNode('image', attrs: {'src': 'upload://mock.jpeg', 'alt': '模拟图'}),
    ]));
    final exported = codec.export(session.exportTree());
    expect(exported, contains('upload://mock.jpeg'));
    expect((await codec.import(exported)).failure, isNull);
    session.editor.undo();
    expect(codec.export(session.exportTree()), isNot(contains('临时')));
    session.editor.redo();
    expect(codec.export(session.exportTree()), exported);
  });
  test('不支持的结构保原文失败，不调用旧转换器', () async {
    final unsupported = SemanticComposerCodec(
      cook: (_) => '<p>模拟</p>',
      tokenize: (_) => {'version': 1, 'tokens': [
        {'type': 'unknown_plugin', 'nesting': 0},
      ]},
    );
    final result = await unsupported.import('模拟不支持插件');
    expect(result.failure, ComposerImportFailure.unsupported);
  });
}
