import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sticker.dart';

/// 收藏表情的分类。
@immutable
class StickerFavoriteCategory {
  const StickerFavoriteCategory({
    required this.id,
    required this.name,
    this.items = const [],
  });

  /// 默认分类的 id。名称为空,显示时用「收藏」。
  static const String defaultId = 'default';

  final String id;
  final String name;
  final List<StickerItem> items;

  bool get isDefault => id == defaultId;

  StickerFavoriteCategory copyWith({String? name, List<StickerItem>? items}) =>
      StickerFavoriteCategory(
        id: id,
        name: name ?? this.name,
        items: items ?? this.items,
      );

  factory StickerFavoriteCategory.fromJson(Map<String, dynamic> json) =>
      StickerFavoriteCategory(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        items: [
          for (final item in json['items'] as List<dynamic>? ?? const [])
            if (item is Map<String, dynamic>) StickerItem.fromJson(item),
        ],
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'items': [for (final item in items) item.toJson()],
  };
}

/// 收藏表情的存储。
///
/// 整份收藏是一个 JSON 存在 prefs 的单个键里(读写原子,随备份导出)。
/// 表情以图片地址为身份:同一张图只属于一个分类,收藏到别的分类即移动。
/// 收藏的只是地址与尺寸 —— 帖子里的图本来就在论坛 CDN 上,不重新上传。
class StickerFavoritesService {
  StickerFavoritesService(this._prefs);

  /// 不能用 `sticker_market_` 前缀:那是可清的缓存,备份会排除。
  static const String _key = 'sticker_favorites';

  final SharedPreferences _prefs;

  List<StickerFavoriteCategory> load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final data = json.decode(raw) as Map<String, dynamic>;
      return [
        for (final c in data['categories'] as List<dynamic>? ?? const [])
          if (c is Map<String, dynamic>) StickerFavoriteCategory.fromJson(c),
      ].where((c) => c.id.isNotEmpty).toList();
    } catch (e) {
      debugPrint('[StickerFavorites] 读取失败: $e');
      return const [];
    }
  }

  Future<void> save(List<StickerFavoriteCategory> categories) =>
      _prefs.setString(
        _key,
        json.encode({
          'version': 1,
          'categories': [for (final c in categories) c.toJson()],
        }),
      );
}
