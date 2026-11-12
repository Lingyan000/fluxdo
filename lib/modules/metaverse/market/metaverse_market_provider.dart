import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../../../providers/theme_provider.dart';
import '../plugin/metaverse_plugin_installer.dart';
import '../plugin/providers/metaverse_plugin_providers.dart';
import 'metaverse_market_catalog.dart';

class MetaverseMarketState {
  const MetaverseMarketState({
    required this.sources,
    this.entries = const [],
    this.errors = const {},
    this.refreshing = false,
  });
  final List<MetaverseMarketSource> sources;
  final List<MetaverseMarketEntry> entries;
  final Map<String, String> errors;
  final bool refreshing;
}

final metaverseMarketProvider =
    NotifierProvider<MetaverseMarketController, MetaverseMarketState>(
      MetaverseMarketController.new,
    );

class MetaverseMarketController extends Notifier<MetaverseMarketState> {
  static const _sourcesKey = 'metaverse_market_sources_v1';
  static const _cachePrefix = 'metaverse_market_cache_v1_';
  Future<void>? _refreshing;
  final _sourceOperations = PluginOperationQueue();
  final _retryAfter = <String, int>{};
  bool _disposed = false;
  SharedPreferences get _preferences => ref.read(sharedPreferencesProvider);

  String _cacheKey(String id) =>
      '$_cachePrefix${sha256.convert(utf8.encode(id))}';

  @override
  MetaverseMarketState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final sources = <MetaverseMarketSource>[];
    final stored = _preferences.getString(_sourcesKey);
    if (stored == null) {
      sources.add(
        const MetaverseMarketSource(MetaverseMarketSource.defaultUrl),
      );
    } else {
      try {
        for (final item in jsonDecode(stored) as List) {
          final source = MetaverseMarketSource.fromInput(item['url'] as String);
          sources.add(
            MetaverseMarketSource(source.url, enabled: item['enabled'] == true),
          );
        }
      } on Object {
        sources.clear();
        sources.add(
          const MetaverseMarketSource(MetaverseMarketSource.defaultUrl),
        );
      }
    }
    final initial = _cachedState(sources);
    Future<void>.microtask(refresh);
    return initial;
  }

  Map<String, dynamic>? _cache(MetaverseMarketSource source) {
    final stored = _preferences.getString(_cacheKey(source.id));
    if (stored == null) return null;
    try {
      final cached = jsonDecode(stored);
      if (cached is! Map<String, dynamic> ||
          cached['body'] is! String ||
          cached['checkedAt'] is! int ||
          (cached['etag'] != null && cached['etag'] is! String)) {
        return null;
      }
      return cached;
    } on Object {
      return null;
    }
  }

  MetaverseMarketState _cachedState(List<MetaverseMarketSource> sources) {
    final entries = <MetaverseMarketEntry>[];
    for (final source in sources.where((s) => s.enabled)) {
      final cached = _cache(source);
      if (cached == null) continue;
      try {
        entries.addAll(
          MetaverseMarketCatalog.parse(
            jsonDecode(cached['body'] as String),
            source,
          ).entries,
        );
      } on Object {
        continue;
      }
    }
    return MetaverseMarketState(
      sources: List.unmodifiable(sources),
      entries: List.unmodifiable(entries),
    );
  }

  Future<void> refresh({bool force = false}) =>
      _refreshing ??= _refresh(force).whenComplete(() => _refreshing = null);

  Future<void> _refresh(bool force) async {
    if (_disposed) return;
    final sources = state.sources;
    state = MetaverseMarketState(
      sources: sources,
      entries: state.entries,
      errors: state.errors,
      refreshing: true,
    );
    final errors = <String, String>{};
    final network = ref.read(metaversePluginNetworkProvider);
    for (final source in sources.where((s) => s.enabled)) {
      if (_disposed) return;
      if ((_retryAfter[source.id] ?? 0) >
          DateTime.now().millisecondsSinceEpoch) {
        errors[source.id] = state.errors[source.id] ?? 'HTTP 429';
        continue;
      }
      final cached = _cache(source);
      final checked = cached?['checkedAt'] as int? ?? 0;
      if (!force &&
          DateTime.now().millisecondsSinceEpoch - checked <
              const Duration(hours: 6).inMilliseconds) {
        continue;
      }
      try {
        final response = await network.downloadResource(
          Uri.parse(source.url),
          maxBytes: 1024 * 1024,
          etag: cached?['etag'] as String?,
        );
        if (_disposed) return;
        if (response.status == 429 || response.status == 403) {
          final seconds =
              int.tryParse(response.headers['retry-after'] ?? '') ?? 60;
          _retryAfter[source.id] =
              DateTime.now().millisecondsSinceEpoch +
              seconds.clamp(60, 3600) * 1000;
        }
        if (response.status != 200 &&
            !(response.status == 304 && cached != null)) {
          throw StateError('HTTP ${response.status}');
        }
        final body = response.status == 304
            ? cached!['body'] as String
            : utf8.decode(response.bytes);
        MetaverseMarketCatalog.parse(jsonDecode(body), source);
        final saved = await _preferences.setString(
          _cacheKey(source.id),
          jsonEncode({
            'body': body,
            'etag': response.headers['etag'] ?? cached?['etag'],
            'checkedAt': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        if (!saved) throw StateError('市场缓存保存失败');
      } catch (error) {
        errors[source.id] = error.toString();
      }
    }
    if (_disposed) return;
    final loaded = _cachedState(sources);
    state = MetaverseMarketState(
      sources: sources,
      entries: loaded.entries,
      errors: errors,
    );
  }

  Future<void> addSource(String input) =>
      _sourceOperations.run('sources', () async {
        final source = MetaverseMarketSource.fromInput(input);
        await _refreshing;
        if (_disposed) return;
        if (state.sources.any((s) => s.id == source.id)) return;
        if (state.sources.length >= 16) throw const FormatException('市场源数量超限');
        await _saveSources([...state.sources, source]);
      });

  Future<void> setEnabled(String id, bool enabled) =>
      _sourceOperations.run('sources', () async {
        await _refreshing;
        if (_disposed) return;
        await _saveSources([
          for (final source in state.sources)
            source.id == id
                ? MetaverseMarketSource(source.url, enabled: enabled)
                : source,
        ]);
      });

  Future<void> removeSource(String id) =>
      _sourceOperations.run('sources', () async {
        await _refreshing;
        if (_disposed) return;
        await _saveSources(state.sources.where((s) => s.id != id).toList());
        await _preferences.remove(_cacheKey(id));
      });

  Future<void> _saveSources(List<MetaverseMarketSource> sources) async {
    final saved = await _preferences.setString(
      _sourcesKey,
      jsonEncode(sources.map((s) => s.toJson()).toList()),
    );
    if (!saved) throw StateError('市场源保存失败');
    if (_disposed) return;
    state = _cachedState(sources);
    await refresh();
  }

  Future<MetaversePluginPackage> download(MetaverseMarketEntry entry) async {
    if (!entry.compatible) {
      throw const MetaversePluginInstallException('插件需要其他版本的 SDK');
    }
    final network = ref.read(metaversePluginNetworkProvider);
    final response = await network.downloadResource(
      Uri.parse(entry.packageUrl),
      maxBytes: MetaversePluginInstaller.maxBundleBytes,
    );
    if (response.status != 200) {
      throw MetaversePluginInstallException('下载失败（HTTP ${response.status}）');
    }
    final package =
        await MetaversePluginInstaller(
          network: network,
          reservedHosts: ref.read(metaversePluginStoreProvider).reservedHosts,
        ).importBundle(
          Stream.value(response.bytes),
          source: entry.source.id,
          expectedDigest: entry.sha256,
        );
    if (package.manifest.id != entry.id ||
        package.manifest.version != entry.version ||
        package.manifest.apiVersion != entry.apiVersion) {
      throw const MetaversePluginInstallException('插件包身份或版本与市场记录不匹配');
    }
    return package;
  }
}
