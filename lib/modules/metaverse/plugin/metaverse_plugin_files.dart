import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';

/// 字节只保存在当前宿主内存中；脚本只持有与界面绑定的临时句柄。
class MetaversePickedFile {
  const MetaversePickedFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

class MetaverseFileSelection {
  const MetaverseFileSelection(this.extensions, this.maxBytes);
  final List<String> extensions;
  final int maxBytes;
  static MetaverseFileSelection parse(Map<String, Object?> options) {
    final raw = options['extensions'],
        limit = options['maxBytes'] ?? 5 * 1024 * 1024;
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 16 ||
        raw.any(
          (v) => v is! String || !RegExp(r'^[a-z0-9]{1,12}$').hasMatch(v),
        ) ||
        limit is! int ||
        limit < 1 ||
        limit > 16 * 1024 * 1024) {
      throw const MetaversePluginCallException('file_selection_invalid');
    }
    return MetaverseFileSelection(List<String>.from(raw), limit);
  }
}

class MetaverseFileVault {
  final _files = <String, ({String surface, MetaversePickedFile file})>{};
  final _operations = <String, ({String surface, CancelToken cancel})>{};
  Map<String, Object> keep(
    String surface,
    MetaversePickedFile file,
    MetaverseFileSelection selection,
  ) {
    final extension = file.name.split('.').last.toLowerCase();
    if (!selection.extensions.contains(extension) ||
        file.bytes.isEmpty ||
        file.bytes.length > selection.maxBytes ||
        file.name.length > 255 ||
        file.name.contains(RegExp(r'[/\\\x00-\x1f\x7f]'))) {
      throw const MetaversePluginCallException('file_type_or_size_invalid');
    }
    if (_files.length >= 8 ||
        _files.values.fold<int>(0, (n, v) => n + v.file.bytes.length) +
                file.bytes.length >
            32 * 1024 * 1024) {
      throw const MetaversePluginCallException('file_capacity_exceeded');
    }
    final handle = const Uuid().v4();
    _files[handle] = (surface: surface, file: file);
    return {
      'handle': handle,
      'name': file.name,
      'size': file.bytes.length,
      'mimeType':
          lookupMimeType(file.name, headerBytes: file.bytes) ??
          'application/octet-stream',
    };
  }

  MetaversePickedFile read(String surface, Object? handle) {
    final entry = _files[handle];
    if (entry == null || entry.surface != surface) {
      throw const MetaversePluginCallException('file_handle_invalid');
    }
    return entry.file;
  }

  void release(String surface, Object? handle) {
    read(surface, handle);
    _files.remove(handle);
  }

  CancelToken start(String surface, Object? id) {
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ||
        _operations.containsKey(id) ||
        _operations.length >= 2) {
      throw const MetaversePluginCallException('file_operation_invalid');
    }
    final cancel = CancelToken();
    _operations[id] = (surface: surface, cancel: cancel);
    return cancel;
  }

  void finish(String id, CancelToken cancel) {
    if (identical(_operations[id]?.cancel, cancel)) _operations.remove(id);
  }

  void cancel(String surface, Object? id) {
    final entry = _operations[id];
    if (entry?.surface == surface) entry!.cancel.cancel();
  }

  bool close([String? surface]) {
    final removed = _files.values.any(
      (entry) => surface == null || entry.surface == surface,
    );
    for (final key in _operations.keys.toList()) {
      if (surface == null || _operations[key]!.surface == surface) {
        _operations.remove(key)!.cancel.cancel();
      }
    }
    _files.removeWhere(
      (_, entry) => surface == null || entry.surface == surface,
    );
    return removed;
  }
}
