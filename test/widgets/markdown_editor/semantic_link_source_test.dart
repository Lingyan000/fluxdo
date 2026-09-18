import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/semantic_editor.dart';

import '../../helpers/discourse_cook_node.dart';

void main() {
  final codec = SemanticComposerCodec(
    cook: cookWithNode,
    tokenize: parseWithNode,
  );

  for (final encoded in ['%FF', 'a%C2%A0b', 'a%E2%80%A8b']) {
    test('自动链接的 IR 不保存有损或分隔符解码：$encoded', () async {
      final url = 'https://example.com/$encoded';
      final raw = '前 $url 后';
      final result = await codec.import(raw);
      expect(result.failure, isNull);
      final session = SemanticEditorSession(result.document!);
      addTearDown(session.dispose);
      final link = session.tree.content.single.content.singleWhere(
        (node) => node.marks.any((mark) => mark.type == 'link'),
      );
      expect(link.text, url);
      expect(link.marks.single.attrs['href'], url);
      expect(link.marks.single.attrs['markup'], 'linkify');
      expect(codec.export(session.tree), raw);
      expect(
        await cookWithNode(codec.export(session.tree)),
        await cookWithNode(raw),
      );
    });
  }

  for (final source in {
    '[https://example.com](https://example.com)': null,
    '<https://example.com>': 'autolink',
    'https://example.com': 'linkify',
  }.entries) {
    test('同名链接 IR 保留来源且不互换语法：${source.key}', () async {
      final result = await codec.import(source.key);
      expect(result.failure, isNull);
      final session = SemanticEditorSession(result.document!);
      addTearDown(session.dispose);
      final link = session.tree.content.single.content.single;
      expect(link.marks.single.attrs['markup'], source.value);
      expect(codec.export(session.tree), source.key);
    });
  }
}
