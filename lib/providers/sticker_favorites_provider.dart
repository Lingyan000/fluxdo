import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';

import '../models/sticker.dart';
import '../services/sticker_favorites_service.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

final stickerFavoritesServiceProvider = Provider<StickerFavoritesService>((
  ref,
) {
  return StickerFavoritesService(ref.watch(sharedPreferencesProvider));
});

/// 收藏表情(按分类,顺序即面板里的展示顺序)。
final stickerFavoritesProvider =
    StateNotifierProvider<
      StickerFavoritesNotifier,
      List<StickerFavoriteCategory>
    >((ref) {
      return StickerFavoritesNotifier(
        ref.watch(stickerFavoritesServiceProvider),
      );
    });

class StickerFavoritesNotifier
    extends StateNotifier<List<StickerFavoriteCategory>> {
  StickerFavoritesNotifier(this._service) : super(_service.load());

  final StickerFavoritesService _service;

  Future<void> _commit(List<StickerFavoriteCategory> next) async {
    state = List.unmodifiable(next);
    await _service.save(next);
  }

  /// 图片所在的分类 id(未收藏为 null)。
  String? categoryOf(String url) {
    for (final c in state) {
      if (c.items.any((item) => item.url == url)) return c.id;
    }
    return null;
  }

  /// 收藏到 [categoryId](默认分类不存在时自动创建并放在最前)。
  /// 已在别的分类里则移过去,已在目标分类里则不动。
  Future<void> add(
    StickerItem item, {
    String categoryId = StickerFavoriteCategory.defaultId,
  }) async {
    if (categoryOf(item.url) == categoryId) return;
    var next = _without({item.url});
    if (!next.any((c) => c.id == categoryId)) {
      if (categoryId != StickerFavoriteCategory.defaultId) return;
      next = [
        const StickerFavoriteCategory(
          id: StickerFavoriteCategory.defaultId,
          name: '',
        ),
        ...next,
      ];
    }
    await _commit([
      for (final c in next)
        c.id == categoryId ? c.copyWith(items: [...c.items, item]) : c,
    ]);
  }

  Future<void> remove(Set<String> urls) => _commit(_without(urls));

  /// 把 [urls] 移到 [categoryId] 末尾,保持它们原来的相对顺序。
  Future<void> move(Set<String> urls, String categoryId) async {
    if (!state.any((c) => c.id == categoryId)) return;
    final moving = [
      for (final c in state)
        for (final item in c.items)
          if (urls.contains(item.url)) item,
    ];
    final next = _without(urls);
    await _commit([
      for (final c in next)
        c.id == categoryId ? c.copyWith(items: [...c.items, ...moving]) : c,
    ]);
  }

  /// 分类内拖拽排序([newIndex] 为移除后的最终位置)。
  Future<void> reorderItems(String categoryId, int oldIndex, int newIndex) {
    return _commit([
      for (final c in state)
        c.id == categoryId
            ? c.copyWith(items: _moved(c.items, oldIndex, newIndex))
            : c,
    ]);
  }

  /// 新建分类,返回其 id。
  Future<String> createCategory(String name) async {
    final id = 'c${DateTime.now().microsecondsSinceEpoch}';
    await _commit([
      ...state,
      StickerFavoriteCategory(id: id, name: name.trim()),
    ]);
    return id;
  }

  Future<void> renameCategory(String id, String name) => _commit([
    for (final c in state) c.id == id ? c.copyWith(name: name.trim()) : c,
  ]);

  /// 删除分类及其中的表情。
  Future<void> deleteCategory(String id) => _commit([
    for (final c in state)
      if (c.id != id) c,
  ]);

  Future<void> reorderCategories(int oldIndex, int newIndex) =>
      _commit(_moved(state, oldIndex, newIndex));

  List<StickerFavoriteCategory> _without(Set<String> urls) => [
    for (final c in state)
      c.items.any((item) => urls.contains(item.url))
          ? c.copyWith(
              items: [
                for (final item in c.items)
                  if (!urls.contains(item.url)) item,
              ],
            )
          : c,
  ];

  static List<T> _moved<T>(List<T> list, int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= list.length) return list;
    final next = [...list];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), item);
    return next;
  }
}
