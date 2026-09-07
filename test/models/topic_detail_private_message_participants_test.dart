import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';

Map<String, dynamic> _topicJson({
  Map<String, dynamic>? details,
  Map<String, dynamic> extra = const {},
}) {
  return {
    ...extra,
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

  test('解析群组收件人与邀请权限', () {
    final detail = TopicDetail.fromJson(
      _topicJson(
        details: {
          'allowed_users': const <Map<String, dynamic>>[],
          'allowed_groups': const [
            {'id': 9, 'name': 'staff', 'full_name': '管理组', 'user_count': 12},
            {'name': 'moderators'},
          ],
          'can_invite_to': true,
        },
      ),
    );

    expect(detail.allowedGroups, hasLength(2));
    expect(detail.allowedGroups.first.id, 9);
    expect(detail.allowedGroups.first.name, 'staff');
    expect(detail.allowedGroups.first.displayName, '管理组');
    expect(detail.allowedGroups.first.userCount, 12);
    // 邀请群组后本地追加时只有名字，id 允许缺失
    expect(detail.allowedGroups.last.id, isNull);
    expect(detail.allowedGroups.last.displayName, 'moderators');
    expect(detail.canInviteTo, isTrue);
  });

  test('解析私信归档态并支持 copyWith 翻转', () {
    // message_archived 在顶层，不在 details 里
    final archived = TopicDetail.fromJson(
      _topicJson(extra: const {'message_archived': true}),
    );
    expect(archived.messageArchived, isTrue);
    expect(archived.copyWith(messageArchived: false).messageArchived, isFalse);

    final plain = TopicDetail.fromJson(_topicJson());
    expect(plain.messageArchived, isFalse);
    expect(plain.copyWith(messageArchived: true).messageArchived, isTrue);
  });

  test('非私信或缺少权限字段时使用安全默认值', () {
    final detail = TopicDetail.fromJson({
      ..._topicJson(),
      'archetype': 'regular',
    });

    expect(detail.isPrivateMessage, isFalse);
    expect(detail.allowedUsers, isEmpty);
    expect(detail.allowedGroups, isEmpty);
    expect(detail.canRemoveAllowedUsers, isFalse);
    expect(detail.canRemoveSelfId, isNull);
    expect(detail.canInviteTo, isFalse);
  });
}
