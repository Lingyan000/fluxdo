/// AVIF 快桥:直连 flutter_avif 的 FFI 符号,替换其 Dart 层慢桥。
///
/// ## 为什么要绕开官方桥
///
/// flutter_avif 官方桥(`FlutterAvifImpl` + `MultiFrameAvifCodec`)的每帧
/// 路径全部发生在**主 isolate**:
///
/// 1. native port 回包 → `CodedBufferReader` 全量 protobuf 解析,bytes
///    字段 sublist(拷贝①);
/// 2. `Uint8List.fromList(frame.data)`(拷贝②);
/// 3. `decodeImageFromPixels` 内部 `ImmutableBuffer.fromUint8List`(拷贝③)。
///
/// 一帧 512px 贴纸 RGBA = 1MB,20fps × 同屏 N 个动图 = 主线程每秒数百 MB
/// memcpy + 等量短命大对象(滚动 GC 停顿双因子之一,见帧监控)。
///
/// ## 本桥做法
///
/// - 请求侧手写 protobuf 编码(KeyRequest 只有 2 个字段);
/// - 响应侧手写 wire 解析,RGBA 字段用 `Uint8List.sublistView` 取**零拷贝
///   视图**直接喂 `decodeImageFromPixels` —— 三拷贝 → 一拷贝(引擎内部的
///   ImmutableBuffer 那次躲不掉);
/// - 支持 decode-time 降采样:`decodeImageFromPixels` 的 targetWidth 让
///   引擎直接出小图,超限帧不再"全尺寸建纹理 → GPU 缩放"(纹理上传
///   独占 raster 的病灶从源头消掉)。
///
/// wire 格式对齐 flutter_avif_platform_interface 3.1.0 的 proto 定义
/// (KeyRequest{1:key,2:data} / Frame{1:data,2:duration,3:width,4:height} /
/// AvifInfo{1:width,2:height,3:imageCount,4:duration}),解析器按标准
/// protobuf 规则跳过未知字段,新增字段不破坏兼容。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_avif_platform_interface/flutter_avif_ffi.dart'
    as fa_ffi;
import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart'
    as fap;

/// initMemoryDecoder 的容器元数据(AvifInfo 的手解版)。
class AvifInfoLite {
  const AvifInfoLite({
    required this.width,
    required this.height,
    required this.imageCount,
    required this.durationSec,
  });

  final int width;
  final int height;
  final int imageCount;
  final double durationSec;
}

/// 解出的一帧(image 已按 maxDim 在 decode-time 降采样)。
class AvifFastFrame {
  const AvifFastFrame({required this.image, required this.duration});

  final ui.Image image;
  final Duration duration;
}

typedef _NativeCall = int Function(
  int port,
  ffi.Pointer<ffi.UnsignedChar> ptr,
  int len,
);

class AvifFastBridge {
  AvifFastBridge._();

  static fa_ffi.FlutterAvifFFI? _ffi;
  static bool _unavailable = false;

  /// FFI 符号表从已注册的官方桥实例上取(`store_dart_post_cobject` 已由
  /// 其构造函数调过,本桥不重复初始化);拿不到(理论上只有 web)则
  /// 本桥不可用,调用方回落官方 MultiFrameAvifCodec。
  static fa_ffi.FlutterAvifFFI? get _apiOrNull {
    if (_unavailable) return null;
    if (_ffi != null) return _ffi;
    try {
      final api = fap.FlutterAvifPlatform.api;
      if (api is fap.FlutterAvifImpl) {
        _ffi = api.flutterAvifFFI;
        return _ffi;
      }
    } catch (_) {
      // FlutterAvifPlatform.api 是 late static,未注册时访问会抛
    }
    _unavailable = true;
    return null;
  }

  static bool get available => _apiOrNull != null;

  /// 测试钩子:wire 编解码器的等价性验证入口(不触 FFI)。
  @visibleForTesting
  static Uint8List encodeKeyRequestForTest(String key, List<int> data) =>
      _encodeKeyRequest(key, data);

  @visibleForTesting
  static AvifInfoLite parseAvifInfoForTest(Uint8List buf) =>
      _parseAvifInfo(buf);

  @visibleForTesting
  static Future<AvifFastFrame> frameToImageForTest(
    Uint8List buf, {
    int? maxDim,
  }) =>
      _frameToImage(buf, maxDim: maxDim);

  /// 初始化 Rust 端 decoder(容器解析,不解帧),与官方桥共用同一个
  /// key 索引的 decoder 注册表。
  static Future<AvifInfoLite> initDecoder(String key, Uint8List avifBytes) async {
    final api = _apiOrNull!;
    final response = await _call(
      _encodeKeyRequest(key, avifBytes),
      api.init_memory_decoder,
    );
    return _parseAvifInfo(response as Uint8List);
  }

  /// 增量解下一帧(到尾自动回绕)。[maxDim] 为帧长边上限,超限时
  /// decode-time 降采样直接出小图。
  static Future<AvifFastFrame> getNextFrame(String key, {int? maxDim}) async {
    final api = _apiOrNull!;
    final response = await _call(
      _encodeKeyRequest(key, const [1]),
      api.get_next_frame,
    );
    return _frameToImage(response as Uint8List, maxDim: maxDim);
  }

  /// 释放 Rust 端 decoder(fire-and-forget,与官方桥同语义)。
  static Future<void> disposeDecoder(String key) async {
    final api = _apiOrNull;
    if (api == null) return;
    await _call(_encodeKeyRequest(key, const [1]), api.dispose_decoder);
  }

  // ==================== FFI 调用骨架 ====================

  /// 一次 native port 往返。请求指针在 FFI 调用返回后立即 free
  /// (Rust 端在返回前同步拷走请求,官方桥同款契约)。
  static Future<Object?> _call(Uint8List request, _NativeCall fn) {
    final completer = Completer<Object?>();
    final port = RawReceivePort();
    port.handler = (Object? response) {
      port.close();
      completer.complete(response);
    };
    final ptr = malloc<ffi.Uint8>(request.length + 1);
    final native = ptr.asTypedList(request.length + 1);
    native.setAll(0, request);
    native[request.length] = 0;
    try {
      fn(port.sendPort.nativePort, ptr.cast(), request.length);
    } catch (e, st) {
      port.close();
      completer.completeError(e, st);
    } finally {
      malloc.free(ptr);
    }
    return completer.future;
  }

  // ==================== protobuf 手编/手解 ====================

  /// KeyRequest{ 1: key(string), 2: data(bytes) }
  static Uint8List _encodeKeyRequest(String key, List<int> data) {
    final keyBytes = utf8.encode(key);
    final b = BytesBuilder(copy: false);
    b.addByte(0x0A); // field 1, wire 2
    _writeVarint(b, keyBytes.length);
    b.add(keyBytes);
    b.addByte(0x12); // field 2, wire 2
    _writeVarint(b, data.length);
    b.add(data);
    return b.takeBytes();
  }

  static void _writeVarint(BytesBuilder b, int value) {
    var v = value;
    while (v >= 0x80) {
      b.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    b.addByte(v);
  }

  /// AvifInfo{ 1: width, 2: height, 3: imageCount, 4: duration(double) }
  static AvifInfoLite _parseAvifInfo(Uint8List buf) {
    var width = 0, height = 0, imageCount = 1;
    var durationSec = 0.0;
    final c = _Cursor();
    while (c.o < buf.length) {
      final tag = _readVarint(buf, c);
      switch (tag) {
        case 0x08: // field 1 varint
          width = _readVarint(buf, c);
        case 0x10: // field 2 varint
          height = _readVarint(buf, c);
        case 0x18: // field 3 varint
          imageCount = _readVarint(buf, c);
        case 0x21: // field 4 fixed64 (double)
          durationSec =
              ByteData.sublistView(buf, c.o, c.o + 8).getFloat64(0, Endian.little);
          c.o += 8;
        default:
          _skipField(buf, c, tag & 7);
      }
    }
    return AvifInfoLite(
      width: width,
      height: height,
      imageCount: imageCount,
      durationSec: durationSec,
    );
  }

  /// Frame{ 1: data(bytes), 2: duration(double), 3: width, 4: height }
  /// → ui.Image(RGBA 零拷贝视图直接喂引擎,超限帧 decode-time 降采样)。
  static Future<AvifFastFrame> _frameToImage(
    Uint8List buf, {
    int? maxDim,
  }) async {
    Uint8List? rgba;
    var durationSec = 0.0;
    var width = 0, height = 0;
    final c = _Cursor();
    while (c.o < buf.length) {
      final tag = _readVarint(buf, c);
      switch (tag) {
        case 0x0A: // field 1 bytes
          final len = _readVarint(buf, c);
          rgba = Uint8List.sublistView(buf, c.o, c.o + len); // 零拷贝
          c.o += len;
        case 0x11: // field 2 fixed64 (double)
          durationSec =
              ByteData.sublistView(buf, c.o, c.o + 8).getFloat64(0, Endian.little);
          c.o += 8;
        case 0x18: // field 3 varint
          width = _readVarint(buf, c);
        case 0x20: // field 4 varint
          height = _readVarint(buf, c);
        default:
          _skipField(buf, c, tag & 7);
      }
    }
    if (rgba == null || width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      throw StateError(
        'AvifFastBridge: malformed frame response '
        '(w=$width h=$height rgba=${rgba?.length})',
      );
    }

    int? targetW, targetH;
    if (maxDim != null && (width > maxDim || height > maxDim)) {
      // 只给长边,短边由引擎按宽高比推出
      if (width >= height) {
        targetW = maxDim;
      } else {
        targetH = maxDim;
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      targetWidth: targetW,
      targetHeight: targetH,
      allowUpscaling: false,
    );
    final image = await completer.future;
    return AvifFastFrame(
      image: image,
      duration: Duration(milliseconds: (durationSec * 1000).round()),
    );
  }

  static int _readVarint(Uint8List buf, _Cursor c) {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = buf[c.o++];
      result |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) break;
      shift += 7;
    }
    return result;
  }

  /// 跳过未知字段(前向兼容:未来 proto 加字段不破坏解析)。
  static void _skipField(Uint8List buf, _Cursor c, int wireType) {
    switch (wireType) {
      case 0: // varint
        _readVarint(buf, c);
      case 1: // fixed64
        c.o += 8;
      case 2: // length-delimited
        c.o += _readVarint(buf, c);
      case 5: // fixed32
        c.o += 4;
      default:
        throw StateError('AvifFastBridge: unsupported wire type $wireType');
    }
  }
}

class _Cursor {
  int o = 0;
}
