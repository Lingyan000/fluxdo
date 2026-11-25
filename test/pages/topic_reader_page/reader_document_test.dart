import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_reader_page/reader_document.dart';
import 'package:fluxdo/pages/topic_reader_page/reader_preferences.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/post/small_action_item.dart' show PostTypes;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _makePost({
  required int id,
  required int postNumber,
  required String cooked,
  DateTime? createdAt,
}) {
  final ts = createdAt ?? DateTime.utc(2026, 5, 1, 10, 0);
  return Post(
    id: id,
    username: 'author',
    name: '作者',
    avatarTemplate: '/avatar/{size}.png',
    cooked: cooked,
    postNumber: postNumber,
    postType: PostTypes.regular,
    createdAt: ts,
    updatedAt: ts,
    likeCount: 0,
    replyCount: 0,
  );
}

void main() {
  group('ReaderDocumentBuilder', () {
    test('提取首贴原生 HTML 标题（h1–h5），不从纯文本猜测章节', () {
      final t0 = DateTime.utc(2026, 5, 1, 8, 0);
      final firstPost = _makePost(
        id: 101,
        postNumber: 1,
        createdAt: t0,
        cooked:
            '<h1>第一节 开篇介绍</h1><p>第一章 这只是普通段落</p>'
            '<h2>1.1 核心背景</h2><p>背景细节。</p>',
      );

      final doc = ReaderDocumentBuilder.build(
        topicId: 42,
        title: '长文实战指南',
        authorName: '作者',
        topicCreatedAt: t0,
        firstPost: firstPost,
        replyCount: 18,
      );

      expect(doc.hasHeadings, isTrue);
      expect(doc.headings.map((h) => h.title).toList(), [
        '第一节 开篇介绍',
        '1.1 核心背景',
      ]);
      expect(doc.headings.map((h) => h.level).toList(), [1, 2]);
      expect(
        doc.items.whereType<ReaderFooterItem>().single.replyCount,
        18,
      );
    });

    test('无 HTML 标题的首贴目录为空', () {
      final firstPost = _makePost(
        id: 201,
        postNumber: 1,
        cooked: '<p>第一章 纯段落内容，不带标题标签。</p>',
      );

      final doc = ReaderDocumentBuilder.build(
        topicId: 43,
        title: '短帖',
        authorName: '作者',
        topicCreatedAt: null,
        firstPost: firstPost,
        replyCount: 0,
      );

      expect(doc.hasHeadings, isFalse);
      expect(doc.headings, isEmpty);
    });
  });

  group('ReaderPreferences & ReaderPositionStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('亮色纸张主题在浅色模式生效、深色模式自动回退深色主题', () {
      final lightTheme = ThemeData(brightness: Brightness.light);
      final darkTheme = ThemeData(brightness: Brightness.dark);

      final warmLight = ReaderPalette.resolve(
        lightTheme,
        ReaderPaperTheme.paper,
      );
      expect(warmLight.isCustomLight, isTrue);
      expect(warmLight.usePaperTexture, isTrue);

      final warmDark = ReaderPalette.resolve(darkTheme, ReaderPaperTheme.paper);
      expect(warmDark.isCustomLight, isFalse);
      expect(warmDark.usePaperTexture, isFalse);
      expect(warmDark.background, darkTheme.colorScheme.surface);
    });

    test('字号严格对齐离散档位，偏好持久化并支持重置', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = ReaderPreferencesNotifier(prefs);

      // 非档位输入自动对齐到最近档位，确保界面选中项与实际字号始终一致
      notifier.setFontSize(18.2);
      expect(notifier.state.fontSize, 19.0);

      notifier.setLineSpacing(ReaderLineSpacing.relaxed);
      notifier.setFontWeight(ReaderFontWeight.semiBold);
      notifier.setFontChoice(FontChoice.system);
      notifier.setPaperTheme(ReaderPaperTheme.green);

      final reloaded = ReaderPreferencesNotifier(prefs);
      expect(reloaded.state.fontSize, 19.0);
      expect(reloaded.state.lineSpacing, ReaderLineSpacing.relaxed);
      expect(reloaded.state.fontWeight, ReaderFontWeight.semiBold);
      expect(reloaded.state.fontChoice, FontChoice.system);
      expect(reloaded.state.paperTheme, ReaderPaperTheme.green);

      reloaded.reset();
      expect(reloaded.state, const ReaderPreferences());
    });

    test('ReaderPositionStore 读写单帖阅读位置', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = ReaderPositionStore(prefs);

      await store.write(
        1001,
        const ReaderPosition(
          itemKey: 'reader_post_555_chunk_2',
          progress: 0.42,
          updatedAtMs: 1700000000000,
        ),
      );

      final restored = store.read(1001);
      expect(restored, isNotNull);
      expect(restored!.itemKey, 'reader_post_555_chunk_2');
      expect(restored.progress, closeTo(0.42, 0.001));
    });
  });
}
