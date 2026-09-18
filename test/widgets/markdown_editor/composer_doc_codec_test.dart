import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo_render/editor.dart';

import '../../helpers/discourse_cook_node.dart';

void main() {
  final codec = SemanticComposerCodec(
    cook: cookWithNode,
    tokenize: parseWithNode,
  );
  Future<SemanticEditorSession> open(String raw) async {
    final result = await codec.import(raw);
    expect(result.failure, isNull);
    return SemanticEditorSession(result.document!);
  }

  test('连续导入、IR展开链接、停留导出三次不增加链接层数', () async {
    const raw = '[https://github.com](https://github.com)';
    final original = await cookWithNode(raw);
    var current = raw;
    for (var round = 0; round < 3; round++) {
      final session = await open(current);
      final editor = session.editor..mode = EditorMode.ir;
      try {
        editor.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: editor.blocks.first.id, offset: 4),
          ),
        );
        final exported = codec.export(session.tree);
        expect(exported, raw, reason: '第 $round 次展开态回写');
        current = exported;
        expect(await cookWithNode(exported), original);
      } finally {
        session.dispose();
      }
    }
  });

  test('链接停留在IR展开态时回写不能变成转义正文', () async {
    const raw = '[https://github.com](https://github.com)';
    final original = await cookWithNode(raw);
    final session = await open(raw);
    final editor = session.editor..mode = EditorMode.ir;
    addTearDown(session.dispose);
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 3),
      ),
    );
    expect(
      (editor.blocks.first as TextBlock).content.text,
      raw,
    );
    // 语义宿主光标停在展开的链接内，只读导出不得把链接转义成正文。
    final back = codec.export(session.tree);
    expect(await cookWithNode(back), original, reason: '选择态回写：$back');
  });

  for (final link in [
    '[https://github.com](https://github.com)',
    'https://github.com',
    '[example.com](http://example.com)',
    'example.com',
    '[a@example.com](mailto:a@example.com)',
    'a@example.com',
  ]) {
    for (final raw in [
      link,
      '前 $link 后',
      '前文  \n$link',
      '> $link',
      '- $link',
    ]) {
      test('链接来源与上下文往返：$raw', () async {
        final original = await cookWithNode(raw);
        final session = await open(raw);
        addTearDown(session.dispose);
        final back = codec.export(session.tree);
        expect(await cookWithNode(back), original, reason: back);
      });
    }
  }

  for (final raw in <String>[
    r'[https://github.com/\](https://github.com)',
    r'前 https://example.com/a\b 后',
    '前 https://example.com/中文 后',
    '前 https://example.com/%E4%B8%AD%E6%96%87 后',
    '前 https://example.com/a%20b 后',
    '前 https://example.com/a%2Fb 后',
    '前 https://example.com/%FF 后',
    '前 https://example.com/a%C2%A0b 后',
    '前 https://example.com/a%E2%80%A8b 后',
    '前 https://example.com/%EF%BF%BC 后',
    '前 https://example.com/%E4%B8%AD%E6%96%87%20x 后',
    r'\[https://example.com/path](https://github.com)',
    r'[显示\]括号](https://example.com)',
    r'\[普通文字\](目标)',
    '[GitHub](https://github.com)',
    '[https://github.com](https://github.com)',
    '模拟段落正文  \n'
        '[https://github.com](https://github.com)\n\n'
        '![mock-photo.jpeg|1200x2608, 50%]'
        '(upload://mock-photo.jpeg)\n\n模拟结尾',
    '[https://example.com/中文](https://example.com/%E4%B8%AD%E6%96%87)',
    r'[https://github.com/\\](https://github.com/%5C)',
    'https://github.com',
    '![mock-photo.jpeg|1200x2608, 50%]'
        '(upload://mock-photo.jpeg)',
  ]) {
    test('真实 cook 连续三次往返：$raw', () async {
      final original = await cookWithNode(raw);
      var current = raw;
      for (var round = 0; round < 3; round++) {
        final session = await open(current);
        addTearDown(session.dispose);
        final back = codec.export(session.tree);
        current = back;
        expect(
          await cookWithNode(back),
          original,
          reason: '第 $round 次序列化结果：$back',
        );
      }
    });
  }

  test('反斜杠链接与上传缩放图片往返保持 cooked 等价', () async {
    const raw =
        '模拟段落正文  \n'
        r'[https://github.com/\](https://github.com)'
        '\n\n![mock-photo.jpeg|1200x2608, 50%]'
        '(upload://mock-photo.jpeg)\n\n模拟结尾';
    final original = await cookWithNode(raw);
    final session = await open(raw);
    addTearDown(session.dispose);
    final back = codec.export(session.tree);
    final cookedBack = await cookWithNode(back);
    expect(cookedBack, original, reason: '序列化结果：$back');
  });
}
