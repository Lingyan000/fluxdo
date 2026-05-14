import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';

void main() {
  test('话题详情会识别顶层书签字段', () {
    final detail = TopicDetail.fromJson({
      'id': 1,
      'title': 'Topic',
      'slug': 'topic',
      'posts_count': 1,
      'post_stream': {
        'posts': const <Map<String, dynamic>>[],
        'stream': const <int>[],
      },
      'category_id': 1,
      'details': const <String, dynamic>{},
      'bookmarked': true,
      'bookmark_id': 42,
      'bookmark_name': 'image',
      'bookmark_reminder_at': '2026-05-13T01:02:03.000Z',
    });

    expect(detail.bookmarked, isTrue);
    expect(detail.bookmarkId, 42);
    expect(detail.bookmarkName, 'image');
    expect(detail.bookmarkReminderAt, isNotNull);
  });

  test('顶层书签名称为问号时会视为未设置', () {
    final detail = TopicDetail.fromJson({
      'id': 1,
      'title': 'Topic',
      'slug': 'topic',
      'posts_count': 1,
      'post_stream': {
        'posts': const <Map<String, dynamic>>[],
        'stream': const <int>[],
      },
      'category_id': 1,
      'details': const <String, dynamic>{},
      'bookmarked': true,
      'bookmark_id': 42,
      'bookmark_name': '?',
    });

    expect(detail.bookmarked, isTrue);
    expect(detail.bookmarkId, 42);
    expect(detail.bookmarkName, isNull);
  });

  test('书签数组里的话题书签占位名称会视为未设置', () {
    for (final rawName in const ['?', '？', '   ']) {
      final detail = TopicDetail.fromJson({
        'id': 1,
        'title': 'Topic',
        'slug': 'topic',
        'posts_count': 1,
        'post_stream': {
          'posts': const <Map<String, dynamic>>[],
          'stream': const <int>[],
        },
        'category_id': 1,
        'details': const <String, dynamic>{},
        'bookmarks': [
          {
            'id': 42,
            'bookmarkable_type': 'Topic',
            'name': rawName,
          },
        ],
      });

      expect(detail.bookmarked, isTrue, reason: 'rawName=$rawName');
      expect(detail.bookmarkId, 42, reason: 'rawName=$rawName');
      expect(detail.bookmarkName, isNull, reason: 'rawName=$rawName');
    }
  });
}
