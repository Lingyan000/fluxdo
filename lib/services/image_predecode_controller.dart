import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 查看器只预解码一张静态邻图；不持有解码帧，不驱逐其他页面的缓存。
class ImagePredecodeController {
  int _generation = 0;
  bool _disposed = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Timer? _timeout;

  /// 限定为查看器的等比缩小 provider，预算同时约束原始位图和输出位图。
  /// 某些平台 codec 先解原图再缩小，因此不能只按缩小后的大小估算峰值。
  Future<void> prefetch({
    required ResizeImage provider,
    required Future<Uint8List> Function() loadBytes,
    required ImageConfiguration configuration,
  }) async {
    cancel();
    if (_disposed ||
        provider.policy != ResizeImagePolicy.fit ||
        provider.allowUpscaling ||
        provider.useLogicalSize) {
      return;
    }
    final generation = _generation;
    bool stale() => _disposed || generation != _generation;
    final cache = PaintingBinding.instance.imageCache;
    final budget = math.min(16 * 1024 * 1024, cache.maximumSizeBytes ~/ 8);
    if (budget <= 0 || cache.maximumSize == 0) return;

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? probe;
    try {
      final status = await provider.obtainCacheStatus(
        configuration: configuration,
      );
      if (stale() || status?.tracked == true) return;
      final bytes = await loadBytes();
      if (stale() || bytes.length > budget) return;
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      if (stale()) return;
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      // 原图也计入预算，保守跳过高像素图片；不会改变用户点开后的清晰度。
      if (stale() || descriptor.width * descriptor.height * 4 > budget) return;
      probe = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      if (stale() || probe.frameCount != 1) return;
      _stream = provider.resolve(configuration);
      _listener = ImageStreamListener(
        (info, synchronousCall) {
          info.dispose();
          // 同步命中时也等 addListener 完成后再释放。
          scheduleMicrotask(() {
            if (!stale()) _releaseStream();
          });
        },
        onError: (Object error, StackTrace? stack) {
          scheduleMicrotask(() {
            if (!stale()) _releaseStream();
          });
        },
      );
      _timeout = Timer(const Duration(seconds: 10), () {
        if (!stale()) cancel();
      });
      _stream!.addListener(_listener!);
    } catch (_) {
      // 预取失败不影响当前图，也不向页面报告后台加载错误。
      if (!stale()) _releaseStream();
    } finally {
      probe?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _releaseStream() {
    _timeout?.cancel();
    _timeout = null;
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  void cancel() {
    _generation++;
    _releaseStream();
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
