/// 块完成规则(回车收尾 → cook)判定测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/block_completion_rules.dart';

BlockCompletion? at(List<String?> texts, [int? index]) =>
    detectBlockCompletion(texts, index ?? texts.length - 1);

void main() {
  group('代码围栏', () {
    test('``` → 空代码块;```dart 带语言', () {
      expect(at(['```'])!.markdown, '```\n\n```');
      expect(at(['```dart'])!.markdown, '```dart\n\n```');
      expect(at(['```c++'])!.markdown, '```c++\n\n```');
      expect(at(['```'])!.splitAfter, isFalse, reason: '岛承载结构,回车被消耗');
    });

    test('围栏后跟正文不触发(不是起始行)', () {
      expect(at(['```dart 一些字']), isNull);
      expect(at(['前面有字 ```']), isNull);
    });
  });

  group('公式与表格', () {
    test(r'$$ → 公式块', () {
      expect(at([r'$$'])!.markdown, r'$$' '\n\n' r'$$');
    });

    test('表头行 → 补分隔行与空数据行', () {
      final hit = at(['| 列1 | 列2 |'])!;
      expect(hit.markdown.split('\n').length, 3);
      expect(hit.markdown.split('\n')[1], '|---|---|');
    });

    test('单根竖线的普通句子不误判', () {
      expect(at(['a | b']), isNull);
      expect(at(['|只有一列|']), isNull);
    });
  });

  group('块级 HTML', () {
    test('</details> 回溯到 <details> 聚合整段', () {
      final texts = ['前文', '<details>', '<summary>标题</summary>', '内容', '</details>'];
      final hit = at(texts)!;
      expect(hit.from, 1);
      expect(hit.to, 4);
      expect(hit.markdown, '<details>\n<summary>标题</summary>\n内容\n</details>');
      expect(hit.splitAfter, isFalse);
    });

    test('带属性的开标签也能配上', () {
      final hit = at(['<div class="x">', '内容', '</div>'])!;
      expect(hit.from, 0);
    });

    test('找不到开标签 / 非白名单标签 → 不触发', () {
      expect(at(['正文', '</details>']), isNull);
      expect(at(['<script>', '</script>']), isNull);
    });

    test('中间夹岛不跨岛聚合', () {
      expect(at(['<details>', null, '</details>']), isNull);
    });
  });

  group('行内 HTML', () {
    test('成对行内标签 → 只换本段且回车照常分段', () {
      final hit = at(['按 <kbd>Ctrl</kbd> 键'])!;
      expect(hit.from, 0);
      expect(hit.to, 0);
      expect(hit.splitAfter, isTrue, reason: '不变岛,回车仍要换行');
      expect(hit.markdown, '按 <kbd>Ctrl</kbd> 键');
    });

    test('未闭合 / 非白名单不触发', () {
      expect(at(['按 <kbd>Ctrl 键']), isNull);
      expect(at(['<blink>x</blink>']), isNull);
    });

    test('hasCompleteInlineHtml 直接判定', () {
      expect(hasCompleteInlineHtml('<sup>1</sup>'), isTrue);
      expect(hasCompleteInlineHtml('<mark>x</mark>'), isTrue);
      expect(hasCompleteInlineHtml('a < b > c'), isFalse);
    });
  });

  group('链接与自闭合标签', () {
    test('<a href> 成对 → 行内渲染,回车照常换行', () {
      final hit = at(['见 <a href="https://a.b">这里</a>'])!;
      expect(hit.splitAfter, isTrue);
      expect(hit.from, 0);
    });

    test('<img> / <br> 自闭合,写出来就算完整', () {
      expect(at(['图 <img src="https://a.b/x.png">'])!.splitAfter, isTrue);
      expect(at(['一行<br>两行'])!.splitAfter, isTrue);
    });

    test('未闭合的 <a> 不触发', () {
      expect(at(['见 <a href="https://a.b">这里']), isNull);
    });
  });

  group('单行写完的块级 HTML', () {
    test('<div>内容</div> → 整段变岛(不 splitAfter)', () {
      final hit = at(['<div class="x">内容</div>'])!;
      expect(hit.splitAfter, isFalse);
      expect(hit.markdown, '<div class="x">内容</div>');
    });

    test('<details> 单行写完也认', () {
      expect(at(['<details><summary>t</summary>c</details>']), isNotNull);
    });

    test('开闭标签不匹配 → 不触发', () {
      expect(at(['<div>内容</section>']), isNull);
    });
  });

  group('边界', () {
    test('空块 / 越界 / 岛块 → null', () {
      expect(at(['']), isNull);
      expect(at(['   ']), isNull);
      expect(detectBlockCompletion(['```'], 5), isNull);
      expect(at([null]), isNull);
    });
  });
}
