import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/services/local_draft_store.dart';

import '../helpers/memory_draft_store.dart';

const _key = 'topic_1';
const _a = DraftData(reply: '共同起点', action: 'reply');
const _b = DraftData(reply: '设备 A 的修改', action: 'reply');
const _c = DraftData(reply: '设备 B 的修改', action: 'reply');

class _Server extends Fake implements DiscourseService {
  Draft? draft = const Draft(draftKey: _key, data: _a, sequence: 1);
  Future<Draft?> Function()? read;
  bool loseResponse = false;
  final writes = <({DraftData data, int sequence, bool force})>[];

  @override
  Future<Draft?> getDraft(String key) async => read == null ? draft : read!();

  @override
  Future<int> saveDraft({
    required String draftKey,
    required DraftData data,
    int sequence = 0,
    bool forceSave = false,
  }) async {
    writes.add((data: data, sequence: sequence, force: forceSave));
    if (!forceSave && draft != null && sequence != draft!.sequence) {
      throw const DraftSequenceConflictException();
    }
    final next = draft == null ? sequence : draft!.sequence + 1;
    draft = Draft(draftKey: draftKey, data: data, sequence: next);
    if (loseResponse) {
      loseResponse = false;
      throw StateError('response lost after server saved');
    }
    return next;
  }

  @override
  Future<void> deleteDraft(String key, {int sequence = 0}) async {
    if (draft?.sequence == sequence) draft = null;
  }
}

class _Device {
  _Device(_Server server, {MemoryDraftStore? cache})
    : store = cache ?? MemoryDraftStore() {
    controller = DraftController(
      draftKey: _key,
      service: server,
      localStore: store,
      accountIdResolver: () async => 'alice',
      connectionStream: connectivity.stream,
      isConnected: () => online,
      onRemoteDraftChanged: (data) => displayed = data,
    );
    addTearDown(() async {
      controller.dispose();
      await connectivity.close();
    });
  }
  final MemoryDraftStore store;
  final connectivity = StreamController<bool>.broadcast(sync: true);
  late final DraftController controller;
  bool online = true;
  DraftData? displayed;

  Future<void> open(WidgetTester tester) async {
    final load = controller.loadDraft();
    await tester.pump();
    displayed = (await load)?.data;
  }

  Future<void> save(WidgetTester tester, DraftData data) async {
    displayed = data;
    final pending = controller.saveNow(data);
    await tester.pump();
    await pending;
  }

  Future<void> refresh(WidgetTester tester) async {
    final pending = controller.retryPending();
    await tester.pump();
    await pending;
  }
}

void main() {
  testWidgets('云端仅改变标签表示格式时不冲突也不重复保存', (tester) async {
    const data = DraftData(reply: '正文', tags: ['纯水', '快问快答']);
    final server = _Server()
      ..draft = const Draft(draftKey: _key, data: data, sequence: 1);
    final device = _Device(server);
    await device.open(tester);
    server.draft = Draft.fromJson({
      'draft_key': _key,
      'draft_sequence': 2,
      'data': {
        'reply': '正文',
        'tags': [
          {'name': '纯水'},
          {'id': 42, 'name': '快问快答'},
        ],
      },
    });

    await device.refresh(tester);
    await device.save(tester, data);

    expect(device.displayed?.tags, data.tags);
    expect(device.controller.hasConflict, isFalse);
    expect(device.controller.status, DraftSaveStatus.saved);
    expect(device.store.entry?.data.tags, data.tags);
    expect(device.store.entry?.sequence, 2);
    expect(device.store.entry?.synced, isTrue);
    expect(server.writes, isEmpty);
  });

  testWidgets('云端响应前收取富文本尚未镜像的新输入，不能把它当成干净缓存覆盖', (tester) async {
    final server = _Server();
    final store = MemoryDraftStore();
    var visible = _a;
    final controller = DraftController(
      draftKey: _key,
      service: server,
      localStore: store,
      accountIdResolver: () async => 'alice',
      connectionStream: const Stream.empty(),
      isConnected: () => true,
      currentEditorData: () => visible,
      onRemoteDraftChanged: (data) => visible = data,
    );
    final load = controller.loadDraft();
    await tester.pump();
    await load;
    final response = Completer<Draft?>();
    server.read = () => response.future;
    final refresh = controller.retryPending();
    await tester.pump();
    visible = _b; // 模拟富文本内核已改变，800ms 镜像尚未触发。
    response.complete(const Draft(draftKey: _key, data: _c, sequence: 2));
    await tester.pump();
    await refresh;
    expect(controller.hasConflict, isTrue);
    expect(visible.reply, _b.reply);
    expect(store.entry?.data.reply, _b.reply);
    expect(server.writes, isEmpty);
    controller.dispose();
  });

  testWidgets('打开已同步旧缓存时采用云端最新内容并更新本地，不误报冲突', (tester) async {
    final server = _Server()
      ..draft = const Draft(draftKey: _key, data: _b, sequence: 2);
    final cache = MemoryDraftStore()
      ..entry = LocalDraftEntry(
        data: _a,
        sequence: 1,
        updatedAt: DateTime.now(),
        synced: true,
      );
    final device = _Device(server, cache: cache);
    await device.open(tester);
    expect(device.displayed?.reply, _b.reply);
    expect(cache.entry?.data.reply, _b.reply);
    expect(cache.entry?.sequence, 2);
    expect(cache.entry?.synced, isTrue);
    expect(device.controller.status, DraftSaveStatus.saved);
    expect(server.writes, isEmpty);
  });

  testWidgets('两台设备交替编辑，回到前台拉取后能沿同一草稿继续保存', (tester) async {
    final server = _Server();
    final left = _Device(server);
    final right = _Device(server);
    await left.open(tester);
    await right.open(tester);
    await left.save(tester, _b);
    await right.refresh(tester);
    expect(right.displayed?.reply, _b.reply);
    expect(right.store.entry?.data.reply, _b.reply);
    await right.save(tester, _c);
    await left.refresh(tester);
    expect(left.displayed?.reply, _c.reply);
    expect(left.store.entry?.data.reply, _c.reply);
    expect(left.controller.sequence, right.controller.sequence);
    expect(server.writes.map((write) => write.force), [false, false]);
  });

  testWidgets('已保存缓存离线恢复后重连，即使没有输入也拉取云端新内容', (tester) async {
    final server = _Server();
    final cache = MemoryDraftStore()
      ..entry = LocalDraftEntry(
        data: _a,
        sequence: 1,
        updatedAt: DateTime.now(),
        synced: true,
      );
    final device = _Device(server, cache: cache)..online = false;
    await device.open(tester);
    server.draft = const Draft(draftKey: _key, data: _b, sequence: 2);
    device.online = true;
    device.connectivity.add(true);
    await tester.pump();
    expect(device.displayed?.reply, _b.reply);
    expect(cache.entry?.data.reply, _b.reply);
    expect(server.writes, isEmpty);
  });

  testWidgets('两端都有修改时保留内容，选择云端后替换本地并可正常继续保存', (tester) async {
    final server = _Server();
    final left = _Device(server);
    final right = _Device(server);
    await left.open(tester);
    await right.open(tester);
    left.online = false;
    await left.save(tester, _b);
    await right.save(tester, _c);
    left.online = true;
    await left.refresh(tester);
    expect(left.controller.hasConflict, isTrue);
    expect(left.store.entry?.data.reply, _b.reply);
    expect(server.draft?.data.reply, _c.reply);
    expect(server.writes, hasLength(1));
    final reload = left.controller.reloadFromRemote();
    await tester.pump();
    expect(await reload, isTrue);
    expect(left.displayed?.reply, _c.reply);
    expect(left.store.entry?.data.reply, _c.reply);
    expect(left.store.entry?.synced, isTrue);
    expect(left.controller.hasConflict, isFalse);
    await left.save(tester, const DraftData(reply: '从云端版本继续写'));
    expect(server.writes.last.force, isFalse);
    expect(left.controller.status, DraftSaveStatus.saved);
  });

  testWidgets('明确覆盖云端后，另一设备也能拉回同一版本', (tester) async {
    final server = _Server();
    final left = _Device(server);
    final right = _Device(server);
    await left.open(tester);
    await right.open(tester);
    await left.save(tester, _b);
    await right.save(tester, _c);
    expect(right.controller.hasConflict, isTrue);
    final force = right.controller.saveNow(_c, forceSave: true);
    await tester.pump();
    await force;
    await left.refresh(tester);
    expect(server.writes.last.force, isTrue);
    expect(left.displayed?.reply, _c.reply);
    expect(left.store.entry?.data.reply, right.store.entry?.data.reply);
  });

  testWidgets('仅版本号变化而云端内容仍为共同基线，409 后正常重试无需强制覆盖', (tester) async {
    final server = _Server();
    final device = _Device(server);
    await device.open(tester);
    server.draft = const Draft(draftKey: _key, data: _a, sequence: 5);
    await device.save(tester, _b);
    expect(server.writes.map((w) => w.sequence), [1, 5]);
    expect(server.writes.every((w) => !w.force), isTrue);
    expect(device.controller.status, DraftSaveStatus.saved);
  });

  testWidgets('云端已保存但响应丢失，重连只确认已有内容，不生成重复保存', (tester) async {
    final server = _Server();
    final device = _Device(server);
    await device.open(tester);
    server.loseResponse = true;
    await device.save(tester, _b);
    await device.refresh(tester);
    expect(server.writes, hasLength(1));
    expect(device.controller.status, DraftSaveStatus.saved);
    expect(device.store.entry?.synced, isTrue);
  });

  for (final dirty in [false, true]) {
    testWidgets('另一设备已删除或发送草稿，清理缓存且不自动复活 dirty=$dirty', (tester) async {
      final server = _Server();
      final device = _Device(server);
      await device.open(tester);
      if (dirty) {
        device.online = false;
        await device.save(tester, _b);
        device.online = true;
      }
      server.draft = null;
      await device.refresh(tester);
      if (dirty) {
        expect(device.controller.hasConflict, isTrue);
        expect(device.store.entry?.data.reply, _b.reply);
        final reload = device.controller.reloadFromRemote();
        await tester.pump();
        expect(await reload, isTrue);
      }
      expect(device.displayed?.hasContent, isFalse);
      expect(device.store.entry, isNull);
      expect(server.writes, isEmpty);
      expect(device.controller.status, DraftSaveStatus.idle);
    });
  }

  testWidgets('拉取云端期间继续输入，不覆盖刚输入的内容', (tester) async {
    final server = _Server();
    final device = _Device(server);
    await device.open(tester);
    final remote = Completer<Draft?>();
    server.read = () => remote.future;
    final reload = device.controller.reloadFromRemote();
    await tester.pump();
    device.controller.scheduleSave(_b);
    remote.complete(const Draft(draftKey: _key, data: _c, sequence: 3));
    await tester.pump();
    expect(await reload, isFalse);
    expect(device.store.entry?.data.reply, _b.reply);
    expect(device.controller.hasConflict, isTrue);
    expect(server.writes, isEmpty);
  });

  testWidgets('选择云端但请求失败，保持本地内容和未解决冲突', (tester) async {
    final server = _Server();
    final device = _Device(server);
    await device.open(tester);
    server.draft = const Draft(draftKey: _key, data: _c, sequence: 2);
    await device.save(tester, _b);
    server.read = () => Future.error(StateError('network down'));
    final reload = device.controller.reloadFromRemote();
    await tester.pump();
    expect(await reload, isFalse);
    expect(device.store.entry?.data.reply, _b.reply);
    expect(device.controller.hasConflict, isTrue);
  });
}
