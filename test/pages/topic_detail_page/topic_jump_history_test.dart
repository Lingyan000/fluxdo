import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_jump_history.dart';

void main() {
  const origin = TopicReadingPosition(postNumber: 128, offset: -36);
  const middle = TopicReadingPosition(postNumber: 34);
  const destination = TopicReadingPosition(postNumber: 8);

  test('快速改选只保存真正离开的起点，忽略迟到的完成结果', () {
    final history = TopicJumpHistory();
    addTearDown(history.dispose);
    final first = history.begin(origin);
    final second = history.begin(middle);
    history.finish(first, succeeded: true, destination: middle);
    expect(history.target, isNull);
    history.finish(second, succeeded: true, destination: destination);
    expect(history.target, same(origin));
  });

  test('逐级返回成功才移除记录，失败后可以重试', () {
    final history = TopicJumpHistory();
    addTearDown(history.dispose);
    history.finish(history.begin(origin), succeeded: true, destination: middle);
    history.finish(
      history.begin(middle),
      succeeded: true,
      destination: destination,
    );
    history.finish(
      history.begin(destination, returning: true),
      succeeded: false,
    );
    expect(history.target, same(middle));
    expect(history.returning, isFalse);
    history.finish(
      history.begin(destination, returning: true),
      succeeded: true,
    );
    expect(history.target, same(origin));
    history.finish(history.begin(middle, returning: true), succeeded: true);
    expect(history.target, isNull);
  });

  test('未移动和失败跳转不记入历史，关闭后迟到结果不会重建入口', () {
    final history = TopicJumpHistory();
    addTearDown(history.dispose);
    history.finish(history.begin(origin), succeeded: true, destination: origin);
    expect(history.target, isNull);
    history.finish(
      history.begin(origin),
      succeeded: false,
      destination: middle,
    );
    expect(history.target, isNull);
    final pending = history.begin(origin);
    history.clear();
    history.finish(pending, succeeded: true, destination: middle);
    expect(history.target, isNull);
  });
}
