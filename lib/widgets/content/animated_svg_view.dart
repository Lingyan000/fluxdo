// 离屏首帧管线直接使用 full_svg_flutter 的内部实现(见文件尾
// _parseFirstFrameTask):公开 API 只有"挂 widget 同步解析"一条路,
// 而实测该 SVG parse 400ms+ 必须移出 UI isolate。升级包版本若内部
// API 变动,编译期即暴露;运行期任何异常自动回退活体截帧路径。
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:app_icons/app_icons.dart';
import 'package:full_svg_flutter/full_svg_flutter.dart';
import 'package:full_svg_flutter/src/animation/animated_svg_painter.dart';
import 'package:full_svg_flutter/src/animation/smil/smil_animation.dart';
import 'package:full_svg_flutter/src/animation/smil/smil_parser.dart';
import 'package:full_svg_flutter/src/animation/smil/smil_timeline.dart';
import 'package:full_svg_flutter/src/animation/svg_dom.dart';
import 'package:full_svg_flutter/src/animation/svg_parser.dart';
import 'package:full_svg_flutter/src/animation/svg_theme_apply.dart';
import 'package:path_provider/path_provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../utils/svg_utils.dart';

/// 动画 SVG 视图（CSS @keyframes / SMIL / filter 等 jovial_svg 不支持的特性）。
///
/// 性能契约(以 707KB/264 text 层的歌词签名图实测为参照):
/// - 首帧走**离屏管线**:strip+parse+动画装配+seek(0)(~460ms)整体在后台
///   isolate;UI isolate 只付一次 Picture 录制(~60ms,且避开快滚窗口),
///   光栅化在引擎 raster 线程 —— 首次滚到也不再有 400ms 级 build 尖峰;
/// - 快照进内存 LRU + 磁盘 PNG(按内容摘要寻址),同一张图一生只付一次;
/// - 同 key 并发挂载只选举一个实例渲染,其余等快照;
/// - 离屏管线任何异常自动回退"挂活体冻结帧 + boundary 截图"旧路径;
/// - 点击播放先出反馈帧(角标转圈),下一帧再挂活体付 parse;
/// - 暂停不卸载活体(controller.pause,ticker 停),再播零成本;滚出视口自动暂停;
/// - 全局同屏最多 1 个实例在播(新播放抢占旧的)。
///
/// 布局契约:几何主权在本组件,不交给包内部。
/// - 宽高比/自然尺寸**只从根 `<svg>` 标签**取(内层 symbol/view 的
///   viewBox 决不能参与);盒子按浏览器 `<img>` 置换元素语义定形:
///   固有尺寸(缺失一维由另一维 × 固有比例补出,如 width="100%"+
///   height="84"+viewBox → 固有 680×84)+ max-width:100% ——
///   列宽富余时按固有宽摆(随 alignment 左对齐),窄时等比缩不放大;
///   仅 viewBox 无固有尺寸的图撑满可用宽。
/// - **盒内内容映射对齐浏览器 preserveAspectRatio**(默认 xMidYMid
///   meet 等比居中,盒比≠图比时留空不拉伸):活体传 fit: contain +
///   alignment: center——这是包内跳过 FittedBox 分支的唯一组合,
///   CustomPaint 直接吃盒子尺寸,painter 按文档声明做 viewBox 映射;
///   其他 fit 会走包内 FittedBox+intrinsic 分支产生拉伸/居中缩小
///   (定高撑宽的卡片签名曾被 fill 水平拉爆,翻过车)。快照位图按根
///   标签 preserveAspectRatio 选 contain(默认)/fill("none")。
///   外部传入的 fit 不参与内部渲染。
///
/// 安全契约:进入活体渲染的源码一律先 [SvgUtils.stripActiveContent]
/// （full_svg_flutter 会真实执行 `<script>`,包括拉取外链脚本,
/// `<image href="file://">` 会读本地文件——论坛内容是不可信输入）。
/// 剥离是懒的:只在真正挂活体时执行,贴快照的实例不付这三遍正则。
class AnimatedSvgView extends StatefulWidget {
  final String svgSource;
  final BoxFit fit;

  /// 画面在可用空间内的对齐(帖子流左对齐,查看器居中)。
  final Alignment alignment;

  /// 挂载即播放:仅用于用户主动打开单图的查看器场景
  /// (全屏一张图,吃满一核也值);帖子流一律 false。
  final bool autoPlay;

  const AnimatedSvgView({
    super.key,
    required this.svgSource,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.centerLeft,
    this.autoPlay = false,
  });

  /// 该 SVG 源码是否含动画(CSS animation/SMIL),
  /// 用于调用方在 jovial_svg 与本组件之间路由。
  static bool hasAnimations(String svgSource) =>
      AnimationDetector.hasAnimations(svgSource);

  /// 根 `<svg>` 标签几何:供管线记入尺寸备忘,
  /// 让占位在加载前就能预留精确高度。
  static ({double aspect, double? naturalW, double? naturalH, bool stretch})
      rootGeometryOf(String svgSource) =>
          _AnimatedSvgViewState._rootGeometryOf(svgSource);

  @override
  State<AnimatedSvgView> createState() => _AnimatedSvgViewState();
}

/// 首帧快照缓存:内存 LRU(key=会话内容 hash) + 磁盘 PNG(key=内容摘要)。
///
/// - 同 key 只允许一个"选举成功"的实例挂活体渲染并截帧,其余实例监听
///   notifier 等快照;渲染者中途 dispose 会退选,唤醒等待者重新选举。
/// - master 归缓存所有,替换/淘汰时 dispose;使用方持 clone,生命周期自管。
class _SvgFirstFrameCache {
  static final Map<int, ui.Image> _images = <int, ui.Image>{};
  static final Map<int, Object> _renderer = <int, Object>{};
  static final Map<int, _BumpNotifier> _notifiers = <int, _BumpNotifier>{};
  static const int _cap = 12;

  // 磁盘层
  static const int _diskCap = 32;
  static Future<Directory>? _dirFuture;

  static ui.Image? peek(int key) {
    final img = _images.remove(key);
    if (img != null) _images[key] = img; // LRU 触摸
    return img;
  }

  /// 尝试成为该 key 的渲染者;已有快照或已被他人占据则失败。
  static bool tryElect(int key, Object token) {
    if (_images.containsKey(key)) return false;
    final cur = _renderer[key];
    if (cur == null) {
      _renderer[key] = token;
      return true;
    }
    return identical(cur, token);
  }

  /// 渲染者未截成帧就退出(如快速滚走被回收),让等待者重新选举。
  static void resign(int key, Object token) {
    if (identical(_renderer[key], token)) {
      _renderer.remove(key);
      _notifiers[key]?.bump();
    }
  }

  static void put(int key, ui.Image master) {
    _renderer.remove(key);
    _images.remove(key)?.dispose();
    _images[key] = master;
    while (_images.length > _cap) {
      final evictKey = _images.keys.first;
      _images.remove(evictKey)?.dispose();
    }
    _notifiers[key]?.bump();
  }

  static _BumpNotifier notifierFor(int key) =>
      _notifiers[key] ??= _BumpNotifier();

  // ---- 磁盘持久化(PNG 解码在引擎 IO 线程,UI isolate 零阻塞) ----

  static Future<Directory> _dir() => _dirFuture ??= () async {
        final base = await getApplicationSupportDirectory();
        final dir = Directory('${base.path}/animated_svg_frames');
        await dir.create(recursive: true);
        return dir;
      }();

  static Future<File> _fileFor(String digest) async =>
      File('${(await _dir()).path}/$digest.png');

  static Future<ui.Image?> loadFromDisk(String digest) async {
    try {
      final file = await _fileFor(digest);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      // 触摸 mtime,配合 prune 做磁盘 LRU
      unawaited(
        file.setLastModified(DateTime.now()).then((_) {}, onError: (_) {}),
      );
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// 持久化 master(接管所有权,保存后 dispose)。
  static Future<void> saveToDisk(String digest, ui.Image master) async {
    try {
      final data = await master.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final file = await _fileFor(digest);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: false);
      unawaited(_prune());
    } catch (_) {
      // 磁盘失败不影响功能,内存层仍在
    } finally {
      master.dispose();
    }
  }

  static Future<void> _prune() async {
    try {
      final dir = await _dir();
      final files = <(File, DateTime)>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.png')) {
          files.add((e, (await e.stat()).modified));
        }
      }
      if (files.length <= _diskCap) return;
      files.sort((a, b) => b.$2.compareTo(a.$2)); // 新→旧
      for (final (f, _) in files.skip(_diskCap)) {
        unawaited(f.delete().then((_) {}, onError: (_) {}));
      }
    } catch (_) {}
  }
}

class _BumpNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}

class _AnimatedSvgViewState extends State<AnimatedSvgView> {
  /// 全局单播放注册表:同屏最多一个实例在播。
  static _AnimatedSvgViewState? _playing;

  /// cacheKey → 快照是否有可见像素:画面空白时不显示播放角标
  /// (悬浮在空白区的控件脱离画面语境,读者无从判断其归属)。
  static final Map<int, bool> _snapshotVisibleByKey = <int, bool>{};

  /// 大字符串门槛:超过则 hash/剥离等全量扫描挪 isolate。
  static const int _bigSourceBytes = 256 << 10;

  final Object _token = Object();
  final GlobalKey _boundaryKey = GlobalKey();

  late int _cacheKey; // 原始源码会话内 hash(不等 strip)
  late double _aspect; // 根 <svg> 宽高比
  double? _naturalWidth; // 根 <svg> 声明的自然宽(逻辑 px),无则 null
  double? _naturalHeight; // 根 <svg> 声明的自然高(逻辑 px),无则 null
  bool _stretchContent = false; // preserveAspectRatio="none":内容随盒拉伸
  String? _strippedSource; // 剥除主动内容后的源码(懒计算,只在挂活体时付)
  String? _digest; // 内容摘要(磁盘寻址),懒计算

  ui.Image? _snapshot; // master 的 clone,本 State 所有
  bool _liveMounted = false; // 包活体已挂载(仅回退路径使用)
  bool _isPlaying = false;
  bool _pendingPlay = false; // 点击后等待挂活体的过渡帧(角标转圈)
  bool _electArmed = false; // 允许参与选举(驻留 300ms + 非快滚)
  bool _offscreenRunning = false; // 离屏首帧管线进行中
  bool _offscreenFailed = false; // 离屏失败,回退活体截帧路径
  Timer? _armTimer;
  bool _captureScheduled = false;
  int _captureRetries = 0;
  AnimatedSvgController? _controller;
  _BumpNotifier? _waitNotifier;

  // ---- 自持播放器(见"播放控制"注释) ----
  SvgDocument? _playerDoc;
  SvgTimeline? _playerTimeline;
  final _BumpNotifier _frameBump = _BumpNotifier();
  final Set<SvgNode> _hiddenByUs = <SvgNode>{};
  bool get _playerMounted => _playerDoc != null;

  /// 防注入后的源码;memoize,同一实例只剥一次。
  String get _safeSource =>
      _strippedSource ??= SvgUtils.stripActiveContent(widget.svgSource);

  @override
  void initState() {
    super.initState();
    _initSource();
  }

  void _initSource() {
    final src = widget.svgSource;
    _cacheKey = Object.hash(src.length, src.hashCode);
    final geo = _rootGeometryOf(src);
    _aspect = geo.aspect;
    // <img> 置换元素尺寸规则:缺失的一维由另一维 × 固有比例补出
    // (width="100%"+height="84"+viewBox → 固有宽 = 84×ratio = 680,
    // 浏览器就按 680×84 摆,左对齐;不是"撑满列宽")。
    _naturalWidth = geo.naturalW ??
        (geo.naturalH != null ? geo.naturalH! * geo.aspect : null);
    _naturalHeight = geo.naturalH ??
        (geo.naturalW != null ? geo.naturalW! / geo.aspect : null);
    _stretchContent = geo.stretch;
    if (widget.autoPlay) {
      // 查看器场景:直接起自持播放器,不走快照/选举
      _playing?._pause();
      _playing = this;
      _pendingPlay = true;
      unawaited(_mountPlayer());
      return;
    }
    final master = _SvgFirstFrameCache.peek(_cacheKey);
    if (master != null) {
      _snapshot = master.clone();
    } else {
      _listenForSnapshot();
      _scheduleArm(const Duration(milliseconds: 300));
      unawaited(_loadFromDiskFlow());
    }
  }

  /// 磁盘快照回灌:命中则免掉本会话对这张图的一切活体成本。
  Future<void> _loadFromDiskFlow() async {
    final key = _cacheKey;
    final digest = await _computeDigest();
    if (!mounted || key != _cacheKey) return;
    _digest = digest;
    final img = await _SvgFirstFrameCache.loadFromDisk(digest);
    if (img == null) return;
    if (!mounted || key != _cacheKey || _liveMounted || _snapshot != null) {
      img.dispose();
      return;
    }
    unawaited(_probeSnapshotVisible(key, img.clone()));
    // 入内存缓存(唤醒同 key 等待者,含本实例的 listener)
    _SvgFirstFrameCache.put(key, img);
  }

  /// 快照可见性探测:抽样扫 alpha,全透明 = 画面空白,不显示播放
  /// 角标(空白区悬浮的控件脱离画面语境,易被误解)。接管 [img] 所有权。
  Future<void> _probeSnapshotVisible(int key, ui.Image img) async {
    try {
      final data =
          await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      var visible = false;
      // 抽样步长:最多查 ~4096 个像素,alpha > 8 即视为有内容
      final pixelCount = bytes.length ~/ 4;
      final step = (pixelCount / 4096).ceil().clamp(1, 1 << 20);
      for (var i = 3; i < bytes.length; i += 4 * step) {
        if (bytes[i] > 8) {
          visible = true;
          break;
        }
      }
      _snapshotVisibleByKey[key] = visible;
      if (mounted && key == _cacheKey && !visible) {
        setState(() {}); // 已经出快照的实例收掉角标
      }
    } catch (_) {
      // 探测失败按可见处理(不误伤正常图)
    } finally {
      img.dispose();
    }
  }

  Future<String> _computeDigest() async {
    final src = widget.svgSource;
    if (_digest != null) return _digest!;
    return src.length > _bigSourceBytes
        ? await compute(_contentDigestTask, src)
        : _contentDigestTask(src);
  }

  /// 驻留满 [delay] 且列表不在惯性快滚时才启动首帧管线,
  /// 飞掠滚动的实例在窗口内就被回收,零成本。
  void _scheduleArm(Duration delay) {
    _armTimer?.cancel();
    _armTimer = Timer(delay, () {
      if (!mounted || _snapshot != null || _electArmed) return;
      if (Scrollable.recommendDeferredLoadingForContext(context)) {
        _scheduleArm(const Duration(milliseconds: 250));
        return;
      }
      // 当选者走离屏管线(UI isolate 只付一次录制);失败回退活体截帧
      if (_SvgFirstFrameCache.tryElect(_cacheKey, _token)) {
        unawaited(_runOffscreenPipeline());
      }
      setState(() => _electArmed = true);
    });
  }

  void _listenForSnapshot() {
    _waitNotifier ??= _SvgFirstFrameCache.notifierFor(_cacheKey)
      ..addListener(_onCacheBump);
  }

  void _onCacheBump() {
    if (!mounted || _liveMounted) return;
    final master = _SvgFirstFrameCache.peek(_cacheKey);
    if (master != null) {
      if (_snapshot == null) {
        setState(() => _snapshot = master.clone());
      }
    } else if (_electArmed &&
        !_offscreenRunning &&
        !_offscreenFailed &&
        _SvgFirstFrameCache.tryElect(_cacheKey, _token)) {
      // 前渲染者退选,本实例已过驻留窗口:接棒离屏管线
      unawaited(_runOffscreenPipeline());
    } else {
      // 渲染者退选 → 重建,让 build 里的回退选举接棒
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedSvgView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.svgSource, widget.svgSource) &&
        oldWidget.svgSource != widget.svgSource) {
      _teardownSource();
      _initSource();
    }
  }

  void _teardownSource() {
    _SvgFirstFrameCache.resign(_cacheKey, _token);
    _waitNotifier?.removeListener(_onCacheBump);
    _waitNotifier = null;
    _armTimer?.cancel();
    _armTimer = null;
    _stopPlaybackClock();
    _playClock.reset();
    _playerDoc = null;
    _playerTimeline = null;
    _hiddenByUs.clear();
    _snapshot?.dispose();
    _snapshot = null;
    _strippedSource = null;
    _digest = null;
    _controller = null;
    _liveMounted = false;
    _isPlaying = false;
    _pendingPlay = false;
    _electArmed = false;
    _captureScheduled = false;
    _captureRetries = 0;
  }

  @override
  void dispose() {
    if (_playing == this) _playing = null;
    _teardownSource();
    super.dispose();
  }

  /// 离屏首帧管线:重活(strip+parse+动画装配+seek0,实测 ~460ms)全在后台
  /// isolate;UI isolate 只付一次 Picture 录制(~60ms,避开快滚窗口);
  /// 光栅化(toImage)在引擎 raster 线程。失败则回退活体截帧路径。
  Future<void> _runOffscreenPipeline() async {
    if (_offscreenRunning) return;
    _offscreenRunning = true;
    final key = _cacheKey;
    try {
      final (doc, hasAnims) = await _parseFirstFrameInBg(widget.svgSource);
      if (!mounted || key != _cacheKey || _snapshot != null || _liveMounted) {
        return;
      }

      // 录制虽只有几十 ms,仍避开惯性快滚窗口
      var guard = 0;
      while (mounted &&
          guard++ < 8 &&
          Scrollable.recommendDeferredLoadingForContext(context)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (!mounted || key != _cacheKey || _snapshot != null || _liveMounted) {
        return;
      }

      final size = svgIntrinsicSize(doc);
      if (size.width <= 0 || size.height <= 0) {
        throw StateError('invalid intrinsic size');
      }
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final scale = dpr.clamp(1.0, 2048 / size.longestSide);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)..scale(scale);
      AnimatedSvgPainter(
        document: doc,
        hasAnimations: hasAnims,
        animationTime: 0.0,
      ).paint(canvas, size);
      final picture = recorder.endRecording();
      try {
        final master = await picture.toImage(
          (size.width * scale).round().clamp(1, 4096),
          (size.height * scale).round().clamp(1, 4096),
        );
        if (!mounted || key != _cacheKey) {
          master.dispose();
          return;
        }
        // put 会 bump notifier,本实例经 _onCacheBump clone 出 _snapshot
        unawaited(_probeSnapshotVisible(key, master.clone()));
        _SvgFirstFrameCache.put(key, master);
        unawaited(_persistSnapshot(master.clone()));
      } finally {
        picture.dispose();
      }
    } catch (_) {
      // 回退:挂活体冻结帧 + boundary 截图(旧路径)
      if (mounted && key == _cacheKey) {
        setState(() => _offscreenFailed = true);
      }
    } finally {
      _offscreenRunning = false;
    }
  }

  // ---- 首帧截图(离屏失败后的回退路径) ----

  void _scheduleCapture() {
    if (_captureScheduled) return;
    _captureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      unawaited(_capture());
    });
  }

  Future<void> _capture() async {
    if (!mounted || _snapshot != null) return;
    final boundary = _boundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    // debugNeedsPaint 只能在 assert 里读(release 下 getter 会炸)
    var needsPaint = false;
    assert(() {
      needsPaint = boundary?.debugNeedsPaint ?? true;
      return true;
    }());
    if (boundary == null || boundary.size.isEmpty || needsPaint) {
      if (_captureRetries++ < 5) _scheduleCapture();
      return;
    }
    try {
      // 限制快照长边 ≤2048px,防超大签名图撑爆纹理内存
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final longest =
          boundary.size.longestSide <= 0 ? 1.0 : boundary.size.longestSide;
      final ratio = dpr.clamp(1.0, 2048 / longest);
      final master = await boundary.toImage(pixelRatio: ratio.toDouble());
      if (!mounted) {
        master.dispose();
        return;
      }
      unawaited(_probeSnapshotVisible(_cacheKey, master.clone()));
      _SvgFirstFrameCache.put(_cacheKey, master);
      unawaited(_persistSnapshot(master.clone()));
      if (!_liveMounted) {
        // 冻结选举者:换成快照位图,卸掉活体(释放解析产物)
        setState(() => _snapshot = master.clone());
      } else {
        _snapshot = master.clone();
      }
    } catch (_) {
      // 截帧失败保持活体冻结显示,不影响正确性
    }
  }

  Future<void> _persistSnapshot(ui.Image img) async {
    final String digest;
    try {
      digest = _digest ??= await _computeDigest();
    } catch (_) {
      img.dispose();
      return;
    }
    await _SvgFirstFrameCache.saveToDisk(digest, img);
  }

  // ---- 播放控制 ----
  //
  // 完全绕开包的播放 widget。两个理由(都实测踩过):
  // ① 包 autoPlay 用 vsync 满帧率每帧 setState+全量重录制;即便改成外部
  //   低频 seek,一次重绘仍要重录整棵树 —— 极端图(上百 text 层)单次
  //   录制几十 ms,15fps 也是每 66ms 一记大 build,滚动照样不跟手。
  // ② 上游 text 级 opacity 缺陷:轮播层在活体里全叠着画,录制成本被
  //   隐藏层放大 N 倍(126 层全录,实际只该录 1~2 层)。
  //
  // 自持播放器:直接持有后台 isolate 传回的 SvgDocument + SvgTimeline,
  // 低频 Timer tick 里 seek(elapsed) 后**按有效 opacity 把隐藏层标
  // display:none**(painter 树遍历对 display:none 短路,压根不进录制)
  // —— 单帧录制成本从"全部层"降到"可见层"(轮播图 = 1~2 层),
  // 且修掉了播放中的串层。重绘经 repaint listenable 直达 CustomPaint,
  // 不走 setState/build。滚动中跳过 tick,动画冻结零成本。
  //
  // 包活体(_buildLive)仅保留给离屏管线失败的回退路径。

  static const int _playbackFps = 15;

  Timer? _playTimer;
  final Stopwatch _playClock = Stopwatch();

  void _startPlaybackClock() {
    _playTimer?.cancel();
    _playTimer = Timer.periodic(
      Duration(milliseconds: (1000 / _playbackFps).round()),
      (_) {
        if (!mounted || !_isPlaying) return;
        // 滚动中让路:不 seek 不重绘,手势帧零竞争
        if (Scrollable.recommendDeferredLoadingForContext(context)) return;
        _tickPlayer();
      },
    );
    _playClock.start();
  }

  void _stopPlaybackClock() {
    _playTimer?.cancel();
    _playTimer = null;
    _playClock.stop();
  }

  void _tickPlayer() {
    final timeline = _playerTimeline;
    final doc = _playerDoc;
    if (timeline == null || doc == null) {
      // 回退路径(包活体):经 controller.seek 驱动
      _controller?.seek(_playClock.elapsed);
      return;
    }
    timeline.seek(_playClock.elapsed);
    _syncHiddenLayers(doc.root);
    _unwrapCssPathValues(doc.root); // CSS d:path("...") 帧值解包(上游缺陷)
    _frameBump.bump(); // 直达 CustomPaint.repaint,不走 build
  }

  /// 按 seek 后的有效 opacity 同步 display:none 标记:
  /// painter 对 display:none 整棵短路,隐藏层零录制成本;
  /// 只动我们自己标过的节点,不碰文档原生 display。
  void _syncHiddenLayers(SvgNode node) {
    for (final c in node.children) {
      final v = c.getAttributeValue('opacity');
      final d = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
      final shouldHide = d != null && d <= 0.01;
      final hiddenNow = _hiddenByUs.contains(c);
      if (shouldHide && !hiddenNow) {
        c.setAttribute('display', 'none', rawValue: 'none');
        _hiddenByUs.add(c);
      } else if (!shouldHide && hiddenNow) {
        c.setAttribute('display', 'inline', rawValue: 'inline');
        _hiddenByUs.remove(c);
      }
      _syncHiddenLayers(c);
    }
  }

  /// 启动自持播放器:复用离屏管线同款后台 parse(不剪层,播放需要全部
  /// 层随时间轴显隐),UI isolate 只挂一个 CustomPaint。
  Future<void> _mountPlayer() async {
    final key = _cacheKey;
    final (doc, anims) = await _parseFirstFrameInBgForPlayback(
      widget.svgSource,
    );
    if (!mounted || key != _cacheKey) return;
    if (anims.isEmpty) {
      // 无可播放时间轴:保持快照态
      setState(() {
        _pendingPlay = false;
        _isPlaying = false;
      });
      return;
    }
    _playerDoc = doc;
    _playerTimeline = SvgTimeline(animations: anims, rootNode: doc.root);
    _playerTimeline!.seek(Duration.zero);
    _syncHiddenLayers(doc.root);
    setState(() {
      _pendingPlay = false;
      _isPlaying = true;
    });
    _startPlaybackClock();
  }

  Future<void> _togglePlay() async {
    if (_pendingPlay) return;
    if (_isPlaying) {
      _pause();
      return;
    }
    // 抢占:暂停上一个在播实例
    if (_playing != null && _playing != this) {
      _playing!._pause();
    }
    _playing = this;

    if (_playerMounted || _liveMounted) {
      // 播放器/回退活体还在(此前暂停过):秒回,零解析
      setState(() => _isPlaying = true);
      _startPlaybackClock();
      return;
    }

    // 首次播放:先出反馈帧(角标转圈),后台 parse 完成后起播
    setState(() => _pendingPlay = true);
    unawaited(_mountPlayer());
  }

  void _pause() {
    if (!_isPlaying) return;
    _stopPlaybackClock();
    if (_playing == this) _playing = null;
    if (mounted) {
      setState(() => _isPlaying = false);
    } else {
      _isPlaying = false;
    }
  }

  // ---- build ----

  /// 活体(full_svg_flutter)子树:冻结选举 / 播放 / 暂停共用同一形状,
  /// 活体(full_svg_flutter)子树:冻结选举 / 播放 / 暂停共用同一形状。
  ///
  /// autoPlay 恒 false:播放由外部低频时钟经 controller.seek 驱动
  /// (见"播放控制"),包内部不建 vsync AnimationController——满帧率
  /// 每帧全量重录制是滚动不跟手的元凶。seek 应用时间轴后只重绘一次。
  ///
  /// fit: contain + alignment: center 是包内**跳过 FittedBox** 的唯一
  /// 组合:CustomPaint 直接吃盒子尺寸,painter 按文档自己的
  /// preserveAspectRatio 做 viewBox→盒子映射(默认 xMidYMid meet 等比
  /// 居中、"none" 拉伸),与浏览器同源。传其他 fit 会走 FittedBox+
  /// intrinsic 分支:定高撑宽的卡片签名曾被 fill 水平拉爆(翻过车)。
  ///
  /// ClipRect:浏览器根 `<svg>` 默认 overflow:hidden,而 CustomPaint
  /// 不裁剪——SMIL 位移动画(飘雪/流光)会画出画面溢进帖子内容。
  /// 包的 clipToViewBox 只在有 viewBox 时生效,widget 级 ClipRect
  /// 对无 viewBox 的图(纯 width/height 徽章)也兜得住;快照路径是
  /// 位图天然不溢,离屏截帧 toImage(w,h) 也天然裁剪,只有活体需要。
  Widget _buildLive() {
    return RepaintBoundary(
      key: _boundaryKey,
      child: ClipRect(
        child: AnimatedSvgPicture.string(
          _safeSource,
          fit: BoxFit.contain,
          alignment: Alignment.center,
          autoPlay: false,
          controller: _controller,
          clipToViewBox: true,
        ),
      ),
    );
  }

  /// 自持播放器子树:直接用包 painter 画自己驱动的 SvgDocument,
  /// 重绘由 repaint listenable 触发(不 setState、不重建 widget 树)。
  Widget _buildPlayer() {
    return RepaintBoundary(
      child: ClipRect(
        child: CustomPaint(
          painter: _SelfDrivenSvgPainter(
            document: _playerDoc!,
            repaint: _frameBump,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget body;
    var showBadge = true;

    if (_playerMounted) {
      // 自持播放器(播放/暂停均常驻,重绘不走 build)
      body = _buildPlayer();
    } else if (_liveMounted) {
      // 回退路径的包活体
      body = _buildLive();
    } else if (_snapshot != null) {
      // 快照冻结态:纯位图,零解析零重绘成本。映射对齐活体 painter:
      // 默认 contain(preserveAspectRatio 缺省 = xMidYMid meet,
      // 盒比≠图比时等比居中留空),声明 "none" 才 fill 拉伸。
      body = RawImage(
        image: _snapshot,
        fit: _stretchContent ? BoxFit.fill : BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
      // 快照全透明(画面空白)时不显示播放角标
      if (_snapshotVisibleByKey[_cacheKey] == false) showBadge = false;
    } else if (_electArmed &&
        _offscreenFailed &&
        _SvgFirstFrameCache.tryElect(_cacheKey, _token)) {
      // 离屏管线失败的回退:挂活体冻结帧,下一帧 boundary 截图入缓存
      _scheduleCapture();
      body = _buildLive();
    } else {
      // 离屏管线进行中 / 等待他人快照 / 未到驻留窗口:轻占位
      showBadge = false;
      body = DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.3,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }

    // 盒子几何 = 浏览器 <img> 置换元素语义:固有尺寸(缺维由比例补出)
    // + max-width:100% —— 列宽富余时按固有宽摆(随外层 Align 左对齐),
    // 列窄时等比缩,绝不放大。仅 viewBox 无固有尺寸的图撑满可用宽。
    // Stack 精确包住画面,角标钉在画面右下角。
    final content = Stack(
      children: [
        Positioned.fill(child: body),
        if (showBadge) Positioned(right: 8, bottom: 8, child: _buildBadge()),
      ],
    );
    Widget framed = AspectRatio(
      // 盒子比例:双数字声明时按属性对(可与 viewBox 比不同,内容层
      // 由 preserveAspectRatio 兜);否则用 viewBox 比。
      aspectRatio: (_naturalWidth != null && _naturalHeight != null)
          ? _naturalWidth! / _naturalHeight!
          : _aspect,
      child: content,
    );
    if (_naturalWidth != null) {
      framed = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _naturalWidth!),
        child: framed,
      );
    }
    // heightFactor: 1.0 —— 垂直收缩到画面本身:父级给有界高(如签名的
    // max-height)时,Align 默认撑满全高、画面垂直居中,上下各悬一截
    // 空白(翻过车);水平仍展开以支持 centerLeft/center 对齐。
    framed = Align(
      alignment: widget.alignment,
      heightFactor: 1.0,
      child: framed,
    );

    return VisibilityDetector(
      key: ValueKey('animated-svg-$hashCode'),
      onVisibilityChanged: (info) {
        // 滚出视口过半即暂停,回收 CPU
        if (_isPlaying && info.visibleFraction < 0.5) {
          _pause();
        }
      },
      child: framed,
    );
  }

  Widget _buildBadge() {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _togglePlay,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: _pendingPlay
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    _isPlaying
                        ? Symbols.pause_rounded
                        : Symbols.play_arrow_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
          ),
        ),
      ),
    );
  }

  // ---- 根标签几何提取(只看根 <svg> 的属性,内层 viewBox 不参与) ----

  static final RegExp _rootSvgTagRe = RegExp(r'<svg\b[^>]*>');
  static final RegExp _attrViewBoxRe = RegExp(
    r'viewBox\s*=\s*"[\d.eE+-]+[\s,]+[\d.eE+-]+[\s,]+([\d.eE+-]+)[\s,]+([\d.eE+-]+)"',
  );
  static final RegExp _attrWidthRe =
      RegExp(r'\swidth\s*=\s*"([\d.]+)(?:px)?\s*"');
  static final RegExp _attrHeightRe =
      RegExp(r'\sheight\s*=\s*"([\d.]+)(?:px)?\s*"');
  static final RegExp _parNoneRe =
      RegExp(r'preserveAspectRatio\s*=\s*"\s*none\s*"');

  /// 浏览器语义的自然尺寸:width/height 只认**纯数字**属性
  /// (`width="100%"` 等相对值不算自然尺寸,匹配不中即 null)。
  /// 比例优先 viewBox,回退 width/height 数字对。
  /// [stretch] = 根标签声明 preserveAspectRatio="none"(内容随盒拉伸)。
  ///
  /// 关键场景:`viewBox + width="100%" + height="84"` —— 浏览器按
  /// "宽度撑满、高度锁 84" 定**视口**;视口内的内容仍按
  /// preserveAspectRatio 等比映射(不拉伸),两层语义要分开。
  static ({double aspect, double? naturalW, double? naturalH, bool stretch})
      _rootGeometryOf(String src) {
    final tag = _rootSvgTagRe.firstMatch(src)?.group(0);
    if (tag == null) {
      return (aspect: 16 / 9, naturalW: null, naturalH: null, stretch: false);
    }

    final w = double.tryParse(_attrWidthRe.firstMatch(tag)?.group(1) ?? '');
    final h = double.tryParse(_attrHeightRe.firstMatch(tag)?.group(1) ?? '');
    final naturalW = (w != null && w > 0) ? w : null;
    final naturalH = (h != null && h > 0) ? h : null;

    double aspect = 16 / 9;
    final vb = _attrViewBoxRe.firstMatch(tag);
    if (vb != null) {
      final vw = double.tryParse(vb.group(1)!);
      final vh = double.tryParse(vb.group(2)!);
      if (vw != null && vh != null && vw > 0 && vh > 0) aspect = vw / vh;
    } else if (naturalW != null && naturalH != null) {
      aspect = naturalW / naturalH;
    }
    return (
      aspect: aspect,
      naturalW: naturalW,
      naturalH: naturalH,
      stretch: _parNoneRe.hasMatch(tag),
    );
  }
}

/// 内容摘要(双基 FNV-1a 32 → 16 hex):磁盘快照寻址用。
/// 顶层函数以便 compute() 派发大字符串;'v1' 为快照格式版本盐,
/// 截帧/剥离逻辑变更时递增使旧盘缓存自然失效。
String _contentDigestTask(String s) {
  const salt = 0x76322e; // 'v2.'(v1→v2:采样时刻改周期中点+path()解包,旧盘快照失效)
  var h1 = 0x811c9dc5 ^ salt;
  var h2 = 0x01935c1f ^ salt;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF;
    h2 = ((h2 ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return '${h1.toRadixString(16).padLeft(8, '0')}'
      '${h2.toRadixString(16).padLeft(8, '0')}'
      '-${s.length}';
}

/// 后台 isolate 的首帧准备:防注入剥离 + parse + theme + 动画装配 + seek(0)。
/// 只碰纯 Dart 结构,不碰 dart:ui(SvgDocument 可跨 isolate 传输,已实测)。
(SvgDocument, bool) _parseFirstFrameTask(String rawSource) {
  final safe = SvgUtils.stripActiveContent(rawSource);
  final doc = SvgParser.parse(safe);
  applySvgTheme(doc);
  final anims = SmilParser.parseAnimations(doc);
  if (anims.isNotEmpty) {
    // seek 到能代表画面的时刻(手写体 path 动画 t=0 是空白起笔,
    // 取周期中点让首帧有内容;非周期/未知时长回退 0)
    SvgTimeline(animations: anims, rootNode: doc.root)
        .seek(_representativeTime(anims));
    _pruneInvisible(doc.root);
    _unwrapCssPathValues(doc.root);
  }
  return (doc, anims.isNotEmpty);
}

/// 选取首帧快照的采样时刻:所有动画共同短周期的中点。
/// 轮播类(互斥 opacity)在任意时刻都只亮一层,中点无损;
/// 手写类(d:path 逐帧)中点=写到一半,比 t=0 的空白有信息量。
Duration _representativeTime(List<SmilAnimation> anims) {
  Duration shortest = Duration.zero;
  for (final a in anims) {
    if (a.dur > Duration.zero && (shortest == Duration.zero || a.dur < shortest)) {
      shortest = a.dur;
    }
  }
  return shortest == Duration.zero
      ? Duration.zero
      : Duration(microseconds: shortest.inMicroseconds ~/ 2);
}

final RegExp _cssPathFnRe =
    RegExp(r'''^path\(\s*["']([\s\S]*)["']\s*\)$''');

/// 解包 CSS `d: path("...")` 动画值(上游缺陷):
/// CSS @keyframes 对 d 属性的动画帧值是 `path("M ...")` 函数包装,
/// timeline seek 后原样写回 DOM,包 painter 的路径解析不认该前缀
/// → 整条 path 静默不画(手写签名类 SVG 整图空白)。seek 后把
/// 包装拆掉还原为裸 path data。
void _unwrapCssPathValues(SvgNode node) {
  final attr = node.getAttribute('d');
  final v = attr?.effectiveValue;
  if (v is String) {
    final m = _cssPathFnRe.firstMatch(v.trim());
    if (m != null) attr!.setAnimatedValue(m.group(1)!);
  }
  for (final c in node.children) {
    _unwrapCssPathValues(c);
  }
}

/// 剪除 seek(0) 后有效 opacity≈0 的节点。
///
/// 上游 painter 缺陷:`<text>` 的元素级 opacity 不作用于其 tspan 子树
/// (opacity 是非继承属性,规范要求按组合成处理;包对 `<g>` 有 saveLayer
/// 组合成,text 漏了)。轮播歌词类 SVG 用上百个互斥 opacity 层做逐句
/// 切换,首帧会全层实心叠加糊成一团。时间轴求值本身正确(已实测
/// dump:opacity 值全部正确写回 DOM),所以按值物理剪除与浏览器 t=0
/// 画面等价(探针对照验证)。只影响首帧快照;点击播放走全量活体解析,
/// 层结构完整。
void _pruneInvisible(SvgNode node) {
  node.children.removeWhere((c) {
    final v = c.getAttributeValue('opacity');
    final d = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
    return d != null && d <= 0.01;
  });
  for (final c in node.children) {
    _pruneInvisible(c);
  }
}

/// 顶层派发器:闭包只捕获 String(async 上下文里创建的闭包会连带
/// _AsyncCompleter 被拒收,已实测踩坑)。
Future<(SvgDocument, bool)> _parseFirstFrameInBg(String source) =>
    Isolate.run<(SvgDocument, bool)>(() => _parseFirstFrameTask(source));

/// 播放用后台 parse:与首帧任务同构但**不剪层**(播放需要全部层随
/// 时间轴显隐,隐藏交给 _syncHiddenLayers 的 display:none 标记)。
/// animations 随文档一起传回(isolate 拷贝保持对象图,动画里的
/// targetNode 引用与文档节点是同一批拷贝),UI isolate 零重解析。
(SvgDocument, List<SmilAnimation>) _parsePlaybackTask(String rawSource) {
  final safe = SvgUtils.stripActiveContent(rawSource);
  final doc = SvgParser.parse(safe);
  applySvgTheme(doc);
  final anims = SmilParser.parseAnimations(doc);
  return (doc, anims);
}

Future<(SvgDocument, List<SmilAnimation>)> _parseFirstFrameInBgForPlayback(
        String source) =>
    Isolate.run<(SvgDocument, List<SmilAnimation>)>(
        () => _parsePlaybackTask(source));

/// 自持播放器的 painter:包装包的 AnimatedSvgPainter,重绘由外部
/// repaint listenable(每 tick bump)驱动 —— 播放帧不经过 setState/
/// build/element 更新,只走 paint。
class _SelfDrivenSvgPainter extends CustomPainter {
  _SelfDrivenSvgPainter({required this.document, required Listenable repaint})
      : super(repaint: repaint);

  final SvgDocument document;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    AnimatedSvgPainter(
      document: document,
      hasAnimations: true,
      animationTime: 0.0,
      clipToViewBox: true,
    ).paint(canvas, size);
  }

  @override
  bool shouldRepaint(_SelfDrivenSvgPainter oldDelegate) =>
      !identical(oldDelegate.document, document);
}
