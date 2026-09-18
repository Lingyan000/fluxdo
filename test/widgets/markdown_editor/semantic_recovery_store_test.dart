import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_recovery_store.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scope = SemanticRecoveryScope(site: 'https://example.test', userId: 1);
  const other = SemanticRecoveryScope(site: 'https://example.test', userId: 2);
  SemanticRecoveryRecord record(String id, SemanticRecoveryScope owner) =>
      SemanticRecoveryRecord(
        id: id,
        scope: owner,
        savedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        lastRaw: '旧正文',
        tree: SemanticNode(
          'doc',
          content: [
            SemanticNode(
              'paragraph',
              content: [SemanticNode('text', text: '未同步的最后一句')],
            ),
          ],
        ),
        description: '回复编辑器',
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('保存并读取完整语义树和描述，账号及站点严格隔离', () async {
    final store = SemanticRecoveryStore();
    await store.save(record('one', scope));
    await store.save(record('two', other));
    final records = await store.read(scope);
    expect(records, hasLength(1));
    expect(records.single.id, 'one');
    expect(records.single.tree.toJson(), record('one', scope).tree.toJson());
    expect(records.single.preview, '未同步的最后一句');
    expect(records.single.description, '回复编辑器');
    expect(
      await store.read(
        const SemanticRecoveryScope(site: 'https://other.test', userId: 1),
      ),
      isEmpty,
    );
    expect(
      await store.read(
        const SemanticRecoveryScope(site: 'https://example.test', userId: 0),
      ),
      isEmpty,
    );
  });

  test('损坏与旧版无scope记录不暴露也不阻止恢复合法记录', () async {
    final prefs = await SharedPreferences.getInstance();
    final broken = [
      '{',
      jsonEncode({'id': 'legacy', 'lastRaw': '其他账号秘密'}),
      jsonEncode({...record('broken', scope).toJson(), 'semanticTree': 1}),
    ];
    await prefs.setStringList(SemanticRecoveryStore.storageKey, broken);
    final store = SemanticRecoveryStore();
    await store.save(record('valid', scope));
    expect((await store.read(scope)).single.id, 'valid');
    await store.remove(scope, 'valid');
    expect(prefs.getStringList(SemanticRecoveryStore.storageKey), broken);
  });

  test('save和remove按调用顺序执行，不误删同id其他账号记录', () async {
    final store = SemanticRecoveryStore();
    final first = store.save(record('same', scope));
    final second = store.save(record('same', other));
    final removal = store.remove(scope, 'same');
    await Future.wait([first, second, removal]);
    expect(await store.read(scope), isEmpty);
    expect((await store.read(other)).single.id, 'same');
  });
}
