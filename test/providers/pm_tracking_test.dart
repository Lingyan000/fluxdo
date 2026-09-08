import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/pm_tracking_providers.dart';
import 'package:fluxdo/services/message_bus_service.dart';

/// 私信追踪消息分派（对齐 Discourse 网页版 pm-topic-tracking-state.js
/// 的 _processMessage）。
///
/// 重点是「哪些消息不该冒提示」：自己发的新私信、自己在别的端做的归档，
/// 以及 read 要把已有提示撤掉。

const int _currentUserId = 42;

class _FakeCurrentUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async =>
      User(id: _currentUserId, username: 'me', trustLevel: 1);
}

MessageBusMessage _msg(
  String messageType, {
  required int topicId,
  Map<String, dynamic> payload = const {},
}) =>
    MessageBusMessage(
      channel: '/private-message-topic-tracking-state/user/$_currentUserId',
      messageId: 1,
      data: {
        'message_type': messageType,
        'topic_id': topicId,
        'payload': payload,
      },
    );

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(_FakeCurrentUser.new),
      ],
    );
  });

  tearDown(() => container.dispose());

  PmTrackingNotifier notifier() => container.read(pmTrackingProvider.notifier);
  PmIncomingState stateOf() => container.read(pmTrackingProvider);

  void send(MessageBusMessage m) =>
      notifier().processMessageForTest(m, currentUserId: _currentUserId);

  test('别人发来的新私信计入提示', () {
    send(_msg('new_topic', topicId: 1, payload: {'created_by_user_id': 99}));
    expect(stateOf().incomingTopicIds, {1});
    expect(stateOf().hasIncoming, isTrue);
  });

  test('自己发出的私信不计入提示', () {
    send(
      _msg(
        'new_topic',
        topicId: 2,
        payload: {'created_by_user_id': _currentUserId},
      ),
    );
    expect(stateOf().incomingTopicIds, isEmpty);
  });

  test('unread 计入提示', () {
    send(_msg('unread', topicId: 3));
    expect(stateOf().incomingTopicIds, {3});
  });

  test('read 撤掉已有提示', () {
    send(_msg('unread', topicId: 4));
    expect(stateOf().incomingTopicIds, {4});

    send(_msg('read', topicId: 4));
    expect(stateOf().incomingTopicIds, isEmpty);
  });

  group('group_archive', () {
    test('他人归档时提示', () {
      send(_msg('group_archive', topicId: 5, payload: {'acting_user_id': 99}));
      expect(stateOf().incomingTopicIds, {5});
    });

    test('自己在别的端归档时不提示', () {
      send(
        _msg(
          'group_archive',
          topicId: 6,
          payload: {'acting_user_id': _currentUserId},
        ),
      );
      expect(stateOf().incomingTopicIds, isEmpty);
    });

    test('没有 acting_user_id 时按他人处理（对齐网页版）', () {
      send(_msg('group_archive', topicId: 7));
      expect(stateOf().incomingTopicIds, {7});
    });
  });

  test('同一话题重复推送只记一次', () {
    send(_msg('unread', topicId: 8));
    send(_msg('unread', topicId: 8));
    expect(stateOf().incomingTopicIds, {8});
    expect(stateOf().incomingCount, 1);
  });

  test('未知消息类型被忽略', () {
    send(_msg('some_future_type', topicId: 9));
    expect(stateOf().incomingTopicIds, isEmpty);
  });

  test('缺少 topic_id 的消息被忽略', () {
    notifier().processMessageForTest(
      MessageBusMessage(
        channel: '/private-message-topic-tracking-state/user/$_currentUserId',
        messageId: 1,
        data: {'message_type': 'unread'},
      ),
      currentUserId: _currentUserId,
    );
    expect(stateOf().incomingTopicIds, isEmpty);
  });

  test('clearIncoming 清空全部提示', () {
    send(_msg('unread', topicId: 10));
    send(_msg('unread', topicId: 11));
    expect(stateOf().incomingCount, 2);

    notifier().clearIncoming();
    expect(stateOf().hasIncoming, isFalse);
  });
}
