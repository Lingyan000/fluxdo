import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/composer_doc_codec.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

/// 用项目自带的真实 cook bundle 验证往返，不依赖移动端 JS 平台通道。
Future<String> cookWithNode(String raw) async {
  final result = await Process.run('node', [
    '-e',
    '''
const fs = require('fs');
eval(fs.readFileSync('assets/cook/discourse-cook.js', 'utf8'));
__fluxdoCook.init(JSON.stringify({
  siteSettings: {
    spoiler_enabled: true, enable_emoji: true,
    enable_markdown_linkify: true,
    markdown_linkify_tlds: 'com|net|org|io|dev|me|do',
    traditional_markdown_linebreaks: false,
    max_image_width: 690, max_image_height: 500
  },
  site: {categories: [], hashtag_configurations: {}},
  customEmoji: [], baseUri: 'https://example.com'
}));
process.stdout.write(__fluxdoCook.cook(JSON.parse(process.argv[1])));
''',
    jsonEncode(raw),
  ]);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
  return result.stdout as String;
}

void main() {
  test('连续导入、点击展开、停留导出三次不增加链接层数', () async {
    const raw = '[https://github.com](https://github.com)';
    final original = await cookWithNode(raw);
    var cooked = original;
    for (var round = 0; round < 3; round++) {
      var n = 0;
      final editor = EditorState(
        blocks: blockNodesToDoc(
          ParagraphParser().parse(cooked),
          () => 'e_${n++}',
        ),
      )..mode = EditorMode.ir;
      try {
        editor.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: editor.blocks.first.id, offset: 4),
          ),
        );
        final exported = editor.exportMarkdown();
        expect(exported, raw, reason: '第 $round 次展开态回写');
        cooked = await cookWithNode(exported);
        expect(cooked, original);
      } finally {
        editor.dispose();
      }
    }
  });

  test('链接停留在 IR 展开态时回写不能变成转义正文', () async {
    const raw = '[https://github.com](https://github.com)';
    final original = await cookWithNode(raw);
    var n = 0;
    final editor = EditorState(
      blocks: blockNodesToDoc(
        ParagraphParser().parse(original),
        () => 'e_${n++}',
      ),
    )..mode = EditorMode.ir;
    addTearDown(editor.dispose);
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 3),
      ),
    );
    expect((editor.blocks.first as TextBlock).content.text, raw);
    // 宿主自动镜像时光标仍在链接内，必须使用模式感知的只读导出。
    final back = editor.exportMarkdown();
    expect(await cookWithNode(back), original, reason: '展开态回写：$back');
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
        var n = 0;
        final doc = blockNodesToDoc(
          ParagraphParser().parse(original),
          () => 'e_${n++}',
        );
        final back = docToRaw(doc);
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
    '就经常闹惨惨惨餐桌参  \n'
        '[https://github.com](https://github.com)\n\n'
        '![14973.jpg|1200x2608, 50%]'
        '(upload://2zEn0OmOJIlgAfDmxF48u4rvXrH.jpeg)\n\n你好',
    '[https://example.com/中文](https://example.com/%E4%B8%AD%E6%96%87)',
    r'[https://github.com/\\](https://github.com/%5C)',
    'https://github.com',
    '![14973.jpg|1200x2608, 50%]'
        '(upload://2zEn0OmOJIlgAfDmxF48u4rvXrH.jpeg)',
  ]) {
    test('真实 cook 连续三次往返：$raw', () async {
      final original = await cookWithNode(raw);
      var cooked = original;
      for (var round = 0; round < 3; round++) {
        var n = 0;
        final doc = blockNodesToDoc(
          ParagraphParser().parse(cooked),
          () => 'e_${n++}',
        );
        final back = docToRaw(doc);
        cooked = await cookWithNode(back);
        expect(cooked, original, reason: '第 $round 次序列化结果：$back');
      }
    });
  }

  test('反斜杠链接与上传缩放图片往返保持 cooked 等价', () async {
    const raw =
        '就经常闹惨惨惨餐桌参  \n'
        r'[https://github.com/\](https://github.com)'
        '\n\n![14973.jpg|1200x2608, 50%]'
        '(upload://2zEn0OmOJIlgAfDmxF48u4rvXrH.jpeg)\n\n你好';
    final original = await cookWithNode(raw);
    var n = 0;
    final doc = blockNodesToDoc(
      ParagraphParser().parse(original),
      () => 'e_${n++}',
    );
    final back = docToRaw(doc);
    final cookedBack = await cookWithNode(back);
    expect(cookedBack, original, reason: '序列化结果：$back');
  });
}
