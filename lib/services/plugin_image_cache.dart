import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import 'download_request_queue.dart';

typedef PluginImageResponse = ({
  Uint8List bytes,
  Map<String, String>? cacheHeaders,
});
typedef _CachedImage = ({Uint8List bytes, DateTime expires});
typedef _Entry = ({int size, DateTime expires});

/// 只接收插件匿名图片出口校验过的字节。文件名是插件及请求变体的摘要，
/// mtime 是到期时间，访问不会延长它。设计依据：docs/plugins/components.md。
class PluginImageCache {
  PluginImageCache({
    required this._directory,
    this._now = DateTime.now,
    this.memoryLimit = 12 << 20,
    this.pluginLimit = 64 << 20,
    this.diskLimit = 192 << 20,
    this.entryLimit = 2048,
  });

  static final shared = PluginImageCache(
    directory: () async {
      // 平台未提供临时目录时，安装、恢复和数据清理仍须可用；图片只在内存中复用。
      try {
        return Directory(
          p.join((await getTemporaryDirectory()).path, 'plugin-images-v1'),
        );
      } on MissingPluginException {
        return null;
      } on MissingPlatformDirectoryException {
        return null;
      }
    },
  );
  static const maxImageBytes = 16 << 20;
  static final _filename = RegExp(r'^[a-f0-9]{64}-[a-f0-9]{64}$');
  final Future<Directory?> Function() _directory;
  final DateTime Function() _now;
  final int memoryLimit, pluginLimit, diskLimit, entryLimit;
  final _disk = Lock();
  // 限制等候慢磁盘的完整图片数量，命中内存和读文件无需占下载槽。
  final _downloads = DownloadRequestQueue(4);
  final _hot = <String, _CachedImage>{};
  int _hotBytes = 0;
  final _flights = <(String, Object), Future<Uint8List>>{};
  final _clearing = <String, Future<void>>{};
  Directory? _root;
  Map<String, _Entry>? _index;

  Future<Directory?> get _dir async => _root ??= await _directory();
  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// 没有新鲜度声明的普通图片短期保留；源站的禁止复用、缓存年龄及过期时间优先。
  static DateTime? freshUntil(Map<String, String> headers, DateTime now) {
    final control = (headers['cache-control'] ?? '')
        .toLowerCase()
        .split(',')
        .map((s) => s.trim());
    final directives = control.map((s) => s.split('=').first.trim());
    if (directives.any(const {'private', 'no-cache', 'no-store'}.contains) ||
        (headers['pragma'] ?? '').toLowerCase().contains('no-cache')) {
      return null;
    }
    final vary = (headers['vary'] ?? '')
        .toLowerCase()
        .split(',')
        .map((s) => s.trim());
    if (vary.any(
      (s) => !const {'', 'accept', 'referer', 'accept-encoding'}.contains(s),
    )) {
      return null;
    }
    DateTime? httpDate(String? value) {
      if (value == null) return null;
      try {
        return HttpDate.parse(value);
      } on HttpException {
        return null;
      }
    }

    final date = httpDate(headers['date']) ?? now;
    final age = int.tryParse(headers['age'] ?? '0');
    if (age == null || age < 0) return null;
    final elapsed = math.max(age, now.difference(date).inSeconds);
    final maxAge = control
        .where((s) => s.split('=').first.trim() == 'max-age')
        .toList();
    var seconds = const Duration(hours: 24).inSeconds;
    if (maxAge.isNotEmpty) {
      final match = RegExp(r'^max-age\s*=\s*(?:"(\d+)"|(\d+))$')
          .firstMatch(maxAge.first);
      if (maxAge.length != 1 || match == null) return null;
      seconds = int.tryParse(match[1] ?? match[2]!) ?? 0;
    } else if (headers.containsKey('expires')) {
      final expires = httpDate(headers['expires']);
      if (expires == null) return null;
      seconds = expires.difference(date).inSeconds;
    }
    if (seconds <= elapsed) return null;
    return now.add(
      Duration(
        seconds: math.min(seconds - elapsed, const Duration(days: 7).inSeconds),
      ),
    );
  }

  Future<Uint8List> load({
    required String pluginId,
    required String variant,
    required Object runtime,
    required bool reusable,
    required Future<PluginImageResponse> Function() download,
    void Function()? checkActive,
    bool reload = false,
  }) async {
    final owner = _hash(pluginId);
    final key = '$owner-${_hash(variant)}';
    final flight = (key, runtime);
    final barriers = [?_clearing[''], ?_clearing[owner]];
    // 重试替换旧读取；后来的普通读取可直接加入重试。旧读取不能覆盖新的结果。
    final pending = _flights[flight];
    if (!reload && pending != null) return pending;
    late final Future<Uint8List> result;
    bool canStore() => identical(_flights[flight], result);
    Future<Uint8List> run() async {
      if (barriers.isNotEmpty) await Future.wait(barriers);
      checkActive?.call();
      if (reusable && canStore()) {
        if (reload) {
          _forgetHot(key);
          await _disk.synchronized(() async {
            if (canStore()) await _discard(key);
          });
        } else {
          final hot = _forgetHot(key);
          if (hot != null && hot.expires.isAfter(_now())) {
            _remember(key, hot);
            return hot.bytes;
          }
          final hit = await _read(key);
          if (hit != null && canStore()) {
            _remember(key, hit);
            return hit.bytes;
          }
        }
      }
      await _downloads.acquire(
        key,
        reload ? DownloadPriority.high : DownloadPriority.normal,
      );
      try {
        checkActive?.call();
        final response = await download();
        final headers = response.cacheHeaders;
        final expires = reusable && headers != null
            ? freshUntil(headers, _now())
            : null;
        checkActive?.call();
        if (expires != null && canStore()) {
          final image = (bytes: response.bytes, expires: expires);
          _remember(key, image);
          await _disk.synchronized(() async {
            checkActive?.call();
            if (canStore()) await _write(key, owner, image);
          });
        }
        return response.bytes;
      } finally {
        _downloads.release();
      }
    }

    result = Future.microtask(run);
    _flights[flight] = result;
    try {
      return await result;
    } finally {
      if (identical(_flights[flight], result)) _flights.remove(flight);
    }
  }

  _CachedImage? _forgetHot(String key) {
    final value = _hot.remove(key);
    if (value != null) _hotBytes -= value.bytes.length;
    return value;
  }

  void _remember(String key, _CachedImage image) {
    _forgetHot(key);
    if (image.bytes.isEmpty || image.bytes.length > memoryLimit) return;
    _hot[key] = image;
    _hotBytes += image.bytes.length;
    while (_hotBytes > memoryLimit || _hot.length > 128) {
      _forgetHot(_hot.keys.first);
    }
  }

  Future<_CachedImage?> _read(String key) async {
    try {
      final dir = await _dir;
      if (dir == null) return null;
      final file = File(p.join(dir.path, key));
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size <= 0 ||
          stat.size > maxImageBytes ||
          !stat.modified.isAfter(_now())) {
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != stat.size || !stat.modified.isAfter(_now())) {
        return null;
      }
      return (bytes: bytes, expires: stat.modified);
    } on Exception {
      return null;
    } // 临时目录可能不可用，仍可匿名下载。
  }

  /// 首次写入才扫描，命中一张图不用先枚举整个目录。之后只更新本次增删的条目。
  Future<Map<String, _Entry>> _entries(Directory dir) async {
    if (_index case final entries?) return entries;
    final entries = <String, _Entry>{};
    await dir.create(recursive: true);
    await for (final file in dir.list(followLinks: false)) {
      if (file is! File) continue;
      final key = p.basename(file.path);
      final stat = await file.stat();
      if (!_filename.hasMatch(key) || !stat.modified.isAfter(_now())) {
        if (stat.type == FileSystemEntityType.file) await file.delete();
      } else {
        entries[key] = (size: stat.size, expires: stat.modified);
      }
    }
    return _index = entries;
  }

  Future<void> _write(String key, String owner, _CachedImage image) async {
    final size = image.bytes.length;
    if (size > math.min(pluginLimit, diskLimit) || size == 0) return;
    try {
      final dir = await _dir;
      if (dir == null) return;
      final entries = await _entries(dir);
      // 系统可能在运行中回收临时目录。
      await dir.create(recursive: true);
      final path = p.join(dir.path, key);
      final temp = File('$path.part');
      await temp.writeAsBytes(image.bytes);
      await temp.setLastModified(image.expires);
      await temp.rename(path);
      entries[key] = (size: size, expires: image.expires);
      var total = 0, owned = 0;
      for (final e in entries.entries) {
        total += e.value.size;
        if (e.key.startsWith(owner)) owned += e.value.size;
      }
      if (owned <= pluginLimit &&
          total <= diskLimit &&
          entries.length <= entryLimit) {
        return;
      }
      final victims = entries.keys.toList()
        ..sort((a, b) => entries[a]!.expires.compareTo(entries[b]!.expires));
      Future<void> evict(String candidate) async {
        final e = entries[candidate]!;
        await _deleteFile(dir, candidate);
        total -= e.size;
        if (candidate.startsWith(owner)) owned -= e.size;
        entries.remove(candidate);
      }

      for (final candidate in victims.where((k) => k.startsWith(owner))) {
        if (owned <= pluginLimit) break;
        await evict(candidate);
      }
      for (final candidate in victims) {
        if (total <= diskLimit && entries.length <= entryLimit) break;
        if (entries.containsKey(candidate)) await evict(candidate);
      }
    } on Exception {
      _index = null;
    } // 缓存写满或被系统回收不影响已经下载的图片。
  }

  static Future<void> _deleteFile(Directory dir, String key) async {
    try {
      await File(p.join(dir.path, key)).delete();
    } on PathNotFoundException {
      /* 已回收 */
    }
  }

  Future<void> _discard(String key) async {
    try {
      final dir = await _dir;
      if (dir != null) await _deleteFile(dir, key);
      _index?.remove(key);
    } on Exception {
      _index = null;
    }
  }

  Future<int> size([String? pluginId]) => _disk.synchronized(() async {
    final dir = await _dir;
    if (dir == null || !await dir.exists()) return 0;
    final owner = pluginId == null ? '' : _hash(pluginId);
    var bytes = 0;
    await for (final file in dir.list(followLinks: false)) {
      if (file is File && p.basename(file.path).startsWith(owner)) {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file) bytes += stat.size;
      }
    }
    return bytes;
  });

  Future<void> clear([String? pluginId]) {
    final owner = pluginId == null ? '' : _hash(pluginId);
    // 先解除旧请求的所有权，它们晚到时不能再落盘，也不能覆盖清理后创建的新请求。
    _flights.removeWhere((flight, _) => flight.$1.startsWith(owner));
    for (final key in _hot.keys.where((k) => k.startsWith(owner)).toList()) {
      _forgetHot(key);
    }
    final clearing = _disk.synchronized(() async {
      final dir = await _dir;
      _index = null;
      if (dir == null || !await dir.exists()) return;
      if (pluginId == null) {
        await dir.delete(recursive: true);
        return;
      }
      await for (final file in dir.list(followLinks: false)) {
        if (file is File && p.basename(file.path).startsWith(owner)) {
          await _deleteFile(dir, p.basename(file.path));
        }
      }
    });
    _clearing[owner] = clearing;
    return clearing.whenComplete(() {
      if (identical(_clearing[owner], clearing)) _clearing.remove(owner);
    });
  }
}
