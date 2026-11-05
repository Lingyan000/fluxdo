import 'dart:async';
import 'dart:typed_data';

/// 已完成下载的字节只在有预算时交给后台落盘。
/// 调用方等待 admission 时必须保留下载槽，避免慢磁盘积压下载结果。
class ImageCacheWriteQueue {
  ImageCacheWriteQueue({this.maxCount = 2, this.maxBytes = 8 << 20})
    : assert(maxCount > 0),
      assert(maxBytes > 0);

  final int maxCount;
  final int maxBytes;
  final _active = <String, PendingImageWrite>{};
  final _waiting = <Object>[];
  int _bytes = 0;
  Completer<void> _changed = Completer<void>();

  PendingImageWrite? operator [](String key) => _active[key];

  /// 小文件返回时已开始写入；超预算先等待，单个超大文件独占且等写完。
  /// 字节直接共享原 Uint8List，不额外复制。错误由 [write] 的调用方处理。
  Future<void> schedule(
    String key,
    Uint8List bytes,
    Future<void> Function() write, {
    bool Function()? isCurrent,
  }) async {
    final ticket = Object();
    _waiting.add(ticket);
    try {
      while (true) {
        if (isCurrent != null && !isCurrent()) return;
        final existing = _active[key];
        if (existing != null) return;
        final oversized = bytes.lengthInBytes > maxBytes;
        final fits =
            identical(_waiting.first, ticket) &&
            _active.length < maxCount &&
            (oversized
                ? _active.isEmpty
                : _bytes + bytes.lengthInBytes <= maxBytes);
        if (fits) {
          final pending = PendingImageWrite(bytes);
          _active[key] = pending;
          _bytes += bytes.lengthInBytes;
          unawaited(_run(key, pending, write));
          if (oversized) await pending.completed;
          return;
        }
        await _changed.future;
      }
    } finally {
      _waiting.remove(ticket);
      _notify();
    }
  }

  void _notify() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  Future<void> _run(
    String key,
    PendingImageWrite pending,
    Future<void> Function() write,
  ) async {
    var success = false;
    try {
      await write();
      success = true;
    } catch (_) {
      // 后台错误不能变成未处理异常；文件消费者会检查最终文件是否存在。
    } finally {
      _active.remove(key);
      _bytes -= pending.bytes.lengthInBytes;
      pending._completed.complete(success);
      _notify();
    }
  }

  /// 等待调用时已开始的写入；用于文件消费者、缓存清理与测试收尾。
  Future<void> finishWhere(bool Function(String) predicate) async {
    await Future.wait([
      for (final entry in _active.entries)
        if (predicate(entry.key)) entry.value.completed,
    ]);
  }
}

class PendingImageWrite {
  PendingImageWrite(this.bytes);
  final Uint8List bytes;
  final _completed = Completer<bool>();
  Future<bool> get completed => _completed.future;
}
