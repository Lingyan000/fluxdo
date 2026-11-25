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

  test('连续探索未滚动时合并过路站，滚动停留后保留逐级返回', () {
    var now = DateTime(2026, 11, 25, 20, 0, 0);
    final history = TopicJumpHistory(clock: () => now);
    addTearDown(history.dispose);

    history.finish(
      history.begin(origin, coalesceExplore: true),
      succeeded: true,
      destination: middle,
    );
    expect(history.target, same(origin));

    // 3 秒内未滚动继续探索到新位置：合并过路站，仍回到最初起点。
    now = now.add(const Duration(seconds: 3));
    history.finish(
      history.begin(middle, coalesceExplore: true),
      succeeded: true,
      destination: destination,
    );
    expect(history.target, same(origin));

    // 在落点滚动停留后再次探索：压入新一级记录。
    history.markUserScrolled();
    now = now.add(const Duration(seconds: 2));
    const another = TopicReadingPosition(postNumber: 90);
    history.finish(
      history.begin(destination, coalesceExplore: true),
      succeeded: true,
      destination: another,
    );
    expect(history.target, same(destination));
  });

  test('不记录标记、同楼层小位移和视口内相邻楼层不入栈', () {
    final history = TopicJumpHistory();
    addTearDown(history.dispose);

    // recordHistory: false 不记入历史。
    history.finish(
      history.begin(origin, recordHistory: false),
      succeeded: true,
      destination: destination,
    );
    expect(history.target, isNull);

    // 同楼层微小偏移不入栈。
    history.finish(
      history.begin(const TopicReadingPosition(postNumber: 1, offset: 0)),
      succeeded: true,
      destination: const TopicReadingPosition(postNumber: 1, offset: -50),
    );
    expect(history.target, isNull);

    // 相邻楼层且跳转前已在视口内可见不入栈。
    history.finish(
      history.begin(
        const TopicReadingPosition(postNumber: 10),
        originVisiblePosts: {10, 11},
      ),
      succeeded: true,
      destination: const TopicReadingPosition(postNumber: 11),
    );
    expect(history.target, isNull);
  });

  test('目标长帖内持续阅读不消退，滚回原位或继续跨多楼浏览自动消退', () {
    final history = TopicJumpHistory();
    addTearDown(history.dispose);

    const start = TopicReadingPosition(postNumber: 10);
    const dest = TopicReadingPosition(postNumber: 50);
    history.finish(history.begin(start), succeeded: true, destination: dest);
    history.markUserScrolled();

    // 在目标长帖及紧邻 ±1 楼内反复阅读，绝不清除。
    for (final floor in [50, 51, 49, 50]) {
      history.observeReading(
        currentPostNumber: floor,
        visiblePostNumbers: {floor},
        isNestedView: false,
      );
      expect(history.target, same(start));
    }

    // 离开目标后继续主动浏览 4 个新楼层，自动清空。
    for (final floor in [52, 53, 54]) {
      history.observeReading(
        currentPostNumber: floor,
        visiblePostNumbers: {floor},
        isNestedView: false,
      );
      expect(history.target, same(start));
    }
    history.observeReading(
      currentPostNumber: 55,
      visiblePostNumbers: {55},
      isNestedView: false,
    );
    expect(history.target, isNull);

    // 重新跳离后，自己滚回原楼层时静默 pop。
    history.finish(history.begin(start), succeeded: true, destination: dest);
    history.markUserScrolled();
    history.observeReading(
      currentPostNumber: 10,
      visiblePostNumbers: {9, 10, 11},
      isNestedView: false,
    );
    expect(history.target, isNull);
  });
}
