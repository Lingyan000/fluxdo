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
  for (final raw in <String>[
    r'[https://github.com/\](https://github.com)',
    r'前 https://example.com/a\b 后',
    '前 https://example.com/中文 后',
    '前 https://example.com/%E4%B8%AD%E6%96%87 后',
    r'\[https://example.com/path](https://github.com)',
    r'[显示\]括号](https://example.com)',
    r'\[普通文字\](目标)',
    '[GitHub](https://github.com)',
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
