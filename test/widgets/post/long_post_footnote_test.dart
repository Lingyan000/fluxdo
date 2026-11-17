import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/post/post_item/segmented_long_post.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final wrapped in [false, true]) {
    test('长帖分段上标能取得文末脚注（section=$wrapped）', () {
      const list =
          '<ol class="extra footnotes-list">'
          '<li id="footnote-1"><p>第一条注释</p></li></ol>';
      final post = Post.fromJson({
        'id': wrapped ? 8101 : 8102,
        'post_number': 1,
        'username': 'tester',
        'cooked':
            '<p>正文<sup class="footnote-ref"><a href="#footnote-1">[1]</a></sup></p>'
            '${List.generate(15, (i) => '<p>第 $i 段${'长帖内容' * 80}</p>').join()}'
            '<hr class="footnotes-sep">'
            '${wrapped ? '<section class="footnotes">$list</section>' : list}'
            '<ol class="footnotes-list"><li id="footnote-2"><p>第二条注释</p></li></ol>',
      });
      final data = NewEngineLongPostData.tryBuild(post)!;
      expect(data.chunks.length, greaterThan(1));
      expect(data.chunks.first.html, isNot(contains('第一条注释')));
      final ref = data
          .parsedChunkAt(0)
          .whereType<ParagraphNode>()
          .first
          .inlines
          .whereType<FootnoteRefRun>()
          .single;
      expect(ref.contentHtml, '第一条注释');
      final footnotes = ParagraphParser().parse(data.footnotesHtml!);
      final entries = footnotes.whereType<FootnotesSectionNode>().expand(
        (section) => section.entries,
      );
      expect(entries.map((entry) => entry.id), ['footnote-1', 'footnote-2']);
    });
  }
}
