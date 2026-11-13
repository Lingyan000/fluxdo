import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'log_policy.dart';

/// 文件操作由 LogWriter 的 IO 队列串行调用，插件分别占用缓冲与轮转配额。
class PluginLogStore {
  static const maxFileBytes = 512 * 1024;
  static const _maxBufferBytes = 128 * 1024;
  static const _maxBufferedLines = 256;

  Directory? _directory;
  final _buffers = <String, _PluginLogBuffer>{};

  int get pendingLines =>
      _buffers.values.fold(0, (count, buffer) => count + buffer.lines.length);

  void append(Map<String, dynamic> entry) {
    final id = entry['pluginId'] as String;
    final buffer = _buffers.putIfAbsent(id, _PluginLogBuffer.new);
    final line = '${jsonEncode(entry)}\n';
    final bytes = utf8.encode(line).length;
    while (buffer.lines.isNotEmpty &&
        (buffer.bytes + bytes > _maxBufferBytes ||
            buffer.lines.length >= _maxBufferedLines)) {
      buffer.bytes -= utf8.encode(buffer.lines.removeAt(0)).length;
      buffer.dropped++;
    }
    buffer.lines.add(line);
    buffer.bytes += bytes;
  }

  Future<void> initialize(Directory parent) async {
    final directory = _directory = Directory('${parent.path}/plugins');
    await directory.create(recursive: true);
    final now = DateTime.now();
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      if (now.difference(await entity.lastModified()).inDays >= 14) {
        await entity.delete();
      }
    }
  }

  File _file(String id, {bool rotated = false}) {
    final key = sha256.convert(utf8.encode(id));
    return File('${_directory!.path}/$key${rotated ? '.1' : ''}.jsonl');
  }

  Future<void> flush() async {
    if (_directory == null) return;
    final pending = Map.of(_buffers);
    _buffers.clear();
    for (final entry in pending.entries) {
      final buffer = entry.value;
      if (buffer.dropped > 0) {
        final last = jsonDecode(buffer.lines.last) as Map<String, dynamic>;
        final summary = LogPolicy.normalize({
          'pluginId': entry.key,
          'emitter': 'framework',
          'level': 'warning',
          'event': 'plugin_log_overflow',
          'message': '插件日志缓冲超限，丢弃最旧记录',
          'dropped': buffer.dropped,
        });
        // 汇总属于原批次，清空期间晚写入也按原记录的代次清理。
        summary.addAll({
          'sessionId': last['sessionId'],
          'seq': last['seq'],
          'timestamp': last['timestamp'],
        });
        buffer.lines.add('${jsonEncode(summary)}\n');
      }
      try {
        await _appendFiles(entry.key, buffer.lines);
      } on FileSystemException {
        // 单个插件的文件故障不会阻止其他插件落盘。
      }
    }
  }

  Future<void> _appendFiles(String id, List<String> lines) async {
    final file = _file(id);
    final rotated = _file(id, rotated: true);
    var size = await file.exists() ? await file.length() : 0;
    final batch = BytesBuilder(copy: false);
    for (final line in lines) {
      final bytes = utf8.encode(line);
      if (size + batch.length + bytes.length > maxFileBytes) {
        if (batch.isNotEmpty) {
          await file.writeAsBytes(batch.takeBytes(), mode: FileMode.append);
        }
        if (await rotated.exists()) await rotated.delete();
        if (await file.exists()) await file.rename(rotated.path);
        size = 0;
      }
      batch.add(bytes);
    }
    if (batch.isNotEmpty) {
      await file.writeAsBytes(batch.takeBytes(), mode: FileMode.append);
    }
  }

  void discardPending({String? pluginId}) {
    if (pluginId == null) {
      _buffers.clear();
    } else {
      _buffers.remove(pluginId);
    }
  }

  Future<void> clearFiles({
    String? pluginId,
    bool Function(String)? keep,
  }) async {
    final files = await _files(pluginId);
    for (final file in files) {
      if (keep == null) {
        await file.delete();
        continue;
      }
      final lines = const LineSplitter()
          .convert(await _read(file))
          .where(keep)
          .toList();
      if (lines.isEmpty) {
        await file.delete();
        continue;
      }
      final temporary = File('${file.path}.clear');
      await temporary.writeAsString('${lines.join('\n')}\n', flush: true);
      await temporary.rename(file.path);
    }
  }

  Future<List<File>> _files(String? pluginId) async {
    final directory = _directory;
    if (directory == null || !await directory.exists()) return [];
    if (pluginId != null) {
      return [
        for (final file in [_file(pluginId, rotated: true), _file(pluginId)])
          if (await file.exists()) file,
      ];
    }
    return [
      await for (final entity in directory.list(followLinks: false))
        if (entity is File && entity.path.endsWith('.jsonl')) entity,
    ];
  }

  Future<String> read({String? pluginId}) async {
    final result = StringBuffer();
    for (final file in await _files(pluginId)) {
      try {
        result.write(await _read(file));
      } on FileSystemException {
        // 仍返回其他可读分区的诊断记录。
      }
    }
    return result.toString();
  }

  Future<String> _read(File file) async =>
      utf8.decode(await file.readAsBytes(), allowMalformed: true);

  void reset() {
    _buffers.clear();
    _directory = null;
  }
}

class _PluginLogBuffer {
  final lines = <String>[];
  int bytes = 0;
  int dropped = 0;
}
