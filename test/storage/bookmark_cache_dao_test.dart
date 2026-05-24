import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openInMemoryDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await databaseFactory.openDatabase(
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
  return db;
}

BookmarkCacheEntry _entry({
  required int bookmarkId,
  int topicId = 1,
  String? name,
  required DateTime updatedAt,
}) {
  return BookmarkCacheEntry(
    bookmarkId: bookmarkId,
    topicId: topicId,
    nameNormalized: name,
    updatedAt: updatedAt,
    cachedAt: updatedAt,
    payload: {
      'id': topicId,
      '_bookmark_id': bookmarkId,
      '_bookmark_updated_at': updatedAt.toUtc().toIso8601String(),
      if (name != null) '_bookmark_name': name,
      'title': 'Topic $topicId',
    },
  );
}

void main() {
  late Database db;
  late BookmarkCacheDao dao;

  setUp(() async {
    db = await _openInMemoryDb();
    dao = BookmarkCacheDao(databaseFactory: () async => db);
  });

  tearDown(() async {
    await db.close();
  });

  test('readAll 返回的条目按 updated_at 倒序', () async {
    await dao.upsertAll('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 3, 1)),
      _entry(bookmarkId: 3, updatedAt: DateTime.utc(2026, 2, 1)),
    ]);

    final entries = await dao.readAll('acct');
    expect(entries.map((e) => e.bookmarkId), [2, 3, 1]);
  });

  test('multiple accounts are isolated', () async {
    await dao.upsertOne(
      'a',
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
    );
    await dao.upsertOne(
      'b',
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
    );

    expect((await dao.allBookmarkIds('a')), {1});
    expect((await dao.allBookmarkIds('b')), {1});

    await dao.clearAccount('a');
    expect((await dao.allBookmarkIds('a')), isEmpty);
    expect((await dao.allBookmarkIds('b')), {1});
  });

  test('upsert 同 (account, bookmark_id) 覆盖旧 payload', () async {
    await dao.upsertOne(
      'acct',
      _entry(
        bookmarkId: 1,
        name: 'image',
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await dao.upsertOne(
      'acct',
      _entry(
        bookmarkId: 1,
        name: 'beta',
        updatedAt: DateTime.utc(2026, 5, 1),
      ),
    );

    final entries = await dao.readAll('acct');
    expect(entries, hasLength(1));
    expect(entries.single.nameNormalized, 'beta');
    expect(entries.single.updatedAt, DateTime.utc(2026, 5, 1));
  });

  test('deleteByIds 仅删除当前账号匹配项', () async {
    await dao.upsertAll('a', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 3, updatedAt: DateTime.utc(2026, 1, 1)),
    ]);
    await dao.upsertAll('b', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
    ]);

    await dao.deleteByIds('a', {1, 3});

    expect((await dao.allBookmarkIds('a')), {2});
    expect((await dao.allBookmarkIds('b')), {1});
  });

  test('snapshotById 返回 (bookmark_id -> updated_at)', () async {
    await dao.upsertAll('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 2, 1)),
    ]);

    final snapshot = await dao.snapshotById('acct');
    expect(snapshot.keys, {1, 2});
    expect(snapshot[1], DateTime.utc(2026, 1, 1).toIso8601String());
    expect(snapshot[2], DateTime.utc(2026, 2, 1).toIso8601String());
  });

  test('payload 反序列化能还原 _bookmark_* 字段', () async {
    final updatedAt = DateTime.utc(2026, 5, 1);
    await dao.upsertOne(
      'acct',
      _entry(bookmarkId: 42, name: 'image', updatedAt: updatedAt),
    );

    final entries = await dao.readAll('acct');
    final payload = entries.single.payload;
    expect(payload['_bookmark_id'], 42);
    expect(payload['_bookmark_name'], 'image');
    expect(payload['_bookmark_updated_at'], updatedAt.toIso8601String());
  });
}
