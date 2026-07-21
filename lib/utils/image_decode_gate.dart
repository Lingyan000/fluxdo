import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'frame_jank_monitor.dart';
import 'frame_scheduler_probe.dart';
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
/// engine 限解码并发 2~3 + 串行上传,两者都证明并发 2 对**大图**加载
/// 速度无感。本闸门是它们在纯 Dart 层的等价物:解码并发 ≤2 ⇒ 上传
/// 并发 ≤2,且每路解码本身耗时 ≥ 数 ms,天然把上传摊开错峰。
///
/// ## 双档语义:小图旁路,限流只属于大图
///
/// 病灶是**大纹理**上传争抢 GPU 队列;64px emoji 纹理 ~16KB,与病灶差
/// 三个数量级,过闸纯属误伤 —— 表情面板挂载瞬间 ~200 张小图串进并发 2
/// 的队列,填满要 1~2.5s(闸门上线前引擎并行解,数百 ms 渐进填满)。
///
/// 参照 Telegram 双端的收敛形态:Android 缩略图队列 cacheThumbOutQueue
/// 从不设闸、HwEmojis 只暂停大图队列;iOS 首帧走独立 userInteractive
/// 高优队列,与全量解码物理分离 —— **小图/首帧通道一律不限流,单一
/// 全局共享计数器在两家均无对应物**。故本闸门按有效解码长边分档:
///
/// - ≤ [smallImageMaxEdge](128px,emoji/头像/tab 图标)→ 旁路闸门
///   ([GatedImageCodec.ungated],不占名额,保留 dec 归因),由引擎
///   worker 池自然并行;
/// - 其余(正文大图)→ [GatedImageCodec],并发 2,行为不变。
///
/// 判据是解码产物尺寸(数据特征),不是 URL 白名单;尺寸在
/// `getTargetSize` 回调里捕获([_SizeCapture]),对
/// ResizeImage / 固有尺寸全路径可得。
///
/// ## 覆盖面
///
/// [FluxdoWidgetsBinding] 覆写 `instantiateImageCodecWithSize`,凡走
/// 框架标准解码回调的图(正文 LazyImage/ResizeImage、头像 CNI、emoji、
/// 一切 NetworkImage/FileImage/MemoryImage)统一分档,零调用方改动。
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

  /// 小图旁路阈值:有效解码长边 ≤ 此值的图不过闸。
  ///
  /// 128px 覆盖 emoji(64)、tab 图标(48)、头像(40~100)、emoji 搜索
  /// (80)。128px RGBA 纹理 ~64KB,即使同帧到达几十张,上传增量对
  /// graphics 队列仍可忽略;正文图最小也在几百 px 档,不会误入。
  static const int smallImageMaxEdge = 128;

  /// 并发上限。取 Immich(固定 2)/AliFlutter(2~3)/engine worker 池
  /// 下限(2)的收敛值:低于引擎自身并发才有错峰效果,2 路吞吐
  /// (每槽 10~50ms ≈ 40~200 张/秒)对大图列表滚动绰绰有余。
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

  /// 申请名额:未满直接获准(返回 null);满员入队,返回排队句柄供
  /// [GatedImageCodec] 在 dispose 时主动退队。
  static Completer<void>? _acquireOrEnqueue() {
    if (_inFlight < _maxInFlight) {
      _inFlight++;
      return null;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer;
  }

  /// 把仍在排队的申请摘除(codec 排队期间被 dispose 时调用)。
  ///
  /// 摘除成功 = 名额从未持有,以 error 完成其 future 让等待方立刻退出
  /// 且**不归还名额**(归还会超发,并发 2 会越放越松);已被授予名额的
  /// (完成竞态,牌已不在队里)摘不到,走 getNextFrame 里的 _disposed
  /// 惰性检查 + finally 归还的老路兜底。
  static void _cancelWaiter(Completer<void> completer) {
    if (_waiters.remove(completer)) {
      completer.completeError(const _CancelledWhileQueued());
    }
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

/// 排队期间被 dispose 主动退队的标记异常,仅在闸门内部流转。
class _CancelledWhileQueued implements Exception {
  const _CancelledWhileQueued();
}

/// 包装引擎 codec:首帧解码(= Impeller 纹理上传点)过 [ImageDecodeGate]。
///
/// [GatedImageCodec.ungated] 是小图旁路专用变体:不占并发名额,但首帧
/// 仍上报 dec 事件 —— 监控的判定口径是"零 dec 的 raster 大帧 = 排除
/// 图片",旁路不能让小图从帧账单里消失,否则归因盲区重现。
class GatedImageCodec implements ui.Codec {
  GatedImageCodec(this._inner) : _gated = true;

  GatedImageCodec.ungated(this._inner) : _gated = false;

  final ui.Codec _inner;
  final bool _gated;
  bool _firstFrameGated = false;
  bool _disposed = false;

  /// 排队中的号码牌;拿到名额或退队后归 null。
  Completer<void>? _queuedWaiter;

  @override
  int get frameCount => _inner.frameCount;

  @override
  int get repetitionCount => _inner.repetitionCount;

  @override
  void dispose() {
    _disposed = true;
    // 还在排队就主动退队,免得快滚划走一串图后队列里全是死号:
    // 每个死号轮到时都要空转一次"喊号→发现已死→抛异常",且监控
    // 看到的排队深度全是虚的。
    final waiter = _queuedWaiter;
    _queuedWaiter = null;
    if (waiter != null) ImageDecodeGate._cancelWaiter(waiter);
    _inner.dispose();
  }

  @override
  Future<ui.FrameInfo> getNextFrame() {
    if (_firstFrameGated) return _inner.getNextFrame();
    _firstFrameGated = true;
    return _gatedFirstFrame();
  }

  Future<ui.FrameInfo> _gatedFirstFrame() async {
    final waiter = _gated ? ImageDecodeGate._acquireOrEnqueue() : null;
    if (waiter != null) {
      _queuedWaiter = waiter;
      try {
        await waiter.future;
      } on _CancelledWhileQueued {
        // dispose 主动退队:名额从未持有,不走 _release。
        throw StateError('GatedImageCodec: codec disposed while queued');
      } finally {
        _queuedWaiter = null;
      }
    }
    // 至此已持有名额(旁路 codec 从未申请,无须归还),任何出口都必须归还。
    try {
      // 授予名额与 dispose 存在微任务竞态(牌已出队、future 未跑),
      // 退队路径摘不到,靠这里的惰性检查兜底。dart:ui 的 getNextFrame
      // 对已 dispose 的 native peer 没有防护,改抛异常 —— 框架侧本就有
      // "codec was disposed during getNextFrame" 的静默兜底路径
      // (catch → reportError(silent))。
      if (_disposed) {
        throw StateError('GatedImageCodec: codec disposed while queued');
      }
      final info = await _inner.getNextFrame();
      // 解码完成点 = Impeller 纹理上传点(worker 解完立即建纹理提交
      // GPU 队列)。在场名单记 dec 事件补上归因盲区:img+ 记的是**首绘**,
      // 上传发生在**此刻**,两者可以差很多帧(快滚划走的图甚至永远没有
      // img+)。raster 大帧同帧/邻帧见 dec = 上传嫌疑坐实;零 dec 的
      // raster 大帧 = 排除图片,矛头转向字形图集等。
      FrameJankMonitor.noteBuild(
        'dec:${info.image.width}x${info.image.height}',
      );
      return info;
    } finally {
      if (_gated) ImageDecodeGate._release();
    }
  }
}

/// 应用级 binding:接管框架标准图片解码入口,给所有标准路径的图
/// 套上 [ImageDecodeGate];并混入 [PerfPipelineProbe] 提供 UI 相位
/// 拆分、[FrameSchedulerProbe] 提供帧调度归因(监控关闭时零成本)。
/// 必须在 main() 里以 `FluxdoWidgetsBinding.ensureInitialized()` 替代
/// `WidgetsFlutterBinding.ensureInitialized()`。
class FluxdoWidgetsBinding extends WidgetsFlutterBinding
    with PerfPipelineProbe, FrameSchedulerProbe {
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
    //
    // 包一层 getTargetSize 捕获有效解码尺寸做大小分档。引擎保证该回调
    // 在 instantiateImageCodecWithSize 返回前被调用(ImageDescriptor
    // 解析完文件头即回调),所以 await super 之后尺寸必然已捕获。
    final sizeCapture = _SizeCapture(getTargetSize);
    final codec = await super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: sizeCapture.capture,
    );
    // 小图旁路:病灶是大纹理上传争抢 GPU 队列,小图过闸纯误伤
    // (表情面板 200 张 64px 串进并发 2 队列 = 数秒填满)。ungated
    // 变体不占名额但保留 dec 上报,帧账单归因口径不变。
    if (sizeCapture.effectiveMaxEdge <= ImageDecodeGate.smallImageMaxEdge) {
      return GatedImageCodec.ungated(codec);
    }
    return GatedImageCodec(codec);
  }
}

/// 包装 [ui.TargetImageSizeCallback],在引擎回调时捕获**有效解码长边**
/// (= 解码产物的实际像素上限,决定纹理大小)。
///
/// 合成规则与引擎一致(dart:ui `instantiateImageCodecWithSize`):
/// - 目标宽高均未指定 → 按固有尺寸解码;
/// - 只指定一边 → 另一边按纵横比缩放,长边不超过指定边与推算边的 max;
/// - 两边都指定 → 取两者 max。
class _SizeCapture {
  _SizeCapture(this._inner);

  final ui.TargetImageSizeCallback? _inner;

  /// 有效解码长边。回调未被调用时保持保守默认(视为大图,过闸)——
  /// 理论上不会发生,防御引擎行为变化。
  int effectiveMaxEdge = 1 << 30;

  ui.TargetImageSize capture(int intrinsicWidth, int intrinsicHeight) {
    final target = _inner == null
        ? const ui.TargetImageSize()
        : _inner(intrinsicWidth, intrinsicHeight);
    final w = target.width;
    final h = target.height;
    if (w == null && h == null) {
      effectiveMaxEdge = _max(intrinsicWidth, intrinsicHeight);
    } else if (w != null && h != null) {
      effectiveMaxEdge = _max(w, h);
    } else if (w != null) {
      // 高按纵横比推算(引擎语义),长边 = max(目标宽, 推算高)。
      final scaled = intrinsicWidth == 0
          ? 0
          : (intrinsicHeight * w / intrinsicWidth).round();
      effectiveMaxEdge = _max(w, scaled);
    } else {
      final targetH = h!;
      final scaled = intrinsicHeight == 0
          ? 0
          : (intrinsicWidth * targetH / intrinsicHeight).round();
      effectiveMaxEdge = _max(targetH, scaled);
    }
    return target;
  }

  static int _max(int a, int b) => a > b ? a : b;
}
