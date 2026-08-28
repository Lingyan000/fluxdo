import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/discourse_url_parser.dart';

void main() {
  group('平行视界左栏链接解析', () {
    test('解析分类 ID', () {
      expect(DiscourseUrlParser.parseCategory('/c/develop/42')?.categoryId, 42);
      expect(DiscourseUrlParser.parseCategory('/c/42')?.categoryId, 42);
    });

    test('解析并解码标签', () {
      expect(DiscourseUrlParser.parseTag('/tag/flutter'), 'flutter');
      expect(DiscourseUrlParser.parseTag('/tag/%E4%B8%AD%E6%96%87'), '中文');
    });

    test('只把真正的站点根路径识别为首页', () {
      expect(DiscourseUrlParser.isHomepage('/'), isTrue);
      expect(DiscourseUrlParser.isHomepage('https://linux.do/'), isTrue);
      expect(DiscourseUrlParser.isHomepage('/latest'), isFalse);
    });

    test('解析标题中的绝对 URL', () {
      final result = DiscourseUrlParser.parseTitleUrl(
        ' https://example.com/article?id=42#comments ',
      );

      expect(result?.url, 'https://example.com/article?id=42#comments');
      expect(result?.uri.host, 'example.com');
    });

    test('标题包含其它文字或非 HTTP(S) 协议时不解析', () {
      expect(
        DiscourseUrlParser.parseTitleUrl('看这篇 https://example.com/article'),
        isNull,
      );
      expect(
        DiscourseUrlParser.parseTitleUrl('mailto:user@example.com'),
        isNull,
      );
      expect(DiscourseUrlParser.parseTitleUrl('https://'), isNull);
    });
  });
}
