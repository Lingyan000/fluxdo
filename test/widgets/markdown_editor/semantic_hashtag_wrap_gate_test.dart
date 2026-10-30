import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show LinkRun, TextRun;
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

import 'composer_token_codec_test.dart' show parseWithNode, cookWithNode;

void main() {
  final codec = SemanticComposerCodec(
    tokenize: parseWithNode,
    cook: cookWithNode,
  );

  test('真实 bundle hashtag 可视原子、替换及撤销通过正式门禁', () async {
    const raw = '前 #mock 后';
    final imported = await codec.import(raw);
    expect(imported.failure, isNull);
    final session = SemanticEditorSession(imported.document!);
    addTearDown(session.dispose);
    final block = session.editor.blocks.whereType<TextBlock>().single;
    final atom = block.content.atoms.entries.single;
    expect(atom.value, isA<LinkRun>());
    expect((atom.value as LinkRun).hashtagRef, 'mock');
    expect((atom.value as LinkRun).children, isNotEmpty);
    final before = session.tree;
    session.editor.replaceAtomAt(
      block.id,
      atom.key,
      const LinkRun(
        href: '',
        hashtagRef: 'changed',
        children: [TextRun('#changed')],
      ),
    );
    final edited = codec.export(session.tree);
    expect(edited, contains('#changed'));
    expect(edited, isNot(contains('#mock')));
    expect((await codec.import(edited)).failure, isNull);
    session.editor.undo();
    expect(session.tree, same(before));
    expect(
      await cookWithNode(codec.export(session.tree)),
      await cookWithNode(raw),
    );
  });

  for (final raw in [
    '[wrap data-mock="x"]\n正文\n[/wrap]',
    '前文\n\n[wrap data-mock="x"]\n<kbd>甲 <kbd>乙</kbd> 丙</kbd>\n[/wrap]\n\n后文',
    '> [wrap data-mock="x"]\n> 正文\n> [/wrap]',
    '[details="摘要"]\n[wrap data-mock="x"]\n正文\n[/wrap]\n[/details]',
  ]) {
    test('真实 bundle wrap 可靠来源保原文及嵌套 $raw', () async {
      final imported = await codec.import(raw);
      expect(imported.failure, isNull);
      final exported = codec.export(imported.document!);
      expect(exported, contains('[wrap data-mock="x"]'));
      expect(exported, contains('[/wrap]'));
      expect(await cookWithNode(exported), await cookWithNode(raw));
      expect((await codec.import(exported)).failure, isNull);
    });
  }
}
