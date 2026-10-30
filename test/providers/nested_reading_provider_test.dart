import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/models/nested_reading_position.dart';
import 'package:fluxdo/providers/nested_reading_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('续读按最后停留而非最高楼层保存，重启后恢复帖子中段和展开状态', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = NestedReadingStore(prefs, 'alice');
    store.save(
      1,
      const NestedReadingPosition(postNumber: 100, rootPostNumber: 2),
    );
    store.save(
      1,
      const NestedReadingPosition(
        postNumber: 20,
        rootPostNumber: 3,
        offset: -360,
        sort: 'new',
        expanded: {3: true, 8: false},
      ),
    );
    await store.flush();
    final reopened = NestedReadingStore(prefs, 'alice');
    final restored = reopened.position(1)!;
    expect(restored.postNumber, 20);
    expect(restored.rootPostNumber, 3);
    expect(restored.offset, -360);
    expect(restored.sort, 'new');
    expect(restored.expanded, {3: true, 8: false});
    expect(NestedReadingStore(prefs, 'bob').position(1), isNull);
    store.dispose();
    reopened.dispose();
  });

  test('同一话题不同页面的临时现场隔离，磁盘只保留最近 200 个话题', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = NestedReadingStore(prefs, 'alice');
    final first = store.session('first');
    first.expanded[3] = true;
    first.scrollOffset = 900;
    expect(identical(store.session('first'), first), isTrue);
    expect(store.session('second').expanded, isEmpty);
    for (var topic = 1; topic <= 201; topic++) {
      store.save(
        topic,
        const NestedReadingPosition(postNumber: 2, rootPostNumber: 2),
      );
    }
    await store.flush();
    final reopened = NestedReadingStore(prefs, 'alice');
    expect(reopened.position(1), isNull);
    expect(reopened.position(201)?.postNumber, 2);
    expect(reopened.existingSession('first'), isNull);
    store.dispose();
    reopened.dispose();
  });

  test('损坏的落点不会阻止打开话题，排序按账号保存', () async {
    SharedPreferences.setMockInitialValues({
      'nested_reading_v1_alice': '{broken',
    });
    final prefs = await SharedPreferences.getInstance();
    final store = NestedReadingStore(prefs, 'alice');
    expect(store.position(1), isNull);
    await store.setSort('top');
    expect(NestedReadingStore(prefs, 'alice').sort, 'top');
    expect(NestedReadingStore(prefs, 'bob').sort, 'old');
    expect(NestedReadingPosition.fromJson({'post': -1, 'root': 3}), isNull);
    store.dispose();
  });
}
