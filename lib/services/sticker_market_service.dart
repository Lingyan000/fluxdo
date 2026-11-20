import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sticker.dart';
import 'app_logger.dart';
import 'sticker_thumbnail_source.dart';

/// 顶层函数，供 compute() 在后台 Isolate 中解析分组详情
StickerGroupDetail _parseGroupDetail(Map<String, dynamic> data) {
  return StickerGroupDetail.fromJson(data);
}

/// 表情包市场 API 服务
///
/// 使用独立的 Dio 实例（非 DiscourseDio），因为这是外部 API，
/// 不需要 Discourse 认证。缓存 24 小时过期：分类与分页这类小文件存
/// SharedPreferences；分组详情（单个 20～230KB，市场卡片的预览条会按需
/// 拉取）存文件，避免 prefs 随浏览膨胀、启动时整份读进内存。
class StickerMarketService {
  static const String defaultBaseUrl = 'https://s.pwsh.us.kg';
  static const String _baseUrlKey = 'sticker_market_base_url';
  static const String _cachePrefix = 'sticker_market_';
  static const String _subscribedKey = 'sticker_subscribed_groups';

  /// 已订阅分组的元信息缓存（name/icon/emojiCount）。
  ///
  /// 与 [_subscribedKey] 分开两个键而不是把订阅列表整体换成 JSON：订阅列表
  /// 是用户数据、要能被旧版本读懂（降级不丢订阅），元信息只是可重建的缓存。
  static const String _subscribedMetaKey = 'sticker_subscribed_group_meta';
  static const String _recentStickersKey = 'sticker_recent_items';

  /// 缩略图走缩放代理的开关(用户设置,不能用 [_cachePrefix] 前缀:
  /// 那是可清的缓存,备份也会排除)。
  static const String _thumbnailProxyKey = 'sticker_thumbnail_proxy';
  static const int _maxRecentStickers = 30;
  static const Duration _cacheDuration = Duration(hours: 24);

  /// 未订阅分组的详情文件超过这个时长未访问就清理（订阅的长期保留）。
  static const Duration _groupFileRetention = Duration(days: 14);

  final SharedPreferences _prefs;
  late final Dio _dio;
  final Future<Directory> Function() _cacheRoot;
  bool _swept = false;

  StickerMarketService(
    this._prefs, {
    Dio? dio,
    Future<Directory> Function()? cacheDirectory,
  }) : _cacheRoot = cacheDirectory ?? _defaultCacheRoot {
    // 缩略图取源在 ImageProvider 里静态读开关;服务是表情面板与市场的
    // 共同依赖,构造时同步一次即可覆盖所有取图路径。
    StickerThumbnailSource.proxyEnabled = thumbnailProxyEnabled;
    _dio =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
  }

  static Future<Directory> _defaultCacheRoot() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/sticker_market',
  );

  /// 表情缩略图是否走缩放代理(默认开启)
  bool get thumbnailProxyEnabled => _prefs.getBool(_thumbnailProxyKey) ?? true;

  Future<void> setThumbnailProxyEnabled(bool enabled) async {
    StickerThumbnailSource.proxyEnabled = enabled;
    await _prefs.setBool(_thumbnailProxyKey, enabled);
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

  /// 获取市场分类列表
  ///
  /// 分类唯一来源是独立的 topics.json（与 index.json 解耦，分类可独立
  /// 于分组数据更新）。
  Future<List<StickerMarketTopic>> getTopics() async {
    final data = await _fetchWithCache(
      'topics',
      '$baseUrl/assets/market/index/topics.json',
    );
    final list = data['topics'] as List<dynamic>? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(StickerMarketTopic.fromJson)
        .toList();
  }

  /// 获取单页分组数据
  ///
  /// 其余分类走 `{topic}-page-N.json`（分类清单见 topics.json）。
  Future<List<StickerGroup>> getGroupsPage(
    int page, {
    String topic = 'all',
  }) async {
    final (groups, _) = await getGroupsPageWithMeta(page, topic: topic);
    return groups;
  }

  /// 获取单页分组数据 + 该分类的分页元信息（totalPages）。
  ///
  /// 每个分类的页文件自带该分类的 totalPages（与「全部」的互不相同），
  /// 分类切换后必须以页文件里的元信息为准，不能沿用索引顶层值。
  Future<(List<StickerGroup>, int totalPages)> getGroupsPageWithMeta(
    int page, {
    String topic = 'all',
  }) async {
    final data = await _fetchWithCache(
      topic == 'all' ? 'page_$page' : 'page_${topic}_$page',
      topic == 'all'
          ? '$baseUrl/assets/market/index/page-$page.json'
          : '$baseUrl/assets/market/index/$topic-page-$page.json',
    );
    final list = data['groups'] as List<dynamic>? ?? [];
    final groups = list
        .map((item) => StickerGroup.fromJson(item as Map<String, dynamic>))
        .toList();
    return (groups, data['totalPages'] as int? ?? 1);
  }

  /// 全市场分组概要(单文件 metadata.json,约 90KB)。
  ///
  /// 与各页文件同源导出、内容一致;分类成员即按 [StickerGroup.topic] 过滤。
  /// 搜索要在全量上过滤,一次取全比逐页补齐少六七次请求。
  Future<List<StickerGroup>> getAllGroups() async {
    final data = await _fetchWithCache(
      'metadata',
      '$baseUrl/assets/market/metadata.json',
    );
    final list = data['groups'] as List<dynamic>? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(StickerGroup.fromJson)
        .toList();
  }

  /// 获取分组详情
  Future<StickerGroupDetail> getGroupDetail(String groupId) async {
    // 市场分组 id 通常已经包含 `group-` 前缀，不能再次拼接成
    // `group-group-*.json`；兼容仍使用裸 id 的旧数据。
    final groupFileName = groupId.startsWith('group-')
        ? '$groupId.json'
        : 'group-$groupId.json';
    if (!_swept) {
      _swept = true;
      unawaited(_sweepGroupFiles());
    }
    final data = await _fetchWithCache(
      'group_$groupId',
      '$baseUrl/assets/market/$groupFileName',
      inFile: true,
    );
    return compute(_parseGroupDetail, data);
  }

  // ==================== 订阅管理 ====================

  /// 获取已订阅的分组 ID 列表（订阅顺序即展示顺序）
  List<String> getSubscribedGroupIds() {
    return _prefs.getStringList(_subscribedKey) ?? [];
  }

  /// 已订阅分组（含 tab 栏所需的 name/icon），按订阅顺序返回。
  ///
  /// 纯本地同步读，不发任何请求 —— 面板首帧就能画出 tab 栏。元信息在订阅
  /// 那一刻就在手上（市场列表里点的就是它），所以随订阅一起落盘；元信息只是
  /// 缓存，[_subscribedKey] 才是「订阅了什么」的真相，所以缺元信息的 id
  /// 仍然会以占位(name/icon 空)出现在结果里，绝不会因为缓存缺失就显示成
  /// 未订阅。占位由 [cacheSubscribedGroupMeta] 从分组详情回填。
  List<StickerGroup> getSubscribedGroups() {
    final metaById = _readSubscribedMeta();
    return [
      for (final id in getSubscribedGroupIds())
        metaById[id] ??
            StickerGroup(
              id: id,
              name: '',
              icon: '',
              order: 0,
              emojiCount: 0,
              isArchived: false,
            ),
    ];
  }

  /// 订阅一个分组，同时缓存其元信息
  Future<void> subscribe(StickerGroup group) async {
    final ids = getSubscribedGroupIds();
    if (!ids.contains(group.id)) {
      ids.add(group.id);
      await _prefs.setStringList(_subscribedKey, ids);
    }
    await cacheSubscribedGroupMeta(group);
  }

  /// 取消订阅，连带清掉元信息缓存
  Future<void> unsubscribe(String groupId) async {
    final ids = getSubscribedGroupIds();
    ids.remove(groupId);
    await _prefs.setStringList(_subscribedKey, ids);
    final metaById = _readSubscribedMeta();
    if (metaById.remove(groupId) != null) {
      await _writeSubscribedMeta(metaById);
    }
  }

  /// 是否已订阅
  bool isSubscribed(String groupId) {
    return getSubscribedGroupIds().contains(groupId);
  }

  /// 元信息与本地缓存是否一致（tab 栏只认 name/icon/emojiCount，
  /// 一致就不写盘、不触发 rebuild）
  bool isSubscribedMetaFresh(StickerGroup group) {
    final cached = _readSubscribedMeta()[group.id];
    return cached != null &&
        cached.name == group.name &&
        cached.icon == group.icon &&
        cached.emojiCount == group.emojiCount;
  }

  /// 写入/更新已订阅分组的元信息缓存
  Future<void> cacheSubscribedGroupMeta(StickerGroup group) async {
    final metaById = _readSubscribedMeta();
    metaById[group.id] = group;
    await _writeSubscribedMeta(metaById);
  }

  Map<String, StickerGroup> _readSubscribedMeta() {
    final raw = _prefs.getStringList(_subscribedMetaKey) ?? const [];
    final result = <String, StickerGroup>{};
    for (final s in raw) {
      try {
        final group = StickerGroup.fromJson(
          json.decode(s) as Map<String, dynamic>,
        );
        if (group.id.isNotEmpty) result[group.id] = group;
      } catch (_) {
        // 单条坏数据不该让整个 tab 栏退化成占位，跳过即可
      }
    }
    return result;
  }

  Future<void> _writeSubscribedMeta(Map<String, StickerGroup> metaById) async {
    await _prefs.setStringList(_subscribedMetaKey, [
      for (final group in metaById.values) json.encode(group.toJson()),
    ]);
  }

  // ==================== 最近使用 ====================

  /// 获取最近使用的表情包列表
  List<StickerItem> getRecentStickers() {
    final raw = _prefs.getStringList(_recentStickersKey);
    if (raw == null) return [];
    return raw
        .map((s) {
          try {
            return StickerItem.fromJson(json.decode(s) as Map<String, dynamic>);
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
    final trimmed = list.length > _maxRecentStickers
        ? list.sublist(0, _maxRecentStickers)
        : list;
    await _prefs.setStringList(_recentStickersKey, trimmed);
  }

  /// 带缓存的网络请求。[inFile] 为 true 时缓存存文件，否则存 prefs。
  Future<Map<String, dynamic>> _fetchWithCache(
    String cacheKey,
    String url, {
    bool inFile = false,
  }) async {
    final cached = inFile
        ? await _readFileCache(cacheKey)
        : _readPrefsCache(cacheKey);
    if (cached != null &&
        DateTime.now().difference(cached.time) < _cacheDuration) {
      return json.decode(cached.body) as Map<String, dynamic>;
    }

    // 请求网络
    try {
      final response = await _dio.get<Map<String, dynamic>>(url);
      final data = response.data!;
      final body = json.encode(data);
      if (inFile) {
        await _writeFileCache(cacheKey, body);
      } else {
        await _prefs.setString('$_cachePrefix$cacheKey', body);
        await _prefs.setInt(
          '$_cachePrefix${cacheKey}_ts',
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      return data;
    } catch (e, st) {
      // 网络失败时尝试使用过期缓存
      if (cached != null) {
        AppLogger.warning(
          '表情包市场请求失败，已回退过期缓存',
          tag: 'StickerMarket',
          fields: {'url': url, 'cacheKey': cacheKey, 'error': e.toString()},
        );
        return json.decode(cached.body) as Map<String, dynamic>;
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

  ({String body, DateTime time})? _readPrefsCache(String cacheKey) {
    final body = _prefs.getString('$_cachePrefix$cacheKey');
    final timestamp = _prefs.getInt('$_cachePrefix${cacheKey}_ts');
    if (body == null || timestamp == null) return null;
    return (body: body, time: DateTime.fromMillisecondsSinceEpoch(timestamp));
  }

  Future<File> _cacheFile(String cacheKey) async {
    final root = await _cacheRoot();
    return File('${root.path}/${md5.convert(utf8.encode(cacheKey))}.json');
  }

  /// 读文件缓存；文件不存在时把旧版本存在 prefs 里的同 key 缓存迁过来。
  Future<({String body, DateTime time})?> _readFileCache(
    String cacheKey,
  ) async {
    try {
      final file = await _cacheFile(cacheKey);
      if (await file.exists()) {
        return (
          body: await file.readAsString(),
          time: await file.lastModified(),
        );
      }
      final legacy = _readPrefsCache(cacheKey);
      if (legacy == null) return null;
      await _writeFileCache(cacheKey, legacy.body, time: legacy.time);
      await _prefs.remove('$_cachePrefix$cacheKey');
      await _prefs.remove('$_cachePrefix${cacheKey}_ts');
      return legacy;
    } catch (e) {
      debugPrint('[StickerMarket] 读取文件缓存失败 $cacheKey: $e');
      return null;
    }
  }

  Future<void> _writeFileCache(
    String cacheKey,
    String body, {
    DateTime? time,
  }) async {
    try {
      final file = await _cacheFile(cacheKey);
      await file.parent.create(recursive: true);
      // 先写临时文件再改名，读到的不会是写了一半的 JSON
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(file.path);
      if (time != null) await file.setLastModified(time);
    } catch (e) {
      debugPrint('[StickerMarket] 写入文件缓存失败 $cacheKey: $e');
    }
  }

  /// 清理长时间没刷新过的未订阅分组详情（每个服务实例只扫一次）。
  /// 详情每 24 小时随访问刷新一次，修改时间即最近一次使用。
  Future<void> _sweepGroupFiles() async {
    try {
      final root = await _cacheRoot();
      if (!await root.exists()) return;
      final keep = {
        for (final id in getSubscribedGroupIds())
          '${md5.convert(utf8.encode('group_$id'))}.json',
      };
      final deadline = DateTime.now().subtract(_groupFileRetention);
      await for (final entity in root.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (keep.contains(name)) continue;
        if ((await entity.lastModified()).isBefore(deadline)) {
          await entity.delete();
        }
      }
    } catch (e) {
      debugPrint('[StickerMarket] 清理分组详情缓存失败: $e');
    }
  }

  /// 清除全部缓存
  Future<void> _clearAllCache() async {
    // 地址键与缓存同前缀，必须跳过，否则刚设置的地址会被一并删掉
    final keys = _prefs.getKeys().where(
      (k) => k.startsWith(_cachePrefix) && k != _baseUrlKey,
    );
    for (final key in keys.toList()) {
      await _prefs.remove(key);
    }
    try {
      final root = await _cacheRoot();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (e) {
      debugPrint('[StickerMarket] 清除文件缓存失败: $e');
    }
  }
}
