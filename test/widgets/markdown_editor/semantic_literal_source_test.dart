import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/semantic_editor.dart';

import '../../helpers/discourse_cook_node.dart';

void main() {
  final codec = SemanticComposerCodec(
    cook: cookWithNode,
    tokenize: parseWithNode,
  );

  test('真实 bundle 字面 BBCode 源通过严格门禁且不添加方括号转义', () async {
    const raw = '[color=red]红[/color] [size=150]大[/size]';
    final dto = await parseWithNode(raw);
    final children = (dto['tokens'] as List)[1]['children'] as List;
    expect(children.single['type'], 'text');
    final result = await codec.import(raw, guarded: true);
    expect(result.failure, isNull);
    expect(codec.export(result.document!), raw);
    expect(
      await cookWithNode(codec.export(result.document!)),
      await cookWithNode(raw),
    );
  });

  test('未知行内 HTML 仍拒绝，整 HTML block 保留源', () async {
    expect((await codec.import('正文 <unknown>文本</unknown>')).failure, isNotNull);
    const raw = '<div><unknown>文本</unknown></div>';
    final result = await codec.import(raw, guarded: true);
    expect(result.failure, isNull);
    expect(result.document!.content.single.type, 'html_block');
    expect(
      await cookWithNode(codec.export(result.document!)),
      await cookWithNode(raw),
    );
  });

  test('字面文本修改后不重放旧源，恢复 Markdown 转义', () {
    final doc = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode(
              'text',
              text: '**新文本**',
              attrs: {'literalSource': '旧文本'},
            ),
          ],
        ),
      ],
    );
    expect(codec.export(doc), r'\*\*新文本\*\*');
  });
}
