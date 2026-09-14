import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/services/local_draft_store.dart';
import '../helpers/memory_draft_store.dart';

class DraftService extends Fake implements DiscourseService {
  Draft? server;
  Future<Draft?> Function()? get;
  Future<int> Function(DraftData, int, bool)? save;
  final requests = <({DraftData data, int sequence, bool force})>[];
  int deletes = 0;
  @override
  Future<Draft?> getDraft(String key) async =>
      get == null ? server : await get!();
  @override
  Future<int> saveDraft({
    required String draftKey,
    required DraftData data,
    int sequence = 0,
    bool forceSave = false,
  }) async {
    requests.add((data: data, sequence: sequence, force: forceSave));
    final result = save == null
        ? sequence + 1
        : await save!(data, sequence, forceSave);
    server = Draft(draftKey: draftKey, data: data, sequence: result);
    return result;
  }

  @override
  Future<void> deleteDraft(String key, {int sequence = 0}) async {
    deletes++;
    server = null;
  }
}

DraftController create(
  DraftService service,
  MemoryDraftStore store, {
  bool Function()? online,
  Stream<bool>? stream,
}) => DraftController(
  draftKey: 'topic_1',
  service: service,
  localStore: store,
  accountIdResolver: () async => 'test',
  isConnected: online ?? () => true,
  connectionStream: stream ?? const Stream.empty(),
);
const a = DraftData(reply: 'A', action: 'reply');
const b = DraftData(reply: 'B', action: 'reply');

void main() {
  testWidgets('未加载草稿的首次保存也不覆盖同 sequence 的未知云端版本', (tester) async {
    final service = DraftService()
      ..server = const Draft(draftKey: 'topic_1', data: b, sequence: 0);
    final store = MemoryDraftStore();
    final c = create(service, store);
    final save = c.saveNow(a);
    await tester.pump();
    await save;
    expect(service.requests, isEmpty);
    expect(c.status, DraftSaveStatus.conflict);
    expect(store.entry?.data.reply, 'A');
    c.dispose();
  });
  testWidgets('已排队的删除不被前一保存失败丢掉', (tester) async {
    final pending = Completer<int>();
    final service = DraftService()..save = (_, _, _) => pending.future;
    final store = MemoryDraftStore();
    final c = create(service, store);
    final save = c.saveNow(a);
    await tester.pump();
    c.disable();
    c.syncSequence(2);
    final deletion = c.deleteDraft();
    service.server = const Draft(draftKey: 'topic_1', data: a, sequence: 2);
    pending.completeError(StateError('response lost'));
    await tester.pump();
    await save;
    await deletion;
    expect(service.server, isNull);
    expect(store.entry, isNull);
    expect(c.status, DraftSaveStatus.idle);
    c.dispose();
  });
  testWidgets('页面关闭后账号切换，不把旧账号草稿上传到新账号', (tester) async {
    var account = 'alice';
    final service = DraftService();
    final store = MemoryDraftStore();
    final c = DraftController(
      draftKey: 'topic_1',
      service: service,
      localStore: store,
      accountIdResolver: () async => account,
      connectionStream: const Stream.empty(),
      isConnected: () => true,
    );
    c.scheduleSave(a);
    await tester.pump();
    account = 'bob';
    final save = c.saveNow(a);
    c.dispose();
    await tester.pump();
    await save;
    expect(service.requests, isEmpty);
    expect(store.entry?.data.reply, 'A');
  });
  testWidgets('持续输入即时写本地，在线保存最长等待 15 秒', (tester) async {
    final service = DraftService();
    final store = MemoryDraftStore();
    final c = create(service, store);
    for (var i = 0; i < 60; i++) {
      c.scheduleSave(DraftData(reply: 'line $i', action: 'reply'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.entry?.data.reply, 'line $i');
    }
    expect(service.requests, isNotEmpty);
    await tester.pump(const Duration(seconds: 2));
    expect(service.requests.last.data.reply, 'line 59');
    expect(store.entry?.synced, isTrue);
    c.dispose();
  });

  testWidgets('关闭不会截断已接受的保存任务，云端确认后仍保留本地缓存', (tester) async {
    final service = DraftService();
    final store = MemoryDraftStore();
    final c = create(service, store);
    final saving = c.saveNow(a);
    c.dispose();
    await tester.pump();
    await saving;
    expect(service.requests.single.data.reply, 'A');
    expect(store.entry?.data.reply, 'A');
    expect(store.entry?.synced, isTrue);
  });

  testWidgets('409 不自动覆盖，只有明确 forceSave 才使用官方强制保存参数', (tester) async {
    final service = DraftService()
      ..save = (_, _, force) async {
        if (!force) throw const DraftSequenceConflictException();
        return 12;
      };
    final store = MemoryDraftStore();
    final c = create(service, store);
    final first = c.saveNow(a);
    await tester.pump();
    await first;
    expect(service.requests, hasLength(1));
    expect(c.status, DraftSaveStatus.conflict);
    expect(store.entry?.data.reply, 'A');
    final second = c.saveNow(a, forceSave: true);
    await tester.pump();
    await second;
    expect(service.requests.map((r) => r.force), [false, true]);
    expect(c.status, DraftSaveStatus.saved);
    c.dispose();
  });

  testWidgets('串行发送，正在写入时的新保存等待前一请求完成', (tester) async {
    final first = Completer<int>();
    final second = Completer<int>();
    final service = DraftService()
      ..save = (data, _, _) => data.reply == 'A' ? first.future : second.future;
    final store = MemoryDraftStore();
    final c = create(service, store);
    final one = c.saveNow(a);
    await tester.pump();
    final two = c.saveNow(b);
    await tester.pump();
    expect(service.requests, hasLength(1));
    first.complete(1);
    await tester.pump();
    expect(service.requests, hasLength(2));
    expect(service.requests.last.sequence, 1);
    second.complete(2);
    await tester.pump();
    await one;
    await two;
    expect(c.sequence, 2);
    expect(store.entry?.data.reply, 'B');
    c.dispose();
  });

  testWidgets('同一轮多个保存合并为最新快照', (tester) async {
    final service = DraftService();
    final store = MemoryDraftStore();
    final c = create(service, store);
    final one = c.saveNow(a);
    final two = c.saveNow(b);
    await tester.pump();
    await one;
    await two;
    expect(service.requests, hasLength(1));
    expect(service.requests.single.data.reply, 'B');
    c.dispose();
  });

  testWidgets('撤销回已保存内容会取消尚未发出的中间版本', (tester) async {
    final service = DraftService()
      ..server = const Draft(draftKey: 'topic_1', data: a);
    final store = MemoryDraftStore();
    final c = create(service, store);
    final load = c.loadDraft();
    await tester.pump();
    await load;
    c.scheduleSave(b);
    await tester.pump(const Duration(milliseconds: 100));
    c.scheduleSave(a);
    await tester.pump(const Duration(seconds: 3));
    expect(service.requests, isEmpty);
    expect(store.entry?.data.reply, 'A');
    c.dispose();
  });

  testWidgets('中间版本已在发送时，撤销内容会在它完成后补写', (tester) async {
    final pending = Completer<int>();
    final service = DraftService()
      ..server = const Draft(draftKey: 'topic_1', data: a)
      ..save = (data, seq, _) =>
          data.reply == 'B' ? pending.future : Future.value(seq + 1);
    final store = MemoryDraftStore();
    final c = create(service, store);
    final load = c.loadDraft();
    await tester.pump();
    await load;
    final save = c.saveNow(b);
    await tester.pump();
    c.scheduleSave(a);
    pending.complete(1);
    await tester.pump();
    await save;
    expect(service.requests.map((r) => r.data.reply), ['B', 'A']);
    expect(service.server?.data.reply, 'A');
    c.dispose();
  });

  testWidgets('在线恢复先核对云端，未上传本地稿冲突时保留两端并停止上传', (tester) async {
    final remote = Completer<Draft?>();
    final service = DraftService()..get = () => remote.future;
    final store = MemoryDraftStore()
      ..entry = LocalDraftEntry(
        data: a,
        sequence: 2,
        updatedAt: DateTime.now(),
      );
    final c = create(service, store);
    final load = c.loadDraft();
    await tester.pump();
    expect(c.sequence, 2);
    remote.complete(const Draft(draftKey: 'topic_1', data: b, sequence: 9));
    await tester.pump();
    expect((await load)?.data.reply, 'A');
    expect(c.status, DraftSaveStatus.conflict);
    expect(service.requests, isEmpty);
    expect(c.sequence, 2);
    c.dispose();
  });

  testWidgets('本地读失败仍能恢复有效云端草稿', (tester) async {
    final service = DraftService()
      ..server = const Draft(draftKey: 'topic_1', data: b, sequence: 3);
    final store = MemoryDraftStore()
      ..readError = StateError('disk unavailable');
    final c = create(service, store);
    final load = c.loadDraft();
    await tester.pump();
    expect((await load)?.data.reply, 'B');
    c.dispose();
  });

  testWidgets('离线写本地，恢复连接后不必继续输入就能同步', (tester) async {
    var online = false;
    final stream = StreamController<bool>.broadcast(sync: true);
    final service = DraftService();
    final store = MemoryDraftStore();
    final c = create(
      service,
      store,
      online: () => online,
      stream: stream.stream,
    );
    c.scheduleSave(a);
    await tester.pump(const Duration(seconds: 3));
    expect(store.entry?.data.reply, 'A');
    expect(service.requests, isEmpty);
    expect(c.status, DraftSaveStatus.local);
    online = true;
    stream.add(true);
    await tester.pump();
    expect(service.requests.single.data.reply, 'A');
    expect(c.status, DraftSaveStatus.saved);
    c.dispose();
    unawaited(stream.close());
  });

  testWidgets('离线舍弃保留删除意图，再次打开不会复活旧云端内容', (tester) async {
    var online = true;
    final service = DraftService()
      ..server = const Draft(draftKey: 'topic_1', data: a);
    final store = MemoryDraftStore();
    final c = create(service, store, online: () => online);
    final load = c.loadDraft();
    await tester.pump();
    await load;
    online = false;
    final deletion = c.deleteDraft();
    await tester.pump();
    await deletion;
    expect(store.entry?.data.hasContent, isFalse);
    expect(service.deletes, 0);
    c.dispose();
    online = true;
    final next = create(service, store, online: () => online);
    final restored = next.loadDraft();
    await tester.pump();
    expect(await restored, isNull);
    await tester.pump();
    expect(service.server, isNull);
    expect(store.entry, isNull);
    next.dispose();
  });

  testWidgets('会话时长不触发重复保存', (tester) async {
    final service = DraftService()
      ..server = Draft(
        draftKey: 'topic_1',
        data: a.copyWith(composerTime: 9000, typingTime: 5000),
      );
    final store = MemoryDraftStore();
    final c = create(service, store);
    final load = c.loadDraft();
    await tester.pump();
    await load;
    c.scheduleSave(a);
    await tester.pump(const Duration(seconds: 3));
    expect(service.requests, isEmpty);
    c.dispose();
  });

  testWidgets('本地和云端都未保存时不会误报本机已保存', (tester) async {
    final service = DraftService()
      ..save = (_, _, _) => Future.error(StateError('network down'));
    final store = MemoryDraftStore()..failWrite = true;
    final c = create(service, store);
    final save = c.saveNow(a);
    await tester.pump();
    await save;
    expect(c.status, DraftSaveStatus.error);
    expect(store.entry, isNull);
    c.dispose();
  });
}
