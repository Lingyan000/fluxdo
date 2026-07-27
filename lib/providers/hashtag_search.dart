import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/category.dart';
import '../models/hashtag_item.dart';
import 'category_provider.dart';
import 'discourse_providers.dart';

/// 编辑器 `#` 补全的候选来源。
///
/// 首选官方 `/hashtags/search.json`(网页版 composer 同源:排序、消歧
/// 后缀、权限过滤都由服务端算好);拿不到结果时退回本地兜底 ——
/// 分类用已缓存的全量分类表,标签用 `/tags/filter/search`。兜底存在的
/// 意义是离线/老站点也别把这个功能整个哑掉。
Future<List<HashtagItem>> searchHashtags(
  WidgetRef ref,
  String term, {
  int? categoryId,
  int categoryLimit = 5,
  int tagLimit = 5,
}) async {
  final service = ref.read(discourseServiceProvider);
  final official = await service.searchHashtags(
    term: term,
    limit: categoryLimit + tagLimit,
  );
  debugPrint('[hashtag] term="$term" 官方接口返回 ${official.length} 条');
  if (official.isNotEmpty) return official;

  final categories = ref.read(categoryMapProvider).value ?? const {};

  int rank(Category c) {
    final q = term.trim().toLowerCase();
    if (q.isEmpty) return 1;
    final name = c.name.toLowerCase();
    final slug = c.slug.toLowerCase();
    if (name.startsWith(q) || slug.startsWith(q)) return 0;
    if (name.contains(q) || slug.contains(q)) return 1;
    return 2;
  }

  final catHits = categories.values.where((c) => rank(c) < 2).toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });

  String refOf(Category c) {
    final parent = c.parentCategoryId == null
        ? null
        : categories[c.parentCategoryId];
    return parent == null ? c.slug : '${parent.slug}:${c.slug}';
  }

  final items = [
    for (final c in catHits.take(categoryLimit))
      HashtagItem(
        kind: HashtagKind.category,
        label: c.name,
        ref: refOf(c),
        slug: c.slug,
        colorHex: c.color,
        description: c.description,
        id: c.id,
      ),
  ];

  final tags = await service.searchTags(
    query: term,
    categoryId: categoryId,
    limit: tagLimit,
  );
  items.addAll([
    for (final t in tags.results)
      HashtagItem(
        kind: HashtagKind.tag,
        label: t.name,
        // 兜底路径自己加消歧后缀:本地不知道有没有同名分类,`::tag`
        // 一律带上,解析结果永远确定
        ref: '${t.name}::tag',
        secondaryText: 'x ${t.count}',
      ),
  ]);
  return items;
}
