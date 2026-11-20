import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/post/inline_posts_scope.dart';

void main() {
  testWidgets('布局切换在宽限期内重建页面时续用同一份快照', (tester) async {
    final first = InlinePostsStore.acquire('switch');
    first.save(InlinePostsKind.replies, 1, posts: const [], expanded: true);
    InlinePostsStore.release('switch');

    await tester.pump(const Duration(seconds: 5));
    final second = InlinePostsStore.acquire('switch');
    expect(identical(first, second), isTrue);
    expect(second.read(InlinePostsKind.replies, 1)?.expanded, isTrue);

    // 续用后释放计时已取消,原宽限期到点也不会丢
    await tester.pump(const Duration(seconds: 40));
    expect(identical(InlinePostsStore.acquire('switch'), second), isTrue);
    InlinePostsStore.release('switch');
    InlinePostsStore.release('switch');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('页面关闭超过宽限期后释放', (tester) async {
    final store = InlinePostsStore.acquire('closed');
    store.save(InlinePostsKind.parents, 2, posts: const [], expanded: true);
    InlinePostsStore.release('closed');

    await tester.pump(const Duration(seconds: 31));
    final fresh = InlinePostsStore.acquire('closed');
    expect(identical(store, fresh), isFalse);
    expect(fresh.read(InlinePostsKind.parents, 2), isNull);
    InlinePostsStore.release('closed');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('同一实例叠开时,一处释放不影响另一处', (tester) async {
    final a = InlinePostsStore.acquire('shared');
    final b = InlinePostsStore.acquire('shared');
    InlinePostsStore.release('shared');

    await tester.pump(const Duration(seconds: 31));
    expect(identical(InlinePostsStore.acquire('shared'), a), isTrue);
    expect(identical(a, b), isTrue);
    InlinePostsStore.release('shared');
    InlinePostsStore.release('shared');
    await tester.pump(const Duration(seconds: 31));
  });
}
