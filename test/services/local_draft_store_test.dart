import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/services/local_draft_store.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  late Box<Map> box;
  late DateTime now;
  var sequence = 0;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('local_draft_store_test_');
    box = await Hive.openBox<Map>(
      'local_drafts_${sequence++}',
      path: tempDir.path,
    );
    now = DateTime.utc(2026, 6, 13, 12);
  });

  tearDown(() async {
    if (box.isOpen) await box.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  LocalDraftStore createStore() =>
      LocalDraftStore(boxFactory: () async => box, now: () => now);

  test('云端确认只更新对应版本，不能覆盖较新的本地输入', () async {
    final store = createStore();
    const old = DraftData(reply: 'A');
    const current = DraftData(reply: 'B');
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_1',
      data: current,
      sequence: 2,
    );
    expect(
      await store.recordSync(
        accountId: 'alice',
        draftKey: 'topic_1',
        data: old,
        sequence: 3,
        synced: true,
      ),
      isFalse,
    );
    expect((await store.read('alice', 'topic_1'))!.data.reply, 'B');
    expect(
      await store.recordSync(
        accountId: 'alice',
        draftKey: 'topic_1',
        data: current,
        sequence: 4,
        synced: true,
        baseFingerprint: current.contentFingerprint,
      ),
      isTrue,
    );
    final saved = (await store.read('alice', 'topic_1'))!;
    expect(saved.synced, isTrue);
    expect(saved.sequence, 4);
    expect(saved.baseFingerprint, current.contentFingerprint);
  });

  test('离线列表包含本地私信、隔离账号并隐藏待删除稿', () async {
    final store = createStore();
    const key = 'new_private_message_123';
    const pm = DraftData(
      reply: '离线内容',
      title: '私信',
      action: 'privateMessage',
      recipients: ['bob'],
    );
    await store.write(accountId: 'alice', draftKey: key, data: pm, sequence: 0);
    await store.write(
      accountId: 'other',
      draftKey: 'topic_2',
      data: const DraftData(reply: '其他账号'),
      sequence: 0,
    );
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_3',
      data: const DraftData(),
      sequence: 1,
    );
    final local = await store.list('alice');
    expect(local.keys, unorderedEquals([key, 'topic_3']));
    final drafts = mergeLocalDrafts([], local, serverAvailable: false);
    expect(drafts.single.draftKey, key);
    expect(drafts.single.data.recipients, ['bob']);
  });

  test('在线列表不会复活已同步且已被远端删除的缓存', () {
    final local = {
      'topic_1': LocalDraftEntry(
        data: const DraftData(reply: '旧缓存'),
        sequence: 1,
        updatedAt: now,
        synced: true,
      ),
      'topic_2': LocalDraftEntry(
        data: const DraftData(reply: '待同步'),
        sequence: 2,
        updatedAt: now,
      ),
    };
    expect(
      mergeLocalDrafts([], local, serverAvailable: true).single.draftKey,
      'topic_2',
    );
    expect(mergeLocalDrafts([], local, serverAvailable: false), hasLength(2));
  });

  test('按账号和 draftKey 隔离并完整恢复草稿数据', () async {
    final store = createStore();
    const data = DraftData(
      title: '标题',
      reply: '正文',
      categoryId: 7,
      tags: ['flutter', 'desktop'],
      action: 'createTopic',
    );

    await store.write(
      accountId: 'alice',
      draftKey: Draft.newTopicKey,
      data: data,
      sequence: 3,
    );

    final restored = await store.read('alice', Draft.newTopicKey);
    expect(restored, isNotNull);
    expect(restored!.data.toJson(), data.toJson());
    expect(restored.sequence, 3);
    expect(restored.updatedAt, now);
    expect(await store.read('bob', Draft.newTopicKey), isNull);
    expect(await store.read('alice', 'topic_42'), isNull);
  });

  test('条件删除不会让旧保存结果误删更新后的本地内容', () async {
    final store = createStore();
    const oldData = DraftData(reply: '旧内容', action: 'reply');
    const newData = DraftData(reply: '新内容', action: 'reply');

    await store.write(
      accountId: 'alice',
      draftKey: 'topic_42',
      data: newData,
      sequence: 5,
    );

    expect(
      await store.deleteIfMatches(
        accountId: 'alice',
        draftKey: 'topic_42',
        data: oldData,
      ),
      isFalse,
    );
    expect((await store.read('alice', 'topic_42'))!.data.reply, '新内容');

    expect(
      await store.deleteIfMatches(
        accountId: 'alice',
        draftKey: 'topic_42',
        data: newData,
      ),
      isTrue,
    );
    expect(await store.read('alice', 'topic_42'), isNull);
  });

  test('读取时清理超过保留期的本地草稿', () async {
    final store = createStore();
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_42',
      data: const DraftData(reply: '过期内容', action: 'reply'),
      sequence: 1,
    );

    now = now.add(const Duration(days: 31));

    expect(await store.read('alice', 'topic_42'), isNull);
    expect(box.isEmpty, isTrue);
  });
}
