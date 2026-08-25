import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sticker.dart';
import 'app_logger.dart';

/// 顶层函数，供 compute() 在后台 Isolate 中解析分组详情
StickerGroupDetail _parseGroupDetail(Map<String, dynamic> data) {
  return StickerGroupDetail.fromJson(data);
}

/// 表情包市场 API 服务
///
/// 使用独立的 Dio 实例（非 DiscourseDio），因为这是外部 API，
/// 不需要 Discourse 认证。支持 SharedPreferences 缓存（24 小时过期）。
class StickerMarketService {
  static const String defaultBaseUrl = 'https://s.pwsh.us.kg';
  static const String _baseUrlKey = 'sticker_market_base_url';
  static const String _cachePrefix = 'sticker_market_';
  static const String _subscribedKey = 'sticker_subscribed_groups';
  static const String _recentStickersKey = 'sticker_recent_items';
  static const int _maxRecentStickers = 30;
  static const Duration _cacheDuration = Duration(hours: 24);

  final SharedPreferences _prefs;
  late final Dio _dio;

  StickerMarketService(this._prefs) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ));
  }

  /// 当前 baseUrl
  String get baseUrl => _prefs.getString(_baseUrlKey) ?? defaultBaseUrl;

  /// 设置 baseUrl，同时清除全部缓存
  Future<void> setBaseUrl(String url) async {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    await _prefs.setString(_baseUrlKey, trimmed);
    await _clearAllCache();
  }

  /// 恢复默认 baseUrl
  Future<void> resetBaseUrl() async {
    await _prefs.remove(_baseUrlKey);
    await _clearAllCache();
  }

  /// 获取市场索引
  Future<StickerMarketIndex> getIndex() async {
    final data = await _fetchWithCache(
      'index',
      '$baseUrl/assets/market/index/index.json',
    );
    return StickerMarketIndex.fromJson(data);
  }

  /// 获取全部非归档分组
  Future<List<StickerGroup>> getAllGroups() async {
    final index = await getIndex();
    final groups = <StickerGroup>[];

    for (int page = 1; page <= index.totalPages; page++) {
      groups.addAll(await getGroupsPage(page));
    }

    // 按 order 排序
    groups.sort((a, b) => a.order.compareTo(b.order));
    return groups;
  }

  /// 获取单页分组数据
  Future<List<StickerGroup>> getGroupsPage(int page) async {
    final data = await _fetchWithCache(
      'page_$page',
      '$baseUrl/assets/market/index/page-$page.json',
    );
    final list = data['groups'] as List<dynamic>? ?? [];
    return list
        .map((item) => StickerGroup.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// 获取分组详情
  Future<StickerGroupDetail> getGroupDetail(String groupId) async {
    final data = await _fetchWithCache(
      'group_$groupId',
      '$baseUrl/assets/market/group-$groupId.json',
    );
    return compute(_parseGroupDetail, data);
  }

  // ==================== 订阅管理 ====================

  /// 获取已订阅的分组 ID 列表
  List<String> getSubscribedGroupIds() {
    return _prefs.getStringList(_subscribedKey) ?? [];
  }

  /// 订阅一个分组
  Future<void> subscribe(String groupId) async {
    final ids = getSubscribedGroupIds();
    if (!ids.contains(groupId)) {
      ids.add(groupId);
      await _prefs.setStringList(_subscribedKey, ids);
    }
  }

  /// 取消订阅
  Future<void> unsubscribe(String groupId) async {
    final ids = getSubscribedGroupIds();
    ids.remove(groupId);
    await _prefs.setStringList(_subscribedKey, ids);
  }

  /// 是否已订阅
  bool isSubscribed(String groupId) {
    return getSubscribedGroupIds().contains(groupId);
  }

  // ==================== 最近使用 ====================

  /// 获取最近使用的表情包列表
  List<StickerItem> getRecentStickers() {
    final raw = _prefs.getStringList(_recentStickersKey);
    if (raw == null) return [];
    return raw
        .map((s) {
          try {
            return StickerItem.fromJson(
                json.decode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<StickerItem>()
        .toList();
  }

  /// 保存一个表情包到最近使用
  Future<void> addRecentSticker(StickerItem sticker) async {
    final list = _prefs.getStringList(_recentStickersKey) ?? [];

    // 移除已存在的（按 id 去重），然后插入到开头
    final encoded = json.encode(sticker.toJson());
    list.removeWhere((s) {
      try {
        final m = json.decode(s) as Map<String, dynamic>;
        return m['id'] == sticker.id;
      } catch (_) {
        return false;
      }
    });
    list.insert(0, encoded);

    // 限制数量
    final trimmed =
        list.length > _maxRecentStickers ? list.sublist(0, _maxRecentStickers) : list;
    await _prefs.setStringList(_recentStickersKey, trimmed);
  }

  /// 带缓存的网络请求
  Future<Map<String, dynamic>> _fetchWithCache(
    String cacheKey,
    String url,
  ) async {
    final fullKey = '$_cachePrefix$cacheKey';
    final timestampKey = '${fullKey}_ts';

    // 检查缓存
    final cached = _prefs.getString(fullKey);
    final timestamp = _prefs.getInt(timestampKey);
    if (cached != null && timestamp != null) {
      final cacheTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(cacheTime) < _cacheDuration) {
        return json.decode(cached) as Map<String, dynamic>;
      }
    }

    // 请求网络
    try {
      final response = await _dio.get<Map<String, dynamic>>(url);
      final data = response.data!;

      // 保存缓存
      await _prefs.setString(fullKey, json.encode(data));
      await _prefs.setInt(timestampKey, DateTime.now().millisecondsSinceEpoch);

      return data;
    } catch (e, st) {
      // 网络失败时尝试使用过期缓存
      if (cached != null) {
        AppLogger.warning(
          '表情包市场请求失败，已回退过期缓存',
          tag: 'StickerMarket',
          fields: {'url': url, 'cacheKey': cacheKey, 'error': e.toString()},
        );
        return json.decode(cached) as Map<String, dynamic>;
      }
      AppLogger.error(
        '表情包市场请求失败且无缓存可用',
        tag: 'StickerMarket',
        error: e,
        stackTrace: st,
        fields: {'url': url, 'cacheKey': cacheKey},
      );
      rethrow;
    }
  }

  /// 清除全部缓存
  Future<void> _clearAllCache() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith(_cachePrefix));
    for (final key in keys.toList()) {
      await _prefs.remove(key);
    }
  }
}
