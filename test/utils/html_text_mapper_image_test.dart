/// 划词引用:单独选中一张图片,反查要拿到 <img>/lightbox 锚点本身,
/// 不能退化成纯文本(那样引用出来只剩一个图片名)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/html_text_mapper.dart';

void main() {
  test('lightbox 图片:返回 <a> 锚点(带 data-base62-sha1,能还原短链)', () {
    const cooked = '<p>看图 </p>'
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/original/1X/abc.png" '
        'data-download-href="/uploads/short-url/abc">'
        '<img src="https://x/optimized/1X/abc_690x300.png" alt="截图.png" '
        'data-base62-sha1="abc123">'
        '<div class="meta">截图.png 1920×1080 300 KB</div>'
        '</a></div>';

    final html = HtmlTextMapper.extractHtml(cooked, '截图.png');

    expect(html, isNotNull, reason: '不该退化成纯文本');
    expect(html, contains('data-base62-sha1="abc123"'));
    expect(html, contains('<a'));
  });

  test('裸图片(无 lightbox):返回 <img> 本身', () {
    const cooked = '<p><img src="/uploads/a.png" alt="a.png"></p>';

    final html = HtmlTextMapper.extractHtml(cooked, 'a.png');

    expect(html, isNotNull);
    expect(html, contains('<img'));
    expect(html, contains('/uploads/a.png'));
  });
}
