/// `[color]` / `[bgcolor]` 的 cook 后置转换测试。
///
/// 背景:着色 BBCode 属 discourse-bbcode-color 插件,不在 cook bundle 里,
/// cook 把它原样当文字吐回;而消毒器会剥 span 上的 style,所以只能在
/// cook **之后**补 span(那时消毒器已跑完)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';

String f(String s) => DiscourseCookService.applyBbcodeColor(s);

void main() {
  group('基本转换', () {
    test('[color=#hex] → span color', () {
      expect(f('<p>[color=#FF0000]红[/color]</p>'),
          '<p><span style="color:#FF0000">红</span></p>');
    });

    test('[bgcolor] → span background-color', () {
      expect(f('<p>[bgcolor=#0f0]底[/bgcolor]</p>'),
          '<p><span style="background-color:#0f0">底</span></p>');
    });

    test('三位简写与 CSS 颜色名都认', () {
      expect(f('[color=#f00]a[/color]'),
          '<span style="color:#f00">a</span>');
      expect(f('[color=red]a[/color]'),
          '<span style="color:red">a</span>');
    });

    test('大小写不敏感', () {
      expect(f('[COLOR=#FF0000]红[/COLOR]'),
          '<span style="color:#FF0000">红</span>');
    });
  });

  // 之前这里只测了"我以为的"cook 输出(`[color=#FF0000]` 原样),漏掉了
  // 真实形态:`#FF0000` 长得像话题标签,cook 会把它包成 hashtag-raw span。
  // 结果带 `#` 的十六进制颜色全部判非法、一个都不渲染,而 `[color=red]`
  // 正常 —— 测试用例选得不好就是会漏掉真 bug。
  group('cook 的 hashtag 特性把颜色值包了标签', () {
    test('#RRGGBB 被包成 hashtag-raw span 后仍能识别', () {
      expect(
        f('<p>[color=<span class="hashtag-raw">#FF0000</span>]a[/color]</p>'),
        '<p><span style="color:#FF0000">a</span></p>',
      );
    });

    test('bgcolor 同理', () {
      expect(
        f('<p>[bgcolor=<span class="hashtag-raw">#0f0</span>]b[/bgcolor]</p>'),
        '<p><span style="background-color:#0f0">b</span></p>',
      );
    });

    test('剥完标签仍非法的照样不转', () {
      const raw = '[color=<span class="hashtag-raw">#xyz</span>]a[/color]';
      expect(f(raw), raw);
    });
  });

  group('嵌套与多处', () {
    test('bgcolor 套 color 由内向外展开', () {
      expect(
        f('[bgcolor=#000][color=#fff]白字黑底[/color][/bgcolor]'),
        '<span style="background-color:#000">'
        '<span style="color:#fff">白字黑底</span></span>',
      );
    });

    test('同一段里多处各自转换', () {
      expect(
        f('[color=red]甲[/color]与[color=blue]乙[/color]'),
        '<span style="color:red">甲</span>与'
        '<span style="color:blue">乙</span>',
      );
    });

    test('内容里的 HTML 标签保留', () {
      expect(f('[color=red]<strong>粗</strong>[/color]'),
          '<span style="color:red"><strong>粗</strong></span>');
    });
  });

  group('不该动的情况', () {
    test('颜色值非法 → 原样留着', () {
      for (final raw in [
        '[color=不是颜色]x[/color]',
        '[color=url(javascript:alert(1))]x[/color]',
        '[color=expression(alert(1))]x[/color]',
        '[color=#12345]x[/color]', // 位数不对
      ]) {
        expect(f(raw), raw, reason: raw);
      }
    });

    test('未闭合 / 标签不配对 → 原样留着', () {
      expect(f('[color=red]没闭合'), '[color=red]没闭合');
      expect(f('[color=red]x[/bgcolor]'), '[color=red]x[/bgcolor]');
    });

    test('不含 BBCode 的 HTML 原样返回', () {
      const html = '<p>普通段落<a href="/x">链接</a></p>';
      expect(f(html), html);
    });

    test('空内容也能转(不崩)', () {
      expect(f('[color=red][/color]'), '<span style="color:red"></span>');
    });
  });
}
