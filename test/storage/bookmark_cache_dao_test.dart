import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';

import 'bookmark_hive_test_support.dart';

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
      '_bookmark_name': ?name,
      'title': 'Topic $topicId',
    },
  );
}

void main() {
  late BookmarkHiveTestSupport storage;
  late BookmarkCacheDao dao;

  setUp(() async {
    storage = await BookmarkHiveTestSupport.create();
    dao = BookmarkCacheDao(boxFactory: storage.openBox);
  });

  tearDown(() async {
    await storage.dispose();
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

  test('findOne 按 id 单点读取', () async {
    await dao.upsertAll('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(
        bookmarkId: 2,
        name: 'beta',
        updatedAt: DateTime.utc(2026, 2, 1),
      ),
    ]);

    final hit = await dao.findOne('acct', 2);
    expect(hit, isNotNull);
    expect(hit!.bookmarkId, 2);
    expect(hit.nameNormalized, 'beta');

    final miss = await dao.findOne('acct', 999);
    expect(miss, isNull);
  });

  test('idsOrderedByUpdated 按 updated_at DESC 排序，不解 payload', () async {
    await dao.upsertAll('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 7, updatedAt: DateTime.utc(2026, 3, 1)),
      _entry(bookmarkId: 3, updatedAt: DateTime.utc(2026, 2, 1)),
    ]);

    final ids = await dao.idsOrderedByUpdated('acct');
    expect(ids, [7, 3, 1]);
  });

  test('readByIds 按传入 id 顺序返回，跳过缺失', () async {
    await dao.upsertAll('acct', [
      _entry(
        bookmarkId: 1,
        topicId: 100,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      _entry(
        bookmarkId: 2,
        topicId: 200,
        updatedAt: DateTime.utc(2026, 2, 1),
      ),
      _entry(
        bookmarkId: 3,
        topicId: 300,
        updatedAt: DateTime.utc(2026, 3, 1),
      ),
    ]);

    final picked = await dao.readByIds('acct', [3, 999, 1]);
    expect(picked.map((e) => e.bookmarkId), [3, 1]);
    expect(picked.map((e) => e.topicId), [300, 100]);
  });

  test('readByIds 空列表直接返回空', () async {
    final picked = await dao.readByIds('acct', const []);
    expect(picked, isEmpty);
  });

  test('nameCounts 聚合 name 出现次数，忽略空名', () async {
    await dao.upsertAll('acct', [
      _entry(
        bookmarkId: 1,
        name: 'image',
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      _entry(
        bookmarkId: 2,
        name: 'image',
        updatedAt: DateTime.utc(2026, 2, 1),
      ),
      _entry(
        bookmarkId: 3,
        name: 'beta',
        updatedAt: DateTime.utc(2026, 3, 1),
      ),
      _entry(bookmarkId: 4, updatedAt: DateTime.utc(2026, 4, 1)),
    ]);

    final counts = await dao.nameCounts('acct');
    expect(counts, {'image': 2, 'beta': 1});
  });
}
