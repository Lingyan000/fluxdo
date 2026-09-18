import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ImageRun;
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

import 'composer_token_codec_test.dart' show parseWithNode, cookWithNode;

void main() {
  final codec = SemanticComposerCodec(
    cook: cookWithNode,
    tokenize: parseWithNode,
  );
  for (final raw in [
    '[date=2026-05-01 time=12:30:00 timezone="Asia/Shanghai"]',
    '[date-range from=2026-05-01T12:30:00 to=2026-05-02T13:30:00 timezone="Asia/Shanghai"]',
    '[date=2026-05-01 timezone="UTC" displayedTimezone="Asia/Shanghai" countdown="true"]',
    '[b]模拟粗体[/b] [i]模拟斜体[/i]',
    '**[date=2026-05-01 timezone="UTC"]**',
    '**@mock_user**',
    '-\n- 文本',
    '[details=""]\n[/details]',
    '[details]\n[/details]',
    ':smile: @mock_user 文字',
    '前 :smile: ![模拟图|640x480, 50%](upload://mock.jpeg) @mock_user 后',
  ]) {
    test('正式扩展严格门禁 $raw', () async {
      final result = await codec.import(
        raw,
        timeout: const Duration(seconds: 20),
      );
      expect(result.failure, isNull);
      final session = SemanticEditorSession(result.document!);
      addTearDown(session.dispose);
      expect(
        await cookWithNode(codec.export(session.tree)),
        await cookWithNode(raw),
      );
      final text = session.editor.blocks.whereType<TextBlock>().firstOrNull;
      expect(text, isNotNull);
      final before = session.tree;
      session.editor.imeReplace(text!.id, 0, 0, '模拟新增 ', caretOffset: 5);
      final edited = codec.export(session.tree);
      expect(edited, contains('模拟新增'));
      expect(
        (await codec.import(
          edited,
          timeout: const Duration(seconds: 20),
        )).failure,
        isNull,
      );
      session.editor.undo();
      expect(session.tree, same(before));
      final image = text.content.atoms.entries
          .where((e) => e.value is ImageRun)
          .firstOrNull;
      if (image != null) {
        session.editor.replaceAtomAt(
          text.id,
          image.key,
          (image.value as ImageRun).copyWith(alt: '模拟修改图片'),
        );
        final changed = codec.export(session.tree);
        expect(changed, contains('模拟修改图片'));
        expect(
          (await codec.import(
            changed,
            timeout: const Duration(seconds: 20),
          )).failure,
          isNull,
        );
        session.editor.undo();
        expect(session.tree, same(before));
      }
    });
  }
}
