import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/utils/reaction_toggle.dart';

PostReaction _r(String id, int count) =>
    PostReaction(id: id, type: 'emoji', count: count);

List<String> _ids(List<PostReaction> list) =>
    [for (final r in list) '${r.id}:${r.count}'];

void main() {
  group('applyReactionToggle', () {
    test('没有回应时选中:新增并成为我的回应', () {
      final (list, current) = applyReactionToggle(
        [_r('heart', 3)],
        null,
        'laughing',
      );
      expect(_ids(list), ['heart:3', 'laughing:1']);
      expect(current?.id, 'laughing');
    });

    test('已有该表情时计数 +1', () {
      final (list, current) = applyReactionToggle(
        [_r('heart', 3), _r('+1', 1)],
        null,
        '+1',
      );
      expect(_ids(list), ['heart:3', '+1:2']);
      expect(current?.id, '+1');
    });

    test('换表情:旧的 -1、减到 0 移除,新的 +1', () {
      final (list, current) = applyReactionToggle(
        [_r('heart', 2), _r('laughing', 1)],
        _r('laughing', 0),
        'heart',
      );
      expect(_ids(list), ['heart:3']);
      expect(current?.id, 'heart');
    });

    test('点自己当前的回应:取消', () {
      final (list, current) = applyReactionToggle(
        [_r('heart', 2), _r('laughing', 1)],
        _r('heart', 0),
        'heart',
      );
      expect(_ids(list), ['heart:1', 'laughing:1']);
      expect(current, isNull);
    });

    test('新表情按计数降序、同计数按 id 升序定位插入', () {
      final (list, _) = applyReactionToggle(
        [_r('heart', 5), _r('open_mouth', 1), _r('tada', 1)],
        null,
        'laughing',
      );
      expect(_ids(list), ['heart:5', 'laughing:1', 'open_mouth:1', 'tada:1']);
    });

    test('不修改入参', () {
      final original = [_r('heart', 1)];
      applyReactionToggle(original, _r('heart', 0), 'heart');
      expect(_ids(original), ['heart:1']);
    });
  });
}
