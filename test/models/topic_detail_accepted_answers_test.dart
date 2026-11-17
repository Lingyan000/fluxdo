import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';

Map<String, dynamic> _topicJson(Map<String, dynamic> extra) {
  return {
    ...extra,
    'id': 42,
    'title': 'Solved topic',
    'slug': 'solved-topic',
    'posts_count': 2,
    'post_stream': {
      'posts': const <Map<String, dynamic>>[],
      'stream': const <int>[],
    },
    'category_id': 0,
    'details': const <String, dynamic>{},
  };
}

void main() {
  test('新版 accepted_answers 读取完整 cooked 与 created_at', () {
    final detail = TopicDetail.fromJson(
      _topicJson({
        'accepted_answers': const [
          {
            'id': 1923103,
            'username': 'alice',
            'avatar_template': '/user_avatar/alice/{size}/1.png',
            'created_at': '2026-01-20T11:42:30.805Z',
            'cooked': '<p>答案正文</p>',
            'post_number': 2,
            'topic_id': 42,
            'url': '/t/solved-topic/42/2',
          },
        ],
      }),
    );

    final answer = detail.acceptedAnswers.single;
    expect(answer.postNumber, 2);
    expect(answer.cooked, '<p>答案正文</p>');
    expect(
      answer.createdAt?.toUtc(),
      DateTime.utc(2026, 1, 20, 11, 42, 30, 805),
    );
  });

  test('旧版 accepted_answer 回退读取 excerpt', () {
    final detail = TopicDetail.fromJson(
      _topicJson({
        'accepted_answer': const {
          'post_number': 3,
          'username': 'bob',
          'excerpt': '摘要',
        },
      }),
    );

    final answer = detail.acceptedAnswers.single;
    expect(answer.postNumber, 3);
    expect(answer.cooked, '摘要');
    expect(answer.createdAt, isNull);
  });
}
