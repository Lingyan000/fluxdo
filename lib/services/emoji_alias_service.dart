import 'package:flutter/foundation.dart';

import 'discourse/discourse_service.dart';

/// 一条 emoji 候选:名字 + 命中的别名(用于在候选行里提示"为什么匹配上")。
class EmojiAliasHit {
  const EmojiAliasHit({required this.name, this.matchedAlias});

  /// emoji 短名(`rofl`),插入时拼成 `:rofl:` / 直接建 EmojiRun。
  final String name;

  /// 命中的别名。名字本身命中时为 null。
  final String? matchedAlias;
}

/// `:` 补全用的 emoji 别名索引。
///
/// 数据源 `GET /emojis/search-aliases.json`,形如
/// `{"rofl": ["laugh", "笑死", "打滚", …], …}` —— 中英别名混在一个数组里。
///
/// 缓存语义按需求定死:**一次 `:` 输入会话内只请求一次**。会话开始
/// (敲下 `:`)调 [ensureLoaded],会话结束(选中/取消)调 [invalidate];
/// 下一次敲 `:` 会重新拉一遍,拿到的是当时的最新别名表。
class EmojiAliasService {
  static final EmojiAliasService _instance = EmojiAliasService._internal();
  factory EmojiAliasService() => _instance;
  EmojiAliasService._internal();

  Map<String, List<String>>? _aliases;
  Future<void>? _inflight;

  /// 已知的合法 emoji 短名。
  ///
  /// 与 [_aliases] 的生命周期**故意不同**:别名表按会话作废是为了每次
  /// 敲 `:` 都拿到最新的搜索词表;而"这个名字是不是真 emoji"是判定
  /// `:rofl:` 该不该转原子的依据,作废掉会让转换时灵时不灵。名字集合
  /// 变化极慢,拉到一次就一直留着。
  Set<String>? _knownNames;

  /// 是否已有合法名集合(shortcode 转换的前提)。
  bool get hasKnownNames => _knownNames != null;

  /// [name] 是不是已知 emoji。集合还没拉到时返回 false(宁可不转,
  /// 也不要把 `12:30:` 这种误转成裂图)。
  bool isKnownEmoji(String name) =>
      _knownNames?.contains(name.toLowerCase()) ?? false;

  /// 本次输入会话是否已有可用索引。
  bool get isLoaded => _aliases != null;

  /// 拉取别名表(已有缓存则直接返回)。并发调用共享同一个请求。
  Future<void> ensureLoaded() {
    if (_aliases != null) return Future.value();
    return _inflight ??= _fetch().whenComplete(() => _inflight = null);
  }

  Future<void> _fetch() async {
    try {
      final res = await DiscourseService().dio.get<dynamic>(
        '/emojis/search-aliases.json',
      );
      final data = res.data;
      if (data is! Map) return;
      final parsed = <String, List<String>>{};
      for (final entry in data.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! List) continue;
        parsed[key] = [
          for (final a in value)
            if (a is String) a,
        ];
      }
      _aliases = parsed;
      _knownNames = {for (final k in parsed.keys) k.toLowerCase()};
    } catch (e) {
      // 拉不到就静默降级:调用方看到 isLoaded=false,不弹浮层。
      debugPrint('EmojiAliasService: 别名表拉取失败 $e');
    }
  }

  /// 丢弃缓存,结束本次输入会话。
  void invalidate() => _aliases = null;

  /// 仅供测试:直接注入索引,跳过网络。
  @visibleForTesting
  void debugSetAliases(Map<String, List<String>> aliases) {
    _aliases = aliases;
    _knownNames = {for (final k in aliases.keys) k.toLowerCase()};
  }

  /// 仅供测试:连同合法名集合一起清掉([invalidate] 故意不动它)。
  @visibleForTesting
  void debugReset() {
    _aliases = null;
    _knownNames = null;
  }

  /// 按 [query] 搜索,最多返回 [limit] 条。
  ///
  /// 排序优先级(同级按名字长度升序,短名更常用):
  /// 1. 名字完全相等
  /// 2. 名字前缀命中
  /// 3. 别名完全相等
  /// 4. 名字包含
  /// 5. 别名前缀 / 包含
  ///
  /// [query] 为空时返回空列表 —— 光敲一个 `:` 不该糊一屏候选上来。
  List<EmojiAliasHit> search(String query, {int limit = 5}) {
    final index = _aliases;
    if (index == null) return const [];
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final scored = <({int rank, String name, String? alias})>[];
    for (final entry in index.entries) {
      final name = entry.key;
      final lower = name.toLowerCase();
      if (lower == q) {
        scored.add((rank: 0, name: name, alias: null));
        continue;
      }
      if (lower.startsWith(q)) {
        scored.add((rank: 1, name: name, alias: null));
        continue;
      }

      String? exactAlias;
      String? prefixAlias;
      String? containsAlias;
      for (final alias in entry.value) {
        final la = alias.toLowerCase();
        if (la == q) {
          exactAlias = alias;
          break;
        }
        prefixAlias ??= la.startsWith(q) ? alias : null;
        containsAlias ??= la.contains(q) ? alias : null;
      }
      if (exactAlias != null) {
        scored.add((rank: 2, name: name, alias: exactAlias));
        continue;
      }
      if (lower.contains(q)) {
        scored.add((rank: 3, name: name, alias: null));
        continue;
      }
      final loose = prefixAlias ?? containsAlias;
      if (loose != null) {
        scored.add((rank: 4, name: name, alias: loose));
      }
    }

    scored.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      final byLen = a.name.length.compareTo(b.name.length);
      if (byLen != 0) return byLen;
      return a.name.compareTo(b.name);
    });

    return [
      for (final s in scored.take(limit))
        EmojiAliasHit(name: s.name, matchedAlias: s.alias),
    ];
  }
}
