import 'dart:convert';
import 'dart:io' as io;

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import '../../../constants.dart';
import 'cookie_jar_service.dart';
import 'cookie_logger.dart';
import 'strategy/platform_cookie_strategy.dart';

/// Dio 收到的原始 Set-Cookie 头持久化队列。
///
/// 打开 WebView 前调用 [flushToWebView] 将队列中的原始头写入 WebView cookie store。
/// 队列持久化到磁盘，杀进程重启后不丢失。
class RawSetCookieQueue {
  RawSetCookieQueue._internal();

  static final RawSetCookieQueue instance = RawSetCookieQueue._internal();

  String? _filePath;
  List<Map<String, String>>? _cache;

  /// 初始化队列存储路径（在 CookieJarService.initialize 中调用）
  Future<void> initialize(String appDocDir) async {
    _filePath = '$appDocDir/.cookies/pending_set_cookies.json';
    // 预加载缓存
    await _load();
  }

  bool get isInitialized => _filePath != null;

  /// Dio 收到 Set-Cookie 时入队并持久化
  Future<void> enqueue(String url, String rawHeader) async {
    if (_filePath == null) return;

    final queue = await _load();
    queue.add({'url': url, 'raw': rawHeader});
    final normalizedQueue = _dedupeQueue(queue);
    await _save(normalizedQueue);

    final name = _extractCookieName(rawHeader);
    CookieLogger.enqueue(
      name: name,
      url: url,
      queueSize: normalizedQueue.length,
    );
  }

  /// 打开 WebView 前调用，将队列中的原始 Set-Cookie 头写入 WebView。
  ///
  /// 返回成功写入的条数。
  Future<int> flushToWebView() async {
    var queue = await _load();
    final normalizedQueue = _dedupeQueue(queue);
    if (normalizedQueue.length != queue.length) {
      queue = normalizedQueue;
      await _save(queue);
    } else {
      queue = normalizedQueue;
    }
    if (queue.isEmpty) {
      // 队列空（冷启动或长时间无请求），从 jar 的 rawSetCookie 字段兜底
      return _flushFromJar();
    }

    final entries = queue
        .where((e) => (e['url'] ?? '').isNotEmpty && (e['raw'] ?? '').isNotEmpty)
        .map((e) => (e['url']!, e['raw']!))
        .toList();

    final strategy = PlatformCookieStrategy.create();
    final written = await strategy.writeRawCookiesToWebView(entries);

    // 保留写入失败的（写入数 < 队列数时有残留）
    if (written >= entries.length) {
      await _save([]);
    }

    CookieLogger.flush(queued: queue.length, written: written);
    return written;
  }

  /// 清空队列（退出登录时调用）
  Future<void> clear() async {
    _cache = [];
    await _save([]);
  }

  /// 清空指定名称的待写入项，避免删除后又被旧队列回灌。
  Future<void> clearCookieNames(Iterable<String> names) async {
    final normalizedNames = names
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (normalizedNames.isEmpty) return;

    final queue = await _load();
    final filtered = queue.where((entry) {
      final raw = entry['raw'] ?? '';
      final cookieName = _extractCookieName(raw).trim().toLowerCase();
      return !normalizedNames.contains(cookieName);
    }).toList(growable: false);

    if (filtered.length != queue.length) {
      await _save(filtered);
    }
  }

  // ---------------------------------------------------------------------------
  // 私有方法
  // ---------------------------------------------------------------------------

  /// 从 jar 的 rawSetCookie 字段兜底写入 WebView
  Future<int> _flushFromJar() async {
    final jar = CookieJarService();
    if (!jar.isInitialized) await jar.initialize();

    final cookies = await jar.loadAllCanonicalCookies();
    final entries = cookies
        .where((c) => c.rawSetCookie != null && c.rawSetCookie!.isNotEmpty)
        .map((c) => (c.originUrl ?? AppConstants.baseUrl, c.rawSetCookie!))
        .toList();

    if (entries.isEmpty) return 0;

    final strategy = PlatformCookieStrategy.create();
    final written = await strategy.writeRawCookiesToWebView(entries);

    if (written > 0) {
      CookieLogger.flush(queued: entries.length, written: written);
    }
    return written;
  }

  Future<List<Map<String, String>>> _load() async {
    if (_cache != null) {
      _cache = _cloneQueue(_cache!);
      return _cache!;
    }
    final path = _filePath;
    if (path == null) {
      _cache = [];
      return _cache!;
    }

    final file = io.File(path);
    if (!await file.exists()) {
      _cache = [];
      return _cache!;
    }

    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        _cache = [];
        return _cache!;
      }
      final json = jsonDecode(content);
      _cache = (json as List)
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList(growable: true);
    } catch (e) {
      debugPrint('[RawSetCookieQueue] 加载失败，重置队列: $e');
      _cache = [];
    }
    return _cache!;
  }

  Future<void> _save(List<Map<String, String>> queue) async {
    final normalizedQueue = _cloneQueue(queue);
    _cache = normalizedQueue;
    final path = _filePath;
    if (path == null) return;

    try {
      final file = io.File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(normalizedQueue));
    } catch (e) {
      debugPrint('[RawSetCookieQueue] 持久化失败: $e');
    }
  }

  /// 从原始 Set-Cookie 头提取 cookie 名（用于日志）
  static String _extractCookieName(String rawHeader) {
    final eqIdx = rawHeader.indexOf('=');
    if (eqIdx <= 0) return rawHeader;
    return rawHeader.substring(0, eqIdx).trim();
  }

  List<Map<String, String>> _dedupeQueue(List<Map<String, String>> queue) {
    if (queue.length < 2) {
      return queue.toList(growable: false);
    }

    final seenKeys = <String>{};
    final dedupedReversed = <Map<String, String>>[];

    for (final entry in queue.reversed) {
      final key = _buildQueueStorageKey(entry);
      if (!seenKeys.add(key)) {
        continue;
      }
      dedupedReversed.add(entry);
    }

    return dedupedReversed.reversed.toList(growable: false);
  }

  String _buildQueueStorageKey(Map<String, String> entry) {
    final rawHeader = entry['raw'] ?? '';
    final url = entry['url'] ?? AppConstants.baseUrl;

    try {
      final uri = Uri.parse(url);
      return SetCookieParser.parse(rawHeader, uri: uri).storageKey;
    } catch (_) {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      final name = _extractCookieName(rawHeader).trim().toLowerCase();
      return '$name|$host|$url';
    }
  }

  List<Map<String, String>> _cloneQueue(List<Map<String, String>> queue) {
    return queue
        .map((entry) => Map<String, String>.from(entry))
        .toList(growable: true);
  }
}
