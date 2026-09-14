import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/services/local_draft_store.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory directory;
  late Box<Map> box;
  late LocalDraftStore store;
  var id = 0;
  const old = DraftData(reply: '已同步的旧正文');
  const remote = DraftData(reply: '云端新正文');
  const edit = DraftData(reply: '本地未上传修改');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('draft_sync_');
    box = await Hive.openBox<Map>('draft_sync_${id++}', path: directory.path);
    store = LocalDraftStore(boxFactory: () async => box);
  });
  tearDown(() async {
    await box.close();
    await directory.delete(recursive: true);
  });

  test('拉取云端可替换已知旧缓存，不会被只允许相同正文的确认逻辑拦住', () async {
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_1',
      data: old,
      sequence: 1,
      synced: true,
    );
    expect(
      await store.recordSync(
        accountId: 'alice',
        draftKey: 'topic_1',
        data: remote,
        sequence: 2,
        synced: true,
        baseFingerprint: remote.contentFingerprint,
        expectedFingerprint: old.contentFingerprint,
      ),
      isTrue,
    );
    final cached = (await store.read('alice', 'topic_1'))!;
    expect(cached.data.reply, remote.reply);
    expect(cached.sequence, 2);
    expect(cached.synced, isTrue);
  });

  test('慢速拉取不得覆盖另一个编辑器已经写下的新内容', () async {
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_1',
      data: edit,
      sequence: 1,
    );
    expect(
      await store.recordSync(
        accountId: 'alice',
        draftKey: 'topic_1',
        data: remote,
        sequence: 2,
        synced: true,
        expectedFingerprint: old.contentFingerprint,
      ),
      isFalse,
    );
    expect((await store.read('alice', 'topic_1'))!.data.reply, edit.reply);
  });

  test('云端列表更新旧缓存，保留未上传修改以及不在当前分页的草稿', () async {
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_1',
      data: old,
      sequence: 1,
      synced: true,
    );
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_2',
      data: edit,
      sequence: 1,
      baseFingerprint: old.contentFingerprint,
    );
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_3',
      data: old,
      sequence: 1,
      synced: true,
    );
    await store.cacheRemoteDrafts('alice', [
      const Draft(draftKey: 'topic_1', data: remote, sequence: 2),
      const Draft(draftKey: 'topic_2', data: remote, sequence: 2),
      const Draft(draftKey: 'topic_4', data: remote, sequence: 2),
    ]);
    final cached = await store.list('alice');
    expect(cached['topic_1']!.data.reply, remote.reply);
    expect(cached['topic_2']!.data.reply, edit.reply);
    expect(cached['topic_2']!.hasLocalChanges, isTrue);
    expect(cached['topic_3'], isNotNull);
    expect(cached['topic_4']!.data.reply, remote.reply);
    expect(mergeLocalDrafts([], cached, serverAvailable: false), hasLength(4));
  });

  test('旧版保存的基线指纹按同样规则规范化，空字段不制造冲突', () async {
    const data = DraftData(reply: '正文', action: 'reply');
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_1',
      data: data,
      sequence: 1,
      baseFingerprint: data.toJsonString(),
    );
    final cached = (await store.read('alice', 'topic_1'))!;
    expect(cached.baseFingerprint, data.contentFingerprint);
    expect(cached.hasLocalChanges, isFalse);
  });
}
