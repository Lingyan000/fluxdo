import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ai_post_review_service.dart';
import 'package:fluxdo/widgets/ai/ai_post_review_button.dart';

void main() {
  group('AiPostReviewInputSnapshot', () {
    const base = AiPostReviewInputSnapshot(
      target: AiPostReviewTarget.topic,
      title: '测试标题',
      content: '测试正文',
      categoryName: '开发调优',
      categoryDescription: '讨论开发和调优',
      tags: ['linux', 'flutter'],
    );

    test('相同输入会复用同一个审核签名', () {
      const same = AiPostReviewInputSnapshot(
        target: AiPostReviewTarget.topic,
        title: '  测试标题  ',
        content: '测试正文',
        categoryName: '开发调优',
        categoryDescription: '讨论开发和调优',
        tags: ['flutter', 'linux'],
      );

      expect(base.hasSameSignature(same), isTrue);
    });

    test('标题、正文、分区和标签变化都会改变审核签名', () {
      final changed = [
        const AiPostReviewInputSnapshot(
          target: AiPostReviewTarget.topic,
          title: '新标题',
          content: '测试正文',
          categoryName: '开发调优',
          categoryDescription: '讨论开发和调优',
          tags: ['linux', 'flutter'],
        ),
        const AiPostReviewInputSnapshot(
          target: AiPostReviewTarget.topic,
          title: '测试标题',
          content: '新正文',
          categoryName: '开发调优',
          categoryDescription: '讨论开发和调优',
          tags: ['linux', 'flutter'],
        ),
        const AiPostReviewInputSnapshot(
          target: AiPostReviewTarget.topic,
          title: '测试标题',
          content: '测试正文',
          categoryName: '资源分享',
          categoryDescription: '分享资源',
          tags: ['linux', 'flutter'],
        ),
        const AiPostReviewInputSnapshot(
          target: AiPostReviewTarget.topic,
          title: '测试标题',
          content: '测试正文',
          categoryName: '开发调优',
          categoryDescription: '讨论开发和调优',
          tags: ['linux'],
        ),
      ];

      for (final snapshot in changed) {
        expect(base.hasSameSignature(snapshot), isFalse);
      }
    });

    test('正文换行和缩进变化不会复用旧审核签名', () {
      const markdown = AiPostReviewInputSnapshot(
        target: AiPostReviewTarget.topic,
        title: '测试标题',
        content: '第一行\n  缩进内容',
        categoryName: '开发调优',
        categoryDescription: '讨论开发和调优',
        tags: ['linux', 'flutter'],
      );
      const flattened = AiPostReviewInputSnapshot(
        target: AiPostReviewTarget.topic,
        title: '测试标题',
        content: '第一行 缩进内容',
        categoryName: '开发调优',
        categoryDescription: '讨论开发和调优',
        tags: ['linux', 'flutter'],
      );

      expect(markdown.hasSameSignature(flattened), isFalse);
    });

    test('空正文会被标记为不可直接审核', () {
      const snapshot = AiPostReviewInputSnapshot(
        target: AiPostReviewTarget.reply,
        title: '话题标题',
        content: '   ',
        categoryName: null,
        categoryDescription: null,
        tags: [],
      );

      expect(snapshot.hasContent, isFalse);
    });
  });
}
