import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/bookmarks_repository.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 方案 E 重构后，旧的 BookmarksNotifier 行为（progressivelyLoadAllBookmarkTopics
// + 整页 hydrate）被本地缓存 + 对账层替代。这里保留核心契约的测试：
// 用户编辑书签后通过 [BookmarksRepository.applyMetadataChange] 能正确写穿到
// 本地缓存，且能清空 name / reminder_at。
//
// 对账三路径（首次 / 增量 / 完整 / 下拉刷新）的测试见
// `bookmarks_reconciler_test.dart`，DAO 持久化测试见
// `test/storage/bookmark_cache_dao_test.dart`。

Future<Database> _openInMemoryDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE bookmark_cache (
            account_id TEXT NOT NULL,
            bookmark_id INTEGER NOT NULL,
            topic_id INTEGER NOT NULL,
            name_normalized TEXT,
            updated_at TEXT NOT NULL,
            cached_at TEXT NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY (account_id, bookmark_id)
          )
        ''');
      },
    ),
  );
}

BookmarkCacheEntry _entryWithName({
  required int bookmarkId,
  required String? name,
  required DateTime updatedAt,
}) {
  return BookmarkCacheEntry(
    bookmarkId: bookmarkId,
    topicId: bookmarkId,
    nameNormalized: name,
    updatedAt: updatedAt,
    cachedAt: updatedAt,
    payload: {
      'id': bookmarkId,
      '_bookmark_id': bookmarkId,
      '_bookmark_updated_at': updatedAt.toUtc().toIso8601String(),
      if (name != null) '_bookmark_name': name,
      'title': 'Topic $bookmarkId',
    },
  );
}

void main() {
  late Database db;
  late BookmarksRepository repo;

  setUp(() async {
    db = await _openInMemoryDb();
    repo = BookmarksRepository(
      BookmarkCacheDao(databaseFactory: () async => db),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('applyMetadataChange 允许清空书签名（name 传 null）', () async {
    await repo.upsertEntries('acct', [
      _entryWithName(
        bookmarkId: 101,
        name: 'image',
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    ]);

    await repo.applyMetadataChange(
      'acct',
      101,
      name: null,
      reminderAt: null,
      bookmarkUpdatedAt: DateTime.utc(2026, 5, 24),
    );

    final records = await repo.readAll('acct');
    expect(records.single.topic.bookmarkName, isNull);
    expect(records.single.topic.bookmarkReminderAt, isNull);
  });

  test('applyMetadataChange 写入提醒时间', () async {
    final reminder = DateTime.utc(2026, 6, 1, 10);
    await repo.upsertEntries('acct', [
      _entryWithName(
        bookmarkId: 101,
        name: 'image',
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    ]);

    await repo.applyMetadataChange(
      'acct',
      101,
      name: 'image',
      reminderAt: reminder,
      bookmarkUpdatedAt: DateTime.utc(2026, 5, 24),
    );

    final records = await repo.readAll('acct');
    expect(records.single.topic.bookmarkReminderAt, reminder.toLocal());
  });

  test('applyMetadataChange 在本地不存在该书签时静默不写入', () async {
    await repo.applyMetadataChange(
      'acct',
      9999,
      name: 'phantom',
      reminderAt: null,
      bookmarkUpdatedAt: DateTime.now().toUtc(),
    );

    expect((await repo.allBookmarkIds('acct')), isEmpty);
  });

  test('deleteOne 写穿本地缓存', () async {
    await repo.upsertEntries('acct', [
      _entryWithName(
        bookmarkId: 1,
        name: 'image',
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      _entryWithName(
        bookmarkId: 2,
        name: 'beta',
        updatedAt: DateTime.utc(2026, 2, 1),
      ),
    ]);

    await repo.deleteOne('acct', 1);
    final ids = await repo.allBookmarkIds('acct');
    expect(ids, {2});
  });

  test('repository.watch 在每次写入后广播一次', () async {
    final events = <void>[];
    final sub = repo.watch().listen(events.add);
    addTearDown(sub.cancel);

    await repo.upsertEntries('acct', [
      _entryWithName(
        bookmarkId: 1,
        name: 'a',
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    ]);
    await repo.deleteOne('acct', 1);

    // 让事件循环跑一遍 broadcast。
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 2);
  });
}
