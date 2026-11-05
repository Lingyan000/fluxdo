import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';

/// 标记 ImageCache 自己的 pending 监听，避免它被误算成仍在看图的视图。
/// ResizeImage 也使用同一缓存入口，淘汰时使用外层真实 key。
class ManagedImageCache extends ImageCache {
  @override
  ImageStreamCompleter? putIfAbsent(
    Object key,
    ImageStreamCompleter Function() loader, {
    ImageErrorListener? onError,
  }) {
    CancelableImageStreamCompleter? created;
    try {
      return super.putIfAbsent(key, () {
        final result = loader();
        if (result is CancelableImageStreamCompleter) {
          created = result;
          result.registeringCache = true;
          result.evictPending = () => evict(key);
        }
        return result;
      }, onError: onError);
    } finally {
      created?.registeringCache = false;
    }
  }
}

/// 同一 completer 的所有消费者退出后，给快速滚回留 250ms，再释放下载租约。
/// 缓存内部监听不计作消费者；其他视图、precacheImage 的监听仍计数。
class CancelableImageStreamCompleter extends MultiFrameImageStreamCompleter {
  CancelableImageStreamCompleter({
    required super.codec,
    required super.scale,
    super.chunkEvents,
    super.debugLabel,
    super.informationCollector,
    required this.cancellation,
  });

  final CancelToken cancellation;
  bool registeringCache = false;
  void Function()? evictPending;
  final _cacheListeners = <ImageStreamListener>[];
  final _consumers = <ImageStreamListener>[];
  Timer? _abandon;
  bool loadComplete = false;
  bool _disposed = false;

  @override
  void addListener(ImageStreamListener listener) {
    (registeringCache ? _cacheListeners : _consumers).add(listener);
    if (!registeringCache) {
      _abandon?.cancel();
      _abandon = null;
    }
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    if (!_cacheListeners.remove(listener)) _consumers.remove(listener);
    super.removeListener(listener);
    if (!_disposed &&
        _consumers.isEmpty &&
        !loadComplete &&
        !cancellation.isCancelled) {
      _abandon ??= Timer(const Duration(milliseconds: 250), () {
        _abandon = null;
        if (_consumers.isNotEmpty || loadComplete) return;
        cancellation.cancel('No image consumers');
        evictPending?.call();
      });
    }
  }

  @override
  void setImage(ImageInfo image) {
    loadComplete = true;
    _abandon?.cancel();
    super.setImage(image);
  }

  @override
  void onDisposed() {
    _disposed = true;
    // Pending cache listener normally keeps the completer alive during grace.
    // When the cache itself is cleared, there is no reason to retain the work.
    _abandon?.cancel();
    if (!loadComplete) cancellation.cancel('Image stream disposed');
    super.onDisposed();
  }
}
