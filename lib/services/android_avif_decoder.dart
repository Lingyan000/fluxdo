import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 上的 AVIF 解码(原生 libavif + dav1d,后台任务队列)。
///
/// 引擎的系统解码路径对 AVIF 会让 UI 线程等单一 IO 线程解析图片头,IO 线程
/// 还在解上一张时 UI 线程一直被卡住;系统 ImageDecoder 也不支持解码时缩小。
/// 原生侧见 `AndroidAvifChannel.kt`。
///
/// 其它平台、或当前引擎没注册通道(如独立窗口引擎)时 [isAvailable] 为
/// false,调用方回落到原有路径。
class AndroidAvifDecoder {
  AndroidAvifDecoder._();

  static const _channel = MethodChannel('com.fluxdo/avif');

  /// 没有目标尺寸时的长边上限(2048px RGBA = 16MB,在解码闸门的单图
  /// 预算 32MB 以内)。
  static const int maxDisplayDim = 2048;

  /// 通道缺失时置位,本次运行不再尝试。
  static bool _missing = false;

  @visibleForTesting
  static bool? debugAvailableOverride;

  static bool get isAvailable =>
      debugAvailableOverride ?? (!kIsWeb && Platform.isAndroid && !_missing);

  static Future<Map<Object?, Object?>?> _decode(
    Uint8List bytes, {
    int? maxDim,
    required bool png,
  }) async {
    try {
      return await _channel.invokeMapMethod<Object?, Object?>('decode', {
        'bytes': bytes,
        'maxDim': maxDim ?? 0,
        'png': png,
      });
    } on MissingPluginException {
      _missing = true;
      return null;
    }
  }

  /// 解首帧并编码成 PNG(长边不超过 [maxDim])。用于缩略图:结果直接写
  /// 缓存,不必把纹理从 GPU 读回再编码。无法解码时返回 null。
  static Future<({Uint8List png, int width, int height})?> decodePng(
    Uint8List bytes, {
    required int maxDim,
  }) async {
    final result = await _decode(bytes, maxDim: maxDim, png: true);
    final png = result?['png'];
    if (png is! Uint8List) return null;
    return (
      png: png,
      width: result!['width'] as int,
      height: result['height'] as int,
    );
  }

  /// 解首帧为可直接显示的单帧 codec(长边不超过 [maxDim],null 为原尺寸)。
  /// 像素是预乘 RGBA,走 [ui.ImageDescriptor.raw],不经过引擎的格式探测,
  /// 不会让 UI 线程等待。无法解码时返回 null。
  static Future<ui.Codec?> instantiateCodec(
    Uint8List bytes, {
    int? maxDim,
  }) async {
    final result = await _decode(bytes, maxDim: maxDim, png: false);
    final rgba = result?['rgba'];
    if (rgba is! Uint8List) return null;
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: result!['width'] as int,
      height: result['height'] as int,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    buffer.dispose();
    return descriptor.instantiateCodec();
  }
}
