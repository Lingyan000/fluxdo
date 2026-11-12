import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/utils/url_helper.dart';
import 'package:fluxdo/widgets/content/collapsed_html_content.dart';

void main() {
  testWidgets('摘要源码中的空行合并为空格，后续内容可连续展示', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const intro = '国庆节的时候，我们上架了 iOS App 的首个可用版本，并发布了公告。';
    const continuation = '从可用到好用，收到了大家的反馈和建议后，我们逐步完善了手机、平板和桌面上的阅读体验。';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 740,
            child: CollapsedHtmlContent(
              html: '$intro\n\n\n\n    $continuation\n\n$continuation',
              maxLines: 4,
              textStyle: TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText),
    );
    expect(paragraph.text.toPlainText(), '$intro $continuation $continuation');
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.size.height, greaterThan(21));
    expect(paragraph.size.height, lessThanOrEqualTo(84));
    final start = paragraph.getOffsetForCaret(
      const TextPosition(offset: intro.length + 1),
      Rect.zero,
    );
    expect(start.dy, lessThan(42));
  });

  for (final (description, source, expected) in [
    (
      '保留段落和显式换行，同时压缩空段',
      '<p>第一段\n   继续 <b>阅读</b>。</p>\n\n<p><br><br></p>'
          '<p>第二段<br>下一行</p>',
      '第一段 继续 阅读。\n第二段\n下一行',
    ),
    (
      '解码实体，忽略非内容元素',
      '<p>&#20320;&#22909;&nbsp;&amp; &#39;朋友&#39; &lt;3</p>'
          '<script>隐藏代码</script><style>隐藏样式</style><template>隐藏模板</template>',
      "你好 & '朋友' <3",
    ),
    (
      '行内标签不凭空分词，普通图片保留替代文字',
      '共同<b>改进</b>体验 <img alt="示意图">，支持 <i>移动端</i>。',
      '共同改进体验 示意图，支持 移动端。',
    ),
  ]) {
    testWidgets(description, (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CollapsedHtmlContent(html: source)),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText),
      );
      expect(paragraph.text.toPlainText(), expected);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('解析多 class、单引号、无 alt 的表情图片与 shortcode', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox).first);
    const source =
        '支持 '
        "<img class='emoji emoji-custom' alt=':custom:' src='/uploads/custom.png'>"
        '<img src="/images/emoji/twemoji/smile.png" class="emoji" title=":smile:">'
        ' :heart: :+1:t3:';
    // 直接检查富文本输出，表情图片的解析测试无需网络解码。
    final text =
        const CollapsedHtmlContent(html: source).build(context) as Text;
    final spans = (text.textSpan! as TextSpan).children!;
    final emojis = spans.whereType<WidgetSpan>().toList();
    expect(emojis, hasLength(4));
    final custom = emojis.first.child as Image;
    expect(custom.semanticLabel, ':custom:');
    expect(
      custom.image,
      emojiImageProvider(UrlHelper.resolveUrlWithCdn('/uploads/custom.png')),
    );
    final standard = emojis[1].child as Image;
    expect(standard.semanticLabel, ':smile:');
    expect(
      standard.image,
      emojiImageProvider(
        UrlHelper.resolveUrlWithCdn('/images/emoji/twemoji/smile.png'),
      ),
    );
    expect(text.textSpan!.toPlainText(), '支持 \uFFFC\uFFFC \uFFFC \uFFFC');
  });
}
