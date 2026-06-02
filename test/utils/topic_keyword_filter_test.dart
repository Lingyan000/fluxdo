import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/utils/topic_keyword_filter.dart';

Topic _topic(int id, String title) => Topic(
  id: id,
  title: title,
  slug: 'topic-$id',
  postsCount: 1,
  replyCount: 0,
  views: 0,
  likeCount: 0,
  categoryId: '1',
);

void main() {
  group('TopicKeywordFilter.apply', () {
    final topics = [
      _topic(1, 'Main thread for the AI release'),
      _topic(2, '今天的水帖合集'),
      _topic(3, 'Available tools'),
      _topic(4, 'Hello world'),
      _topic(5, 'AI 助手测试'),
    ];

    test('空关键词返回原列表，hidden 为 0', () {
      final (visible, hidden) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: const [],
        wholeWord: false,
      );
      expect(visible, topics);
      expect(hidden, 0);
    });

    test('空话题列表直接返回，hidden 为 0', () {
      final (visible, hidden) = TopicKeywordFilter.apply(
        const [],
        normalizedKeywords: const ['ai'],
        wholeWord: false,
      );
      expect(visible, isEmpty);
      expect(hidden, 0);
    });

    test('子串匹配不区分大小写', () {
      final (visible, hidden) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: const ['ai'],
        wholeWord: false,
      );
      // 子串模式下 "ai" 命中 Main、Available、AI、AI 助手 → 4 条被过滤
      // 仅 id=2 "今天的水帖合集" 与 id=4 "Hello world" 留下
      // 等等：Hello world 不含 ai，Main 含 ai (m-a-i-n)，Available 含 ai (av-ai-lable)
      // AI release 含 ai，AI 助手 含 ai
      expect(visible.map((t) => t.id), [2, 4]);
      expect(hidden, 3);
    });

    test('中文关键词命中', () {
      final (visible, hidden) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: const ['水帖'],
        wholeWord: false,
      );
      expect(visible.map((t) => t.id), [1, 3, 4, 5]);
      expect(hidden, 1);
    });

    test('多关键词任一命中即过滤', () {
      final (visible, hidden) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: const ['ai', '水帖'],
        wholeWord: false,
      );
      // 命中：1(ai)、2(水帖)、3(ai)、5(ai) → 剩 4
      expect(visible.map((t) => t.id), [4]);
      expect(hidden, 4);
    });

    test('完整词模式下英文不再误匹配子串', () {
      final (visible, hidden) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: const ['ai'],
        wholeWord: true,
      );
      // 完整词下 "ai" 应命中 "AI release"（独立的 AI 词）和 "AI 助手"
      // 而不命中 "Main"（mai 是 main 的子串）和 "Available"（ai 是 av-ai-lable 的子串）
      expect(visible.map((t) => t.id), containsAll([2, 3, 4]));
      expect(visible.map((t) => t.id), isNot(contains(1)));
      expect(visible.map((t) => t.id), isNot(contains(5)));
      expect(hidden, 2);
    });

    test('完整词模式对中文关键词等价于子串', () {
      final (visible, hidden) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: const ['水帖'],
        wholeWord: true,
      );
      expect(visible.map((t) => t.id), [1, 3, 4, 5]);
      expect(hidden, 1);
    });

    test('包含特殊正则字符的关键词被转义', () {
      final special = [
        _topic(10, 'Use a.b.c notation'),
        _topic(11, 'No dots here'),
      ];
      final (visible, hidden) = TopicKeywordFilter.apply(
        special,
        normalizedKeywords: const ['a.b.c'],
        wholeWord: false,
      );
      expect(visible.map((t) => t.id), [11]);
      expect(hidden, 1);
    });
  });

  group('TopicKeywordFilter.shouldAutoLoadMore', () {
    test('hasMore 为 false 时不续加载', () {
      expect(
        TopicKeywordFilter.shouldAutoLoadMore(
          visibleBefore: 5,
          visibleAfter: 5,
          hasMore: false,
          attempts: 0,
        ),
        isFalse,
      );
    });

    test('达到 maxAttempts 时不续加载', () {
      expect(
        TopicKeywordFilter.shouldAutoLoadMore(
          visibleBefore: 0,
          visibleAfter: 0,
          hasMore: true,
          attempts: 3,
        ),
        isFalse,
      );
    });

    test('可见增量足够时不续加载', () {
      expect(
        TopicKeywordFilter.shouldAutoLoadMore(
          visibleBefore: 10,
          visibleAfter: 25,
          hasMore: true,
          attempts: 0,
        ),
        isFalse,
      );
    });

    test('可见增量不足且未达上限且仍有更多时续加载', () {
      expect(
        TopicKeywordFilter.shouldAutoLoadMore(
          visibleBefore: 10,
          visibleAfter: 12,
          hasMore: true,
          attempts: 1,
        ),
        isTrue,
      );
    });
  });
}
