// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/async_presentation_cache.dart';

void main() {
  test('同身份刷新可继续显示 previous，失败仍返回错误', () {
    final cache = AsyncPresentationCache<List<int>>()..selectIdentity('a');
    final first = AsyncData([1]);
    cache.accept(first);
    final refreshing = const AsyncLoading<List<int>>().copyWithPrevious(first);
    expect(cache.accept(refreshing).value, [1]);
    expect(cache.needsRefresh(refreshing), isFalse);
    final error = AsyncError<List<int>>('failed', StackTrace.current);
    expect(cache.accept(error), same(error));
  });

  test('换账号立即清空旧内容，既有刷新启动后不再重复请求', () {
    final cache = AsyncPresentationCache<List<int>>()..selectIdentity('a');
    final old = AsyncData([1]);
    cache.accept(old);
    cache.selectIdentity('b');
    expect(cache.cached.hasValue, isFalse);
    expect(cache.accept(old).hasValue, isFalse);
    expect(cache.needsRefresh(old), isTrue);
    final refreshing = const AsyncLoading<List<int>>().copyWithPrevious(old);
    expect(cache.accept(refreshing).hasValue, isFalse);
    expect(cache.needsRefresh(refreshing), isFalse);
    final next = AsyncData([2]);
    expect(cache.accept(next).value, [2]);
    expect(cache.needsRefresh(next), isFalse);
  });

  test('刷新期间连续换筛选，不重新接受最初的 previous', () {
    final cache = AsyncPresentationCache<List<int>>()..selectIdentity('a');
    final old = AsyncData([1]);
    cache.accept(old);
    final refreshing = const AsyncLoading<List<int>>().copyWithPrevious(old);
    for (final query in ['b', 'c', 'd']) {
      cache.selectIdentity(query);
      expect(cache.accept(refreshing).hasValue, isFalse);
    }
    expect(cache.accept(AsyncData([4])).value, [4]);
  });

  test('用户资料晚于列表返回，能识别需要刷新的旧结果', () {
    final cache = AsyncPresentationCache<List<int>>()..selectIdentity('guest');
    final arrivedBeforeUser = AsyncData([1]);
    cache.accept(arrivedBeforeUser);
    cache.selectIdentity('signed in');
    cache.accept(arrivedBeforeUser);
    expect(cache.needsRefresh(arrivedBeforeUser), isTrue);
    // 请求完成即使复用了同一份列表，也必须释放等待。
    final refreshed = AsyncData(arrivedBeforeUser.value);
    expect(cache.accept(refreshed).value, [1]);
    expect(cache.needsRefresh(refreshed), isFalse);
  });

  test('新身份的空结果和失败都正常展示，不永久等待', () {
    for (final result in [
      const AsyncData<List<int>>([]),
      AsyncError<List<int>>('failed', StackTrace.current),
    ]) {
      final cache = AsyncPresentationCache<List<int>>()..selectIdentity('a');
      cache.accept(AsyncData([1]));
      cache.selectIdentity('b');
      expect(cache.accept(result), same(result));
      expect(cache.needsRefresh(result), isFalse);
    }
  });
}
