import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/html_preview_truncator.dart';

void main() {
  test('短内容原样返回', () {
    const html = '<p>短答案</p>';
    final preview = HtmlPreviewTruncator.truncate(
      html,
      maxText: 100,
      maxMarkup: 100,
    );
    expect(preview.html, html);
    expect(preview.truncated, isFalse);
  });

  test('文字预算耗尽后截断文本并丢弃后续节点,标签保持闭合', () {
    final html = '<p>${'甲' * 10}</p><p>${'乙' * 10}</p><p>丙</p>';
    final preview = HtmlPreviewTruncator.truncate(
      html,
      maxText: 15,
      maxMarkup: 1000,
    );
    expect(preview.truncated, isTrue);
    expect(preview.html, '<p>${'甲' * 10}</p><p>${'乙' * 5}</p>');
  });

  test('代码块停在完整行', () {
    final code = List.generate(20, (i) => 'line_$i').join('\n');
    final preview = HtmlPreviewTruncator.truncate(
      '<pre><code>$code</code></pre>',
      maxText: 20,
      maxMarkup: 1000,
    );
    expect(preview.truncated, isTrue);
    expect(preview.html, '<pre><code>line_0\nline_1</code></pre>');
  });

  test('标记预算兜住几乎没有文字的内容,首个节点始终保留', () {
    final img = '<img src="https://example.com/${'x' * 80}.png">';
    final preview = HtmlPreviewTruncator.truncate(
      List.filled(10, img).join(),
      maxText: 1000,
      maxMarkup: 50,
    );
    expect(preview.truncated, isTrue);
    expect('<img'.allMatches(preview.html), hasLength(1));
  });
}
