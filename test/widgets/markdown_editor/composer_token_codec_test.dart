import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';

import '../../helpers/discourse_cook_node.dart';
export '../../helpers/discourse_cook_node.dart';

final codec = SemanticComposerCodec(
  cook: cookWithNode,
  tokenize: parseWithNode,
);

const fullMockRaw = '模拟正文首行  \n'
    '''[https://github.com](https://github.com)

[grid]
![模拟图片一|1254x1254](upload://mockGridA.png)
![模拟图片二|1200x2608](upload://mockGridB.png)
![模拟图片三|1200x2608, 50%](upload://mockGridC.png)
![模拟图片四|1200x2608](upload://mockGridD.png)
![模拟图片一|1254x1254](upload://mockGridA.png)
![模拟图片六|500x500](upload://mockGridF.png)
[/grid]

[details="模拟折叠摘要"]
模拟折叠第一段。


模拟折叠第二段。

模拟折叠第三段。
[/details]

> 模拟引用第一段。
>
> 模拟引用第二段。
>
> 模拟引用第三段。

<video width="640" height="360" controls>
  <source src="/uploads/short-url/mock.xz" type="video/mp4">
</video>

<video width="640" height="360" controls>
  <source src="/uploads/short-url/mockOther.xz" type="video/mp4">
</video>

![模拟图片六|500x500](upload://mockGridF.png)

| 模拟表头甲 | 模拟表头乙 |
| --- | --- |
| 模拟单元格甲 | 模拟单元格乙 |
| 模拟单元格丙 | 模拟单元格丁 |''';

String firstDifference(String before, String after) {
  var index = 0;
  while (index < before.length &&
      index < after.length &&
      before.codeUnitAt(index) == after.codeUnitAt(index)) {
    index++;
  }
  if (index == before.length && index == after.length) return '无差异';
  final start = index > 100 ? index - 100 : 0;
  String context(String value) => value.substring(
    start < value.length ? start : value.length,
    index + 200 < value.length ? index + 200 : value.length,
  );
  return '首差异偏移 $index\n原始：${context(before)}\n往返：${context(after)}';
}

void main() {
  for (final raw in [
    '>',
    '> ',
    '>\n',
    '> >',
    '模拟正文\n\n>',
    '$fullMockRaw\n\n>',
  ]) {
    test('空引用保留为带容器的文本块：${raw.length}', () async {
      final imported = await codec.import(raw);
      expect(imported.failure, isNull);
      final quotes = SemanticEditorProjection.project(imported.document!).blocks
          .whereType<TextBlock>()
          .where(
            (block) => block.containers.any((frame) => frame is QuoteFrame),
          );
      expect(quotes, isNotEmpty);
      expect(
        await cookWithNode(codec.export(imported.document!)),
        await cookWithNode(raw),
      );
    });
  }
  for (final fixture in <String, String>{
    '普通表格': fullMockRaw,
    '转义表格': fullMockRaw.replaceFirst('模拟单元格甲', r'模拟甲\|模拟乙'),
    '对齐表格': fullMockRaw.replaceFirst('| --- | --- |', '| :--- | ---: |'),
  }.entries) {
    test('完整模拟正文经真实 token parse 与严格门禁连续三轮往返：${fixture.key}', () async {
      final original = await cookWithNode(fixture.value);
      var current = fixture.value;
      for (var round = 0; round < 3; round++) {
        final parsed = await codec.import(current);
        expect(parsed.failure, isNull);
        final tree = parsed.document!;
        expect(tree, isA<SemanticNode>());
        final document = SemanticEditorProjection.project(tree).blocks;
        final islands = document
            .whereType<IslandBlock>()
            .map((b) => b.node)
            .toList();
        final grid = islands.whereType<ImageGridNode>().single;
        expect(grid.images, hasLength(6));
        expect(grid.images[0].src, grid.images[4].src);
        expect(grid.images[2].origWidth, 1200);
        expect(grid.images[2].origHeight, 2608);
        expect(grid.images[2].scale, 50);
        expect(islands.whereType<VideoNode>(), hasLength(2));
        expect(document.whereType<TextBlock>().length, greaterThanOrEqualTo(7));
        if (fixture.key != '对齐表格') {
          final table = islands.whereType<TableNode>().single;
          expect(table.columnCount, 2);
          expect(table.rows, hasLength(3));
        }
        final back = codec.export(tree);
        final cookedBack = await cookWithNode(back);
        final diagnostic =
            '${firstDifference(original, cookedBack)}\n'
            '模型：${document.join(', ')}\n'
            '序列化：$back';
        final pipeline = codec;
        final imported = await pipeline.import(
          current,
          timeout: const Duration(seconds: 20),
          guarded: true,
        );
        expect(imported.failure, isNull, reason: diagnostic);
        expect(cookedBack, original, reason: diagnostic);
        current = codec.export(imported.document!);
      }
    });
  }
  for (final raw in [
    '# 模拟标题\n\n**粗体** 与 [同名](https://mock.example.com)',
    '[https://mock.example.com](https://mock.example.com)',
    '前 https://mock.example.com 后',
    '![模拟图|640x480, 50%](upload://mock.png)',
    '3. 模拟项\n4. 第二项',
    '[details="模拟摘要"]\n正文\n[/details]',
    '[quote="mock_user, post:2, topic:42"]\n模拟引用\n[/quote]',
    '[spoiler]模拟隐藏[/spoiler]',
    '[date=2027-03-12 time=09:30:00 timezone="Asia/Shanghai"]',
    '|甲|乙|\n|-|-|\n|1|2|',
    '[grid mode=carousel]\n![甲](upload://mock.png)\n[/grid]',
    '[x] 完成',
    '> [!note] 标题\n> 正文',
    '[grid]\n```text\nmock\n```\n[/grid]',
    '[color=red]红[/color] [size=150]大[/size]',
    r'$x$',
    '[poll]\n* mock甲\n* mock乙\n[/poll]',
    '![|video](upload://mock.mp4)',
    '![|audio](upload://mock.mp3)',
    '软换行\n下一行',
    '<small>模拟</small> 与 **粗体**',
    '```text\n  模拟代码  \n\n```',
  ]) {
    test('真实 token 入口连续三轮往返：$raw', () async {
      final original = await cookWithNode(raw);
      var current = raw;
      for (var i = 0; i < 3; i++) {
        final pipeline = codec;
        final imported = await pipeline.import(
          current,
          timeout: const Duration(seconds: 20),
          guarded: true,
        );
        expect(imported.failure, isNull);
        current = codec.export(imported.document!);
        expect(await cookWithNode(current), original);
      }
    });
  }
}
