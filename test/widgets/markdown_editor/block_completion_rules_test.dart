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

  group('分割线', () {
    test('--- / *** / ___ 回车都出 hr', () {
      for (final raw in ['---', '***', '___', '----', '*****']) {
        final hit = at([raw]);
        expect(hit, isNotNull, reason: raw);
        expect(hit!.markdown, '---', reason: '统一序列化口径');
        expect(hit.splitAfter, isFalse, reason: '岛承载结构,回车被消耗');
      }
    });

    test('不足三个 / 混写 / 带正文不触发', () {
      expect(at(['--']), isNull);
      expect(at(['**']), isNull);
      expect(at(['-*-']), isNull);
      expect(at(['--- 正文']), isNull);
      expect(at(['正文 ***']), isNull);
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

  group('BBCode', () {
    test('行内:[b] / [i] / [u] / [s] → 只换本段,回车照常换行', () {
      final hit = at(['这是[b]粗字[/b]哦'])!;
      expect(hit.splitAfter, isTrue);
      expect(hit.from, 0);
      expect(at(['[i]斜[/i]']), isNotNull);
      expect(at(['[u]下划线[/u]']), isNotNull);
      expect(at(['[s]删除[/s]']), isNotNull);
    });

    test('行内:[url] / [email] / [img]', () {
      expect(at(['看[url=https://a.b]这里[/url]']), isNotNull);
      expect(at(['[email]a@b.c[/email]']), isNotNull);
      expect(at(['[img]https://a.b/x.png[/img]']), isNotNull);
    });

    // 白名单曾经凭印象写,放进了一堆 cook 引擎不认的标签 —— 检测命中但
    // cook 原样吐回字面量,表现为"回车分了段却没渲染"(实测复现:
    // `[color=#FF0000]a[/color]` 回车后纹丝不动)。这些必须不触发。
    // color/bgcolor/size:由内核 input rules 即打即渲染(打完闭标记当场
    // 转换),不走块完成 —— 这里必须不触发,否则与 input rules 撞车。
    test('[color] / [bgcolor] 由内核 input rules 处理,不触发块完成', () {
      expect(at(['这是[color=#FF0000]红字[/color]哦']), isNull);
      expect(at(['[bgcolor=#fff]底色[/bgcolor]']), isNull);
    });

    test('[size] 由内核 input rules 处理,不触发块完成', () {
      expect(at(['这是[size=150]大字[/size]哦']), isNull);
      expect(at(['[size=0]隐藏[/size]']), isNull);
    });

    test('引擎不支持的 BBCode 一律不触发', () {
      for (final raw in [
        '[font=arial]字体[/font]',
        '[sup]上标[/sup]', // BBCode 形式不认,HTML <sup> 才认
        '[sub]下标[/sub]',
        '[highlight]高亮[/highlight]',
        '[mark]标记[/mark]',
      ]) {
        expect(at([raw]), isNull, reason: raw);
      }
      for (final tag in ['note', 'aside', 'table', 'chat', 'floatl', 'floatr']) {
        expect(at(['[$tag]', '内容', '[/$tag]']), isNull, reason: tag);
        expect(at(['[$tag]内容[/$tag]']), isNull, reason: tag);
      }
    });

    test('[code] / [spoiler] 归块级(cook 出来是 pre / div,不是行内)', () {
      expect(at(['[code]x[/code]'])!.splitAfter, isFalse);
      expect(at(['[spoiler]剧透[/spoiler]'])!.splitAfter, isFalse);
    });

    test('块级:[quote] … [/quote] 跨块回溯,整段变岛', () {
      final hit = at(['[quote]', '引用内容', '[/quote]'])!;
      expect(hit.from, 0);
      expect(hit.to, 2);
      expect(hit.splitAfter, isFalse);
      expect(hit.markdown, '[quote]\n引用内容\n[/quote]');
    });

    test('块级:带参数的开标签也能配上', () {
      expect(at(['[quote="某人, post:1"]', '内容', '[/quote]']), isNotNull);
      expect(at(['[details="标题"]', '内容', '[/details]']), isNotNull);
    });

    test('块级:单行写完也认', () {
      final hit = at(['[quote]短引用[/quote]'])!;
      expect(hit.splitAfter, isFalse);
    });

    test('排除:未闭合 / 非白名单 / 找不到开标签', () {
      expect(at(['[color=#f00]红字']), isNull);
      expect(at(['[nosuchtag]x[/nosuchtag]']), isNull);
      expect(at(['正文', '[/quote]']), isNull);
    });

    test('块级 BBCode 回溯不跨岛', () {
      expect(at(['[quote]', null, '[/quote]']), isNull);
    });
  });

  // 软换行(回车插段内 \n)之后一个块可以含多行,调用方必须把文档展开成
  // **逻辑行**再喂进来。这里锁住"前面有内容的那一行"仍能收尾 ——
  // 实测回归:开了软换行后 `***`/围栏/表格全失灵,就是因为拿整块文本匹配。
  group('多行块(软换行)按行判定', () {
    test('前面有正文行时,末行仍能命中', () {
      expect(at(['上一行', '***'])!.markdown, '---');
      expect(at(['上一行', '```dart'])!.markdown, '```dart\n\n```');
      expect(at(['上一行', '| a | b |']), isNotNull);
    });

    test('命中区间只覆盖那一行', () {
      final hit = at(['上一行', '***'])!;
      expect(hit.from, 1);
      expect(hit.to, 1, reason: '不能把"上一行"一起吞掉');
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
