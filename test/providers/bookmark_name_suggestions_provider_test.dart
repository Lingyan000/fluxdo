import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/bookmarks_repository.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/bookmark_hive_test_support.dart';

// 方案 E 重构后 BookmarkNameSuggestionsNotifier 改为从 BookmarksRepository
// 派生，自身不再独立发起网络请求。这里只覆盖旧 API 兼容性的契约：
// rememberName / markDirty 立即把新名字插入候选；clearCache 清空状态。
//
// repository.watch 自动派生的端到端流程已被 bookmarks_reconciler_test +
// bookmarks_provider_test 覆盖，这里不重复。

Future<ProviderContainer> _createContainer(
  BookmarkHiveTestSupport storage,
) async {
  final repo = BookmarksRepository(
    BookmarkCacheDao(boxFactory: storage.openBox),
  );
  final container = ProviderContainer(
    overrides: [bookmarksRepositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(() async {
    container.dispose();
    await repo.dispose();
  });
  return container;
}

void main() {
  late BookmarkHiveTestSupport storage;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    storage = await BookmarkHiveTestSupport.create();
  });

  tearDown(() async {
    await storage.dispose();
  });

  test('rememberName 立即把新名字加入候选', () async {
    final container = await _createContainer(storage);
    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);

    expect(container.read(bookmarkNameSuggestionsProvider), isEmpty);

    notifier.rememberName('image');
    notifier.rememberName('beta');

    expect(container.read(bookmarkNameSuggestionsProvider), ['image', 'beta']);
  });

  test('rememberName 跳过空白与重复值', () async {
    final container = await _createContainer(storage);
    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);

    notifier.rememberName('image');
    notifier.rememberName(' image ');
    notifier.rememberName('');
    notifier.rememberName('   ');
    notifier.rememberName(null);

    expect(container.read(bookmarkNameSuggestionsProvider), ['image']);
  });

  test('markDirty 等价于 rememberName(optimisticName)', () async {
    final container = await _createContainer(storage);
    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);

    notifier.markDirty(optimisticName: 'codex');

    expect(container.read(bookmarkNameSuggestionsProvider), ['codex']);
  });

  test('clearCache 清空候选', () async {
    final container = await _createContainer(storage);
    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);

    notifier.rememberName('image');
    notifier.clearCache();

    expect(container.read(bookmarkNameSuggestionsProvider), isEmpty);
  });
}
