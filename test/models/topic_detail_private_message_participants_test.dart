import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';

Map<String, dynamic> _topicJson({Map<String, dynamic>? details}) {
  return {
    'id': 42,
    'title': 'Private message',
    'slug': 'private-message',
    'posts_count': 1,
    'post_stream': {
      'posts': const <Map<String, dynamic>>[],
      'stream': const <int>[],
    },
    'category_id': 0,
    'archetype': 'private_message',
    'details': details ?? const <String, dynamic>{},
  };
}

void main() {
  test('私信详情会解析成员与移除权限', () {
    final detail = TopicDetail.fromJson(
      _topicJson(
        details: {
          'allowed_users': const [
            {
              'id': 7,
              'username': 'alice',
              'name': 'Alice',
              'avatar_template': '/user_avatar/alice/{size}/1.png',
            },
            {
              'id': 8,
              'username': 'bob',
              'avatar_template': '/user_avatar/bob/{size}/1.png',
            },
          ],
          'can_remove_allowed_users': true,
          'can_remove_self_id': 7,
        },
      ),
    );

    expect(detail.isPrivateMessage, isTrue);
    expect(detail.allowedUsers, hasLength(2));
    expect(detail.allowedUsers.first.username, 'alice');
    expect(detail.allowedUsers.first.displayName, 'Alice');
    expect(detail.allowedUsers.last.username, 'bob');
    expect(detail.canRemoveAllowedUsers, isTrue);
    expect(detail.canRemoveSelfId, 7);
  });

  test('copyWith 可同步移除成员并清空自己的退出权限', () {
    final detail = TopicDetail.fromJson(
      _topicJson(
        details: {
          'allowed_users': const [
            {'id': 7, 'username': 'alice', 'avatar_template': ''},
          ],
          'can_remove_allowed_users': true,
          'can_remove_self_id': 7,
        },
      ),
    );

    final updated = detail.copyWith(
      allowedUsers: const [],
      clearCanRemoveSelfId: true,
    );

    expect(updated.allowedUsers, isEmpty);
    expect(updated.canRemoveSelfId, isNull);
    expect(updated.canRemoveAllowedUsers, isTrue);
  });

  test('非私信或缺少权限字段时使用安全默认值', () {
    final detail = TopicDetail.fromJson({
      ..._topicJson(),
      'archetype': 'regular',
    });

    expect(detail.isPrivateMessage, isFalse);
    expect(detail.allowedUsers, isEmpty);
    expect(detail.canRemoveAllowedUsers, isFalse);
    expect(detail.canRemoveSelfId, isNull);
  });
}
