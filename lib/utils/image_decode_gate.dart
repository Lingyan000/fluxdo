import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'perf_pipeline_probe.dart';

/// 全局图片解码并发闸门:限制同一时刻在引擎里跑的图片解码任务数。
///
/// ## 为什么闸解码就是闸纹理上传(病灶与对症关系)
///
/// Impeller 的解码与上传绑死在同一个 worker 任务里:worker 线程解压完
/// 位图立刻创建 device 纹理 → blit + GenerateMipmap → 提交到**与 raster
/// 共用的单条 graphics 队列**(engine 从未启用独立 transfer queue,见
/// flutter#123791;上传时机是"解码完成时"而非"首次绘制时")。engine
/// 的 worker 池并发 2~4(engine#52423),图密话题快滚时多张图同时解码
/// 完成 = 多路上传同帧争抢 GPU 队列,实测 raster 单帧被顶到 48~112ms
/// (帧清单零 img 记录 + pending 高位,paint 层闸门无法触及)。
///
/// 因此唯一的 app 层控制点在 `getNextFrame()` 之前 —— 这是业界收敛的
/// 同款方案:Immich 远程图用固定 2 线程的原生解码池、AliFlutter 定制
/// engine 限解码并发 2~3 + 串行上传,两者都证明并发 2 对加载速度无感。
/// 本闸门是它们在纯 Dart 层的等价物:解码并发 ≤2 ⇒ 上传并发 ≤2,
/// 且每路解码本身耗时 ≥ 数 ms,天然把上传摊开错峰。
///
/// ## 覆盖面
///
/// [FluxdoWidgetsBinding] 覆写 `instantiateImageCodecWithSize`,凡走
/// 框架标准解码回调的图(正文 LazyImage/ResizeImage、头像 CNI、emoji、
/// 一切 NetworkImage/FileImage/MemoryImage)统一过闸,零调用方改动。
/// 自带解码管线的 provider(AVIF/贴纸的 Rust 解码 + 自有信号量、
/// native_animated_image 逐帧)不在此闸内 —— 它们各有独立限流,且与
/// 正文图分队避免贴纸面板堵塞帖内图片。
///
/// ## 语义细节
///
/// - 只闸**首帧**:动图后续帧走原速,闸了会破坏播放节奏;首帧之后
///   codec 已热,逐帧解码由动图自身的帧调度节流。
/// - 缓存命中天然旁路:ImageCache 命中根本不会创建新 codec。
/// - 排队图片的表现 = 占位多留几帧(队列深度常态个位数、单槽周转
///   10~50ms),与现有"下载等待"占位完全同款,无新视觉状态。
class ImageDecodeGate {
  ImageDecodeGate._();

  /// 并发上限。取 Immich(固定 2)/AliFlutter(2~3)/engine worker 池
  /// 下限(2)的收敛值:低于引擎自身并发才有错峰效果,2 路吞吐
  /// (每槽 10~50ms ≈ 40~200 张/秒)远超列表滚动的需求。
  static const int _maxInFlight = 2;

  static int _inFlight = 0;
  static final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  static Future<void> _acquire() {
    if (_inFlight < _maxInFlight) {
      _inFlight++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  static void _release() {
    if (_waiters.isNotEmpty) {
      // 名额直接移交队首,_inFlight 不变
      _waiters.removeFirst().complete();
    } else {
      _inFlight--;
    }
  }

  /// 在闸门内执行一个解码任务(异常也保证归还名额)。
  static Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }
}

/// 包装引擎 codec:首帧解码(= Impeller 纹理上传点)过 [ImageDecodeGate]。
class GatedImageCodec implements ui.Codec {
  GatedImageCodec(this._inner);

  final ui.Codec _inner;
  bool _firstFrameGated = false;
  bool _disposed = false;

  @override
  int get frameCount => _inner.frameCount;

  @override
  int get repetitionCount => _inner.repetitionCount;

  @override
  void dispose() {
    _disposed = true;
    _inner.dispose();
  }

  @override
  Future<ui.FrameInfo> getNextFrame() {
    if (_firstFrameGated) return _inner.getNextFrame();
    _firstFrameGated = true;
    return ImageDecodeGate.run(() {
      // 排队期间可能被 dispose(图滚出视口、监听者清空、cache 驱逐 →
      // MultiFrameImageStreamCompleter._maybeDispose 释放 codec)。
      // dart:ui 的 getNextFrame 对已 dispose 的 native peer 没有防护,
      // 出队后再调用是未定义行为;这里改抛异常 —— 框架侧本就有
      // "codec was disposed during getNextFrame" 的静默兜底路径
      // (catch → reportError(silent))。副产品是队列级取消:已死的
      // 解码请求不再白白占名额解码 + 上传。
      if (_disposed) {
        throw StateError('GatedImageCodec: codec disposed while queued');
      }
      return _inner.getNextFrame();
    });
  }
}

/// 应用级 binding:接管框架标准图片解码入口,给所有标准路径的图
/// 套上 [ImageDecodeGate];并混入 [PerfPipelineProbe] 提供 UI 相位
/// 拆分(监控关闭时零成本)。必须在 main() 里以
/// `FluxdoWidgetsBinding.ensureInitialized()` 替代
/// `WidgetsFlutterBinding.ensureInitialized()`。
class FluxdoWidgetsBinding extends WidgetsFlutterBinding
    with PerfPipelineProbe {
  static FluxdoWidgetsBinding? _instance;

  static FluxdoWidgetsBinding ensureInitialized() =>
      _instance ??= FluxdoWidgetsBinding();

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    // codec 实例化只是解析文件头,便宜;真正的解压 + 上传发生在
    // getNextFrame,由 GatedImageCodec 负责过闸。
    final codec = await super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
    return GatedImageCodec(codec);
  }
}
