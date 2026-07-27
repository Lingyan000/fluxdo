/// lib/utils/html_to_markdown.dart(Discourse cooked → markdown)引用与
/// 图片短链行为验证:aside.quote 头部格式、data-display-name 消费、
/// 客户端 cook 预览形态的 data-orig-src 回退。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/html_to_markdown.dart';

void main() {
  group('aside.quote 头部', () {
    test('无 data-display-name:老格式,首字段 username,无 username: 参数', () {
      final md = HtmlToMarkdown.convert(
        '<aside class="quote no-group" data-username="sam" data-post="3" data-topic="42">'
        '<div class="title"><div class="quote-controls"></div> sam:</div>'
        '<blockquote><p>被引内容</p></blockquote></aside>',
      );
      expect(md, contains('[quote="sam, post:3, topic:42"]'));
      expect(md, isNot(contains('username:')));
      expect(md, contains('被引内容'));
    });

    test('带 data-display-name:首字段显示名 + username: 参数', () {
      final md = HtmlToMarkdown.convert(
        '<aside class="quote no-group" data-username="sam" '
        'data-display-name="张三" data-post="3" data-topic="42">'
        '<div class="title"><div class="quote-controls"></div> 张三:</div>'
        '<blockquote><p>被引内容</p></blockquote></aside>',
      );
      expect(md, contains('[quote="张三, post:3, topic:42, username:sam"]'));
    });

    test('跨主题引用:标题栏 <a> 里是话题标题,不得被当成显示名', () {
      final md = HtmlToMarkdown.convert(
        '<aside class="quote" data-username="sam" data-post="3" data-topic="42">'
        '<div class="title"><div class="quote-controls"></div>'
        '<a href="https://x.test/t/some-topic/42/3">某话题标题</a></div>'
        '<blockquote><p>被引内容</p></blockquote></aside>',
      );
      expect(md, contains('[quote="sam, post:3, topic:42"]'));
      expect(md, isNot(contains('[quote="某话题标题')));
    });

    test('嵌套引用:外层头部不被内层引用的显示名污染', () {
      final md = HtmlToMarkdown.convert(
        '<aside class="quote" data-username="outer" data-post="2" data-topic="1">'
        '<div class="title"><div class="quote-controls"></div> outer:</div>'
        '<blockquote>'
        '<aside class="quote" data-username="inner" '
        'data-display-name="内层昵称" data-post="1" data-topic="1">'
        '<div class="title"><div class="quote-controls"></div> 内层昵称:</div>'
        '<blockquote><p>内层内容</p></blockquote></aside>'
        '<p>外层内容</p>'
        '</blockquote></aside>',
      );
      expect(md, contains('[quote="outer, post:2, topic:1"]'));
      expect(
        md,
        contains('[quote="内层昵称, post:1, topic:1, username:inner"]'),
      );
    });
  });

  group('图片 upload:// 短链', () {
    test('data-base62-sha1 优先:lightbox 链接转短链', () {
      final md = HtmlToMarkdown.convert(
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x.test/uploads/orig/abc.png" title="图片">'
        '<img src="https://x.test/uploads/opt/abc.png" '
        'data-base62-sha1="b62abc" width="690" height="345">'
        '</a></div>',
      );
      expect(md, contains('](upload://b62abc.png)'));
    });

    test('客户端 cook 预览形态:img 无 sha1 时回退 data-orig-src', () {
      final md = HtmlToMarkdown.convert(
        '<p><img src="/images/transparent.png" alt="示意" '
        'data-orig-src="upload://abc.png" width="100" height="80"></p>',
      );
      expect(md, contains('](upload://abc.png)'));
      expect(md, isNot(contains('transparent.png')));
    });

    test('客户端 cook 预览形态:lightbox 链接回退 img 的 data-orig-src', () {
      final md = HtmlToMarkdown.convert(
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x.test/uploads/orig/abc.png" title="图片">'
        '<img src="/images/transparent.png" data-orig-src="upload://abc.png">'
        '</a></div>',
      );
      expect(md, contains('](upload://abc.png)'));
    });
  });
}
