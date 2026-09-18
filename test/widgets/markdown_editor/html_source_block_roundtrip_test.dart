import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import '../../helpers/discourse_cook_node.dart';

// 全部正文与上传标识均为独立模拟数据。
const _video =
    '<video controls>\n  <source src="https://example.invalid/mock-video.mp4">\n</video>';
const _image = '![模拟图片|500x500](upload://mock-image.jpeg)';

void main() {
  final codec = SemanticComposerCodec(
    cook: cookWithNode,
    tokenize: parseWithNode,
  );
  Future<SemanticEditorSession> open(String raw) async {
    final original = await cookWithNode(raw);
    final result = await codec.import(raw);
    expect(result.failure, isNull);
    expect(await cookWithNode(raw), original, reason: '编辑 token 解析不能污染阅读 cook');
    final session = SemanticEditorSession(result.document!);
    addTearDown(session.dispose);
    expect(await cookWithNode(codec.export(session.tree)), original);
    return session;
  }

  test('相似占位文本和 HTML 实体不会误消费源码', () async {
    const raw =
        '```\nfluxdo_html_source_0\nfluxdo&#95;html_source_0\n```\n\n$_video';
    final session = await open(raw);
    expect(
      session.tree.content
          .where((n) => n.type == 'html_block')
          .single
          .textContent,
      _video,
    );
    expect(
      session.tree.content
          .where((n) => n.type == 'code_block')
          .single
          .textContent,
      'fluxdo_html_source_0\nfluxdo&#95;html_source_0',
    );
  });

  test('标准 Markdown 图片和视频不变成 HTML 源码块', () async {
    final session = await open(
      '$_image\n\n![模拟视频|video](upload://mock-playable.mp4)',
    );
    expect(
      session.tree.content.where(
        (n) => n.type == 'html_block' || n.type == 'code_block',
      ),
      isEmpty,
    );
    final image = session.tree.content.first.content.single;
    expect(image.type, 'image');
    expect(image.attrs['src'], 'upload://mock-image.jpeg');
  });

  test('语义 HTML 导入不影响阅读普通代码标记', () async {
    final session = await open(_video);
    expect(session.tree.content.single.type, 'html_block');
    final parser = ParagraphParser();
    final readingNodes = parser.parse('<pre><code>mock_key</code></pre>');
    expect((readingNodes.single as CodeBlockNode).rawHtml, isFalse);
    expect((readingNodes.single as CodeBlockNode).code, 'mock_key');
  });

  test('完整模拟帖的两个 video 与紧跟图片保持 HTML 源码及门禁等价', () async {
    const raw =
        '''模拟开场

[grid]
![模拟网格甲|120x120](upload://mock-grid-a.jpeg)
![模拟网格乙|120x120](upload://mock-grid-b.jpeg)
[/grid]

[details="模拟折叠"]
模拟折叠正文
[/details]

[quote="mock_author, post:1, topic:42"]
模拟引用正文
[/quote]

$_video

$_video
$_image''';
    final session = await open(raw);
    final sources = session.tree.content
        .where((n) => n.type == 'html_block')
        .map((n) => n.textContent);
    expect(sources.length, 2);
    expect(sources, contains('$_video\n$_image'));
    expect(codec.export(session.tree), contains('$_video\n$_image'));
  });

  test('围栏内相似源码不误识别，独立合法图片仍为图片', () async {
    final session = await open(
      '```html\n$_video\n$_image\n```\n\n$_video\n\n$_image',
    );
    expect(session.tree.content.where((n) => n.type == 'html_block').length, 1);
    expect(
      session.tree.content
          .where((n) => n.type == 'code_block')
          .single
          .textContent,
      '$_video\n$_image',
    );
    expect(session.tree.content.last.content.single.type, 'image');
  });

  test('HTML 源码节点编辑后直接导出，无围栏或实体转义', () async {
    final session = await open('$_video\n$_image');
    final island = session.editor.blocks.whereType<IslandBlock>().single;
    final node = island.node as CodeBlockNode;
    session.editor.updateIslandNode(
      island.id,
      CodeBlockNode(
        id: node.id,
        code: node.code.replaceAll('mock-video', 'mock-edited'),
        language: node.language,
        rawHtml: node.rawHtml,
      ),
    );
    final back = codec.export(session.tree);
    expect(back, contains('mock-edited.mp4'));
    expect(back, isNot(contains('```')));
    expect(back, isNot(contains('&lt;')));
    final reimported = await open(back);
    expect(reimported.tree.content.single.type, 'html_block');
    expect(
      reimported.tree.content.single.textContent,
      contains('mock-edited.mp4'),
    );
  });
}
