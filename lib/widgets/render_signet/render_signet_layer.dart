import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/core_providers.dart';
import 'native_signet_overlay.dart';
import 'render_signet_codec.dart';

/// 全局渲染帧标识印记层。
///
/// 挂在 MaterialApp.builder 的 Stack 顶层,把当前会话标识编码成肉眼
/// 不可见的差分点阵平铺全屏。无损帧捕获为像素级拷贝,点阵随之保留,
/// 可用 tools/render-signet/extract.py 离线还原标识做归属核验。
///
/// 渲染后端按平台分派:
/// - macOS / iOS:下沉为窗口级原生 CALayer([NativeSignetOverlay])。
///   Flutter 层的全屏绘制会把平台视图(WKWebView)头顶的整个区域计入
///   引擎的原生命中测试忽略区,macOS 上又没有手势转发兜底,表现为
///   可见 WebView 整块点不动;原生兄弟视图不参与该统计,从根上消除
///   互斥,且能把印记盖到 WebView 自身的像素上。
/// - 其余平台:Flutter 内联绘制,「消饱和 + 单极性点阵」两笔,全部为
///   Porter-Duff 系数混合(固定管线,不依赖 framebuffer fetch,任何
///   GPU 上都无离屏回退):
///   1. 消饱和笔:全屏 srcATop 纯色 (0,0,0)@α=δ,把所有色通道均匀乘
///      (255-δ)/255——纯白像素降到 255-δ,全屏不再存在饱和像素。
///      均匀无对比的 0.4% 变化低于面板校准差异,物理不可见;
///   2. 信号笔:点阵图块(预乘 (0,0,δ,δ))配 plus。因已无饱和,
///      +δ 处处满效——含旧双极性方案信号过零的中灰死区,SNR 更优。
///
///   历史:曾用 modulate(不透明白底图块)+plus 双极性分解,个别
///   Android 驱动在混合首用帧把白底图块按 srcOver 原样画出=整屏白
///   (2026-07 白屏案);随后的 exclusion 单笔修掉了白屏,但它是
///   advanced blend,在 Adreno≤630/PowerVR 等无 framebuffer fetch 的
///   GPU 上走 Impeller 离屏回退(每帧全屏拷贝),低端机滚动付税。
///   现方案两个问题同时消灭:全部失败形态结构性不可见(消饱和笔
///   退化成 srcOver 时公式 out = 0 + d·(1-δ/255) 与正常效果完全相同;
///   信号笔退化 = α≈1/255 微染色),且全 GPU 走固定管线混合。
///
/// [RenderSignetLayer.inline] 强制内联绘制,供离屏 RepaintBoundary
/// 截图场景(分享图)使用——窗口级原生层盖不进离屏合成产物。
///
/// 编码结构与混合原理见 [render_signet_codec.dart] 库注释。
/// 无会话标识时不渲染任何内容。
class RenderSignetLayer extends ConsumerStatefulWidget {
  const RenderSignetLayer({super.key}) : inline = false;

  /// 离屏截图场景专用:跳过平台分派,始终 Flutter 内联绘制。
  const RenderSignetLayer.inline({super.key}) : inline = true;

  final bool inline;

  /// 窗口级原生后端平台。
  /// - macOS/iOS:动机是平台视图命中测试互斥(全屏 Flutter 绘制会让
  ///   WKWebView 整块收不到鼠标事件),CALayer 混合下沉。
  /// - Windows:动机是性能——Skia+ANGLE 无 partial repaint,内联两笔
  ///   全屏 dst-read 混合每帧全额支付(4K≈132MB/帧),核显+高刷实测
  ///   卡顿(用户 A/B 实锤);下沉 Windows.UI.Composition 后每帧成本
  ///   转嫁 DWM 合成端,增量接近零。
  /// - Android:HC 平台视图有触摸转发、引擎有 partial repaint,两个
  ///   动机都不存在,维持内联;Linux 用户基数小,有反馈再说。
  static bool get usesNativeOverlay =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  ConsumerState<RenderSignetLayer> createState() => _RenderSignetLayerState();
}

class _RenderSignetLayerState extends ConsumerState<RenderSignetLayer> {
  ui.Image? _tile;
  int? _tileId;
  double? _tileDpr;

  @override
  void dispose() {
    _tile?.dispose();
    super.dispose();
  }

  void _clearTiles() {
    _tile?.dispose();
    _tile = null;
    _tileId = null;
    _tileDpr = null;
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅标识:currentUser 其他字段(头像/未读数等)刷新不应重建
    final id = ref.watch(
      currentUserProvider.select((value) => value.value?.id),
    );

    if (!widget.inline && RenderSignetLayer.usesNativeOverlay) {
      _clearTiles();
      NativeSignetOverlay.instance.sync(
        id: id,
        dpr: MediaQuery.devicePixelRatioOf(context),
      );
      return const SizedBox.shrink();
    }

    if (id == null) {
      _clearTiles();
      return const SizedBox.shrink();
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_tile == null || _tileId != id || _tileDpr != dpr) {
      _clearTiles();
      _tile = buildSignetSignalTile(id, dpr);
      _tileId = id;
      _tileDpr = dpr;
    }

    // 两笔的 dst 依赖语义(srcATop/plus)要求指令直接落在 app 内容
    // 之上的同一渲染目标里,任何形式的离屏烘焙都会把混合底换成
    // 透明黑,信号丢失(残余 δ 量级,不可见)。两道防线:不包
    // RepaintBoundary(防图层级 raster cache),willChange: true
    // (防 Skia picture 级 raster cache;Impeller 无 raster cache)
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        willChange: true,
        painter: RenderSignetPainter(tile: _tile!),
      ),
    );
  }
}

/// 把一个印记块(kSignetBlockPeriod 见方)按 dpr 栅格成一张信号笔
/// 图块:透明底,点位为预乘 (0,0,δ,δ)(直通色 (0,0,255)@α=δ)。
/// 关闭抗锯齿 + 整数几何,保证点边缘落在整物理像素上,解码端才能按
/// 同款网格精确采样。
///
/// 与消饱和笔(painter 内联的全屏 srcATop)配合:
///   1. srcATop (0,0,0)@α=δ → 全通道乘 (255-δ)/255,饱和消失;
///   2. 本图块 plus → 点位 B 恒 +δ(无 clamp,处处满效)。
/// 单极性信号,解码端以位置差分(左位-右位)提取,极性权重恒 1。
///
/// 结构安全性(2026-07 Android 白屏案后的硬要求):本方案所有构件
/// 中不存在不透明亮色底图,任何混合失败形态(srcOver 退化/被跳过/
/// 离屏烘焙)的视觉残余都在 δ≈1/255 量级——结构上无可见坏帧;且
/// 两笔均为 Porter-Duff 系数混合,任何 GPU 走固定管线,无性能分层。
ui.Image buildSignetSignalTile(int id, double dpr) {
  final bits = encodeSignetBits(id);
  final tilePx = (kSignetBlockPeriod * dpr).round().clamp(1, 1 << 12);
  final scale = tilePx / kSignetBlockPeriod;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale.toDouble());
  final dot = Paint()
    ..color = const Color.fromARGB(kSignetPlusDelta, 0, 0, 255)
    ..isAntiAlias = false;
  for (var row = 0; row < kSignetGridRows; row++) {
    for (var col = 0; col < kSignetGridCols; col++) {
      final bit = bits[row * kSignetGridCols + col];
      final x = col * kSignetCellSize;
      // y 逐格打散消除条纹感,见 signetDotYOffset 注释
      final y = row * kSignetCellSize + signetDotYOffset(row, col);
      // 位置编码:bit=1 点画在左位,bit=0 画在右位
      canvas.drawRect(
        Rect.fromLTWH(
          x + (bit ? kSignetDotLeftX : kSignetDotRightX),
          y.toDouble(),
          kSignetDotW,
          kSignetDotH,
        ),
        dot,
      );
    }
  }
  final picture = recorder.endRecording();
  final image = picture.toImageSync(tilePx, tilePx);
  picture.dispose();
  return image;
}

/// 把一个印记块(kSignetBlockPeriod 见方)按 dpr 栅格成两张物理像素
/// 图块(modulate 笔白底 / plus 笔透明底)。关闭抗锯齿 + 整数几何,
/// 保证点边缘落在整物理像素上,解码端才能按同款网格精确采样。
/// 公开供混合语义像素回读测试使用。
///
/// [opaquePlusPen] 供原生 CA 混合后端使用:CA 的 linearDodge 是
/// 「先按混合方程算色、再按 α source-over 合成」,α=δ 的半透明点会把
/// +δ 语义稀释成 B·(1-δ/255)+δ,白底净效应从 -δ 漂成 -2δ。改成
/// α=255、色值 (0,0,δ) 的不透明点,linearDodge 直接得 B+δ,与
/// Flutter plus 笔在不透明底上的语义严格一致。透明底格子仍 α=0,
/// 不影响非点位像素。(Flutter 内联后端不能用它:plus 混合会把
/// α=255 也加进目标 α,平台视图挖孔处会盖出实心点——见默认笔注释)
(ui.Image, ui.Image) buildSignetTiles(
  int id,
  double dpr, {
  bool opaquePlusPen = false,
}) {
  final bits = encodeSignetBits(id);
  final tilePx = (kSignetBlockPeriod * dpr).round().clamp(1, 1 << 12);
  final scale = tilePx / kSignetBlockPeriod;

  ui.Image raster(Color? background, Color dotColor) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale.toDouble());
    if (background != null) {
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, kSignetBlockPeriod, kSignetBlockPeriod),
        Paint()
          ..color = background
          ..isAntiAlias = false,
      );
    }
    final dot = Paint()
      ..color = dotColor
      ..isAntiAlias = false;
    for (var row = 0; row < kSignetGridRows; row++) {
      for (var col = 0; col < kSignetGridCols; col++) {
        final bit = bits[row * kSignetGridCols + col];
        final x = col * kSignetCellSize;
        // y 逐格打散消除条纹感,见 signetDotYOffset 注释
        final y = row * kSignetCellSize + signetDotYOffset(row, col);
        // 位置编码:bit=1 点画在左位,bit=0 画在右位
        canvas.drawRect(
          Rect.fromLTWH(
            x + (bit ? kSignetDotLeftX : kSignetDotRightX),
            y.toDouble(),
            kSignetDotW,
            kSignetDotH,
          ),
          dot,
        );
      }
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(tilePx, tilePx);
    picture.dispose();
    return image;
  }

  // modulate 笔:白底(乘 1 不改画面),点位 B 乘性压降——白底满效,
  // 黑底无效
  final mod = raster(
    const Color(0xFFFFFFFF),
    Color.fromARGB(255, 255, 255, 255 - kSignetModulateDrop),
  );
  // plus 笔:透明底(加 0 不改画面),点位 B 加性抬升——黑底满效,
  // 白底饱和自动熄火。α 取 delta 而非 255:预乘后恰为 (0,0,δ,δ),
  // 叠在平台视图挖孔等透明区上仍近乎全透明,不会盖出实心点
  final plus = raster(
    null,
    opaquePlusPen
        ? const Color.fromARGB(255, 0, 0, kSignetPlusDelta)
        : const Color.fromARGB(kSignetPlusDelta, 0, 0, 255),
  );
  return (mod, plus);
}

class RenderSignetPainter extends CustomPainter {
  RenderSignetPainter({required this.tile});

  /// 信号笔图块([buildSignetSignalTile])
  final ui.Image tile;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 笔 1 消饱和:srcATop (0,0,0)@α=δ → 全通道乘 (255-δ)/255。
    // 必须先于信号笔:消除 B=255 饱和,plus 的 +δ 才处处满效。
    // 该笔退化成 srcOver 时输出与正常完全相同(0 + d·(1-δ/255)),
    // 连失败形态都不存在
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color.fromARGB(kSignetPlusDelta, 0, 0, 0)
        ..blendMode = BlendMode.srcATop,
    );
    // 笔 2 信号:点阵 plus,B 恒 +δ,单极性
    _drawTiled(canvas, rect, tile, BlendMode.plus);
  }

  void _drawTiled(Canvas canvas, Rect rect, ui.Image tile, BlendMode mode) {
    // 图块物理 px → 逻辑 px:平铺周期精确回到 kSignetBlockPeriod
    final scale = kSignetBlockPeriod / tile.width;
    final shader = ui.ImageShader(
      tile,
      TileMode.repeated,
      TileMode.repeated,
      (Matrix4.identity()..scaleByDouble(scale, scale, 1, 1)).storage,
      filterQuality: FilterQuality.none,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = shader
        ..blendMode = mode,
    );
  }

  @override
  bool shouldRepaint(RenderSignetPainter oldDelegate) =>
      oldDelegate.tile != tile;
}
