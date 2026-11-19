import 'package:flutter/foundation.dart';
import 'package:jovial_svg/jovial_svg.dart';

/// 已解析 SVG 的全局复用，按最终送去解析的源码寻址：不同入口只要清理结果相同，
/// 就共享同一份解析产物，不必各自约定缓存键，也不会串用其他主题的变体。
///
/// - [load]：较大的源码在后台 isolate 解析成 SI 二进制，主线程只做反序列化；
///   并发请求合并，失败结果同样缓存，避免损坏文件在每次构建时反复解析。
/// - [sync]：需要立即布局的场景（帖子内联 SVG、构建期头像）使用，命中缓存时
///   不再解析。能提前异步加载的入口应先 [load]，让构建期只做命中。
///
/// [ScalableImage] 不可变，内嵌图片的 prepare/unprepare 按引用计数，可安全共享。
abstract final class SvgImageCache {
  /// 小图标在主线程解析不足一毫秒，开 isolate 的往返反而更慢。
  static const int _isolateThreshold = 4 << 10;
  static const int _maxBytes = 16 << 20;
  static const int _maxEntries = 512;

  static final _entries = <String, _Entry>{};
  static final _pending = <String, Future<ScalableImage>>{};
  static int _bytes = 0;

  static ScalableImage? peek(String source) {
    final entry = _touch(source);
    return entry?.image;
  }

  static ScalableImage sync(String source) {
    final entry = _touch(source) ?? _store(source, _parse(source));
    return entry.image ?? (throw entry.error!);
  }

  static Future<ScalableImage> load(String source) {
    final entry = _touch(source);
    if (entry != null) {
      return entry.image != null
          ? SynchronousFuture(entry.image!)
          : Future.error(entry.error!);
    }
    // 回调不能返回 remove 的结果：那正是本 future，whenComplete 会等它自己。
    return _pending[source] ??= _loadUncached(source).whenComplete(() {
      _pending.remove(source);
    });
  }

  static Future<ScalableImage> _loadUncached(String source) async {
    _Entry? entry;
    if (source.length >= _isolateThreshold) {
      try {
        final bytes = await compute(_toSIBytes, source);
        entry = _Entry.image(ScalableImage.fromSIBytes(bytes));
      } catch (_) {
        // 后台解析不可用或失败时退回主线程，结果以主线程解析为准。
      }
    }
    entry = _store(source, entry ?? _parse(source));
    return entry.image ?? (throw entry.error!);
  }

  static _Entry _parse(String source) {
    try {
      return _Entry.image(ScalableImage.fromSvgString(source, warnF: (_) {}));
    } catch (error) {
      return _Entry.error(error);
    }
  }

  static _Entry? _touch(String source) {
    final entry = _entries.remove(source);
    if (entry != null) _entries[source] = entry;
    return entry;
  }

  static _Entry _store(String source, _Entry entry) {
    final old = _entries.remove(source);
    if (old != null) _bytes -= _cost(source);
    _entries[source] = entry;
    _bytes += _cost(source);
    while ((_bytes > _maxBytes || _entries.length > _maxEntries) &&
        _entries.length > 1) {
      final key = _entries.keys.first;
      _entries.remove(key);
      _bytes -= _cost(key);
    }
    return entry;
  }

  /// 源码键本身加解析产物，按源码长度粗估。
  static int _cost(String source) => source.length * 4;

  @visibleForTesting
  static void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

class _Entry {
  _Entry.image(ScalableImage this.image) : error = null;
  _Entry.error(Object this.error) : image = null;
  final ScalableImage? image;
  final Object? error;
}

/// bigFloats 保留双精度坐标，反序列化后与主线程直接解析逐像素一致。
Uint8List _toSIBytes(String source) => ScalableImage.fromSvgString(
  source,
  compact: true,
  bigFloats: true,
  warnF: (_) {},
).toSIBytes();
