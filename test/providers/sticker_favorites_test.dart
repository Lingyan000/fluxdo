import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/providers/sticker_favorites_provider.dart';
import 'package:fluxdo/services/sticker_favorites_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

StickerItem _item(String name) => StickerItem(
  id: 'id-$name',
  name: name,
  url: 'https://cdn.example.com/$name.png',
  width: 100,
  height: 80,
  groupId: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<StickerFavoritesNotifier> newNotifier([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return StickerFavoritesNotifier(
      StickerFavoritesService(await SharedPreferences.getInstance()),
    );
  }

  List<String> namesIn(StickerFavoritesNotifier n, String categoryId) => [
    for (final item in n.state.firstWhere((c) => c.id == categoryId).items)
      item.name,
  ];

  test('首次收藏自动建默认分类并放在最前', () async {
    final n = await newNotifier();
    final custom = await n.createCategory('  猫猫 ');

    await n.add(_item('a'));

    expect(n.state.map((c) => c.id), [
      StickerFavoriteCategory.defaultId,
      custom,
    ]);
    expect(n.state.last.name, '猫猫', reason: '名称去掉首尾空白');
    expect(namesIn(n, StickerFavoriteCategory.defaultId), ['a']);
  });

  test('同一张图只属于一个分类,收藏到别的分类即移动', () async {
    final n = await newNotifier();
    final custom = await n.createCategory('猫猫');
    await n.add(_item('a'));
    await n.add(_item('a'));
    expect(namesIn(n, StickerFavoriteCategory.defaultId), ['a']);

    await n.add(_item('a'), categoryId: custom);

    expect(namesIn(n, StickerFavoriteCategory.defaultId), isEmpty);
    expect(namesIn(n, custom), ['a']);
    expect(n.categoryOf(_item('a').url), custom);
  });

  test('收藏到不存在的自定义分类时不做任何事', () async {
    final n = await newNotifier();

    await n.add(_item('a'), categoryId: 'missing');

    expect(n.state, isEmpty);
  });

  test('批量移动保持原有相对顺序,批量删除', () async {
    final n = await newNotifier();
    final custom = await n.createCategory('猫猫');
    for (final name in ['a', 'b', 'c', 'd']) {
      await n.add(_item(name));
    }

    await n.move({_item('c').url, _item('a').url}, custom);
    expect(namesIn(n, StickerFavoriteCategory.defaultId), ['b', 'd']);
    expect(namesIn(n, custom), ['a', 'c']);

    await n.remove({_item('b').url, _item('c').url});
    expect(namesIn(n, StickerFavoriteCategory.defaultId), ['d']);
    expect(namesIn(n, custom), ['a']);
  });

  test('分类内排序与分类排序:newIndex 为最终位置', () async {
    final n = await newNotifier();
    for (final name in ['a', 'b', 'c']) {
      await n.add(_item(name));
    }
    await n.reorderItems(StickerFavoriteCategory.defaultId, 0, 2);
    expect(namesIn(n, StickerFavoriteCategory.defaultId), ['b', 'c', 'a']);

    final x = await n.createCategory('x');
    await n.reorderCategories(1, 0);
    expect(n.state.first.id, x);
  });

  test('重命名与删除分类(连同其中表情)', () async {
    final n = await newNotifier();
    final custom = await n.createCategory('猫猫');
    await n.add(_item('a'), categoryId: custom);

    await n.renameCategory(custom, '狗狗');
    expect(n.state.single.name, '狗狗');

    await n.deleteCategory(custom);
    expect(n.state, isEmpty);
    expect(n.categoryOf(_item('a').url), isNull);
  });

  test('持久化后重新读取一致,坏数据不崩', () async {
    final n = await newNotifier();
    final custom = await n.createCategory('猫猫');
    await n.add(_item('a'), categoryId: custom);
    final prefs = await SharedPreferences.getInstance();
    final reloaded = StickerFavoritesNotifier(StickerFavoritesService(prefs));
    expect(reloaded.state.single.items.single.url, _item('a').url);

    final broken = await newNotifier({'sticker_favorites': '{not json'});
    expect(broken.state, isEmpty);
  });
}
