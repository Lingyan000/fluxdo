import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/seeking.dart';
import 'package:fluxdo/models/user_action.dart';
import 'package:fluxdo/providers/seeking_provider.dart';

void main() {
  group('SeekingState', () {
    test('合并多名用户动态后按时间倒序排列', () {
      final state = SeekingState(
        data: {
          'alice': [
            SeekingActivity(
              uid: 'alice-old',
              username: 'alice',
              type: SeekingActivityType.reply,
              topicId: 1,
              title: '较早动态',
              createdAt: DateTime.utc(2026, 7, 16, 1),
            ),
          ],
          'bob': [
            SeekingActivity(
              uid: 'bob-new',
              username: 'bob',
              type: SeekingActivityType.post,
              topicId: 2,
              title: '最新动态',
              createdAt: DateTime.utc(2026, 7, 16, 3),
            ),
            SeekingActivity(
              uid: 'bob-middle',
              username: 'bob',
              type: SeekingActivityType.like,
              topicId: 3,
              title: '中间动态',
              createdAt: DateTime.utc(2026, 7, 16, 2),
            ),
          ],
        },
      );

      expect(state.timeline.map((activity) => activity.uid), [
        'bob-new',
        'bob-middle',
        'alice-old',
      ]);
    });
  });

  group('SeekingActivity', () {
    test('将用户操作映射为对应的追觅动态类型', () {
      SeekingActivity fromAction(int actionType) {
        return SeekingActivity.fromUserAction(
          'alice',
          UserAction(
            actionType: actionType,
            topicId: 42,
            postNumber: 3,
            title: '测试话题',
          ),
        );
      }

      expect(
        fromAction(UserActionType.newTopic).type,
        SeekingActivityType.post,
      );
      expect(fromAction(UserActionType.like).type, SeekingActivityType.like);
      expect(fromAction(UserActionType.reply).type, SeekingActivityType.reply);
    });
  });
}
