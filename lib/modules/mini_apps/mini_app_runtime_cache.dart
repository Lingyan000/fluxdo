import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// 按官方内容哈希保存公开运行器，供新建的 WebView 和独立窗口复用。
/// 每次读取重新校验内容，资源表仍由宿主在本次启动时获取。
class MiniAppRuntimeCache {
  MiniAppRuntimeCache({Future<Directory> Function()? directory})
    : _directory = directory ?? getTemporaryDirectory;

  static final instance = MiniAppRuntimeCache();
  static const handler = 'fluxdoMiniAppRuntime';
  static const maxBytes = 4 * 1024 * 1024;
  static const _maxEntries = 3;
  final Future<Directory> Function() _directory;
  Future<void> _writes = Future.value();

  static bool validDigest(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  Future<Object?> handle(Map request) async {
    final digest = request['hash'];
    if (!validDigest(digest)) return null;
    if (request['action'] == 'read') return read(digest as String);
    final source = request['source'];
    if (request['action'] == 'write' && source is String) {
      return write(digest as String, source);
    }
    return null;
  }

  Future<Directory> _folder() async =>
      Directory('${(await _directory()).path}/mini_app_runtime');

  Future<String?> read(String digest) async {
    if (!validDigest(digest)) return null;
    try {
      final file = File('${(await _folder()).path}/$digest.js');
      final length = await file.length();
      if (length <= 0 || length > maxBytes) return null;
      final bytes = await file.readAsBytes();
      if (sha256.convert(bytes).toString() != digest) return null;
      return utf8.decode(bytes);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> write(String digest, String source) async {
    if (!validDigest(digest) || source.isEmpty || source.length > maxBytes) {
      return false;
    }
    final bytes = utf8.encode(source);
    if (bytes.length > maxBytes || sha256.convert(bytes).toString() != digest) {
      return false;
    }
    // 主引擎串行写入和淘汰，多个小程序同时启动时不会互相清理临时文件。
    var stored = false;
    final operation = _writes.then((_) async {
      try {
        final folder = await _folder();
        await folder.create(recursive: true);
        final temporary = File('${folder.path}/$digest.tmp');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename('${folder.path}/$digest.js');
        stored = true;
        final files = await folder
            .list()
            .where((file) => file is File)
            .toList();
        final entries = <(File, DateTime)>[];
        for (final file in files.whereType<File>()) {
          if (file.path.endsWith('.js') && !file.path.endsWith('/$digest.js')) {
            entries.add((file, (await file.stat()).modified));
          }
        }
        entries.sort((a, b) => b.$2.compareTo(a.$2));
        for (final entry in entries.skip(_maxEntries - 1)) {
          await entry.$1.delete();
        }
      } on FileSystemException {
        // 缓存不可写时，当前启动继续使用浏览器取得的运行器。
      }
    });
    _writes = operation.catchError((_) {});
    await operation;
    return stored;
  }
}
