import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/core_providers.dart';
import 'render_signet_codec.dart';

/// 全局渲染帧标识印记层。
///
/// 挂在 MaterialApp.builder 的 Stack 顶层,把当前会话标识编码成肉眼
/// 不可见的差分点阵平铺全屏。无损帧捕获为像素级拷贝,点阵随之保留,
/// 可用 tools/render-signet/extract.py 离线还原标识做归属核验。
///
/// 渲染方式:把单个印记块按设备像素比栅格成两张 ui.Image(modulate
/// 笔/plus 笔),各用 ImageShader(TileMode.repeated)一次 drawRect
/// 覆盖全屏——每帧只有两条绘制指令。两笔混合让扰动极性逐像素跟随
/// 底色自适应(暗底 +ΔB/浅底 -ΔB),同屏明暗混排也全域不可见且
/// 信号完整,无需任何主题/底色判断。两种混合模式在 Skia/Impeller
/// 均为系数混合,不触发离屏 pass。
///
/// 编码结构与混合原理见 [render_signet_codec.dart] 库注释。
/// 无会话标识时不渲染任何内容。
class RenderSignetLayer extends ConsumerStatefulWidget {
  const RenderSignetLayer({super.key});

  @override
  ConsumerState<RenderSignetLayer> createState() => _RenderSignetLayerState();
}

class _RenderSignetLayerState extends ConsumerState<RenderSignetLayer> {
  ui.Image? _modTile;
  ui.Image? _plusTile;
  int? _tileId;
  double? _tileDpr;

  @override
  void dispose() {
    _modTile?.dispose();
    _plusTile?.dispose();
    super.dispose();
  }

  void _clearTiles() {
    _modTile?.dispose();
    _plusTile?.dispose();
    _modTile = null;
    _plusTile = null;
    _tileId = null;
    _tileDpr = null;
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅标识:currentUser 其他字段(头像/未读数等)刷新不应重建
    final id = ref.watch(
      currentUserProvider.select((value) => value.value?.id),
    );
    if (id == null) {
      _clearTiles();
      return const SizedBox.shrink();
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_modTile == null || _tileId != id || _tileDpr != dpr) {
      _clearTiles();
      final (mod, plus) = buildSignetTiles(id, dpr);
      _modTile = mod;
      _plusTile = plus;
      _tileId = id;
      _tileDpr = dpr;
    }

    // 混合笔的 dst 依赖语义(modulate/plus)要求两条指令直接落在 app
    // 内容之上的同一渲染目标里,任何形式的离屏烘焙都会把混合底换成
    // 透明黑——modulate 整笔蒸发、plus 退化为 srcOver 蓝点,在浅底
    // 显出 13 倍于设计信号的亮度脏纹(像素法证:R/G 各降 1)。
    // 两道防线:不包 RepaintBoundary(防图层级 raster cache),
    // willChange: true(防 Skia picture 级 raster cache 把静态两指令
    // picture 烘成纹理;Impeller 无 raster cache 不受影响)
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        willChange: true,
        painter: RenderSignetPainter(
          modTile: _modTile!,
          plusTile: _plusTile!,
        ),
      ),
    );
  }
}

/// 把一个印记块(kSignetBlockPeriod 见方)按 dpr 栅格成两张物理像素
/// 图块(modulate 笔白底 / plus 笔透明底)。关闭抗锯齿 + 整数几何,
/// 保证点边缘落在整物理像素上,解码端才能按同款网格精确采样。
/// 公开供混合语义像素回读测试使用。
(ui.Image, ui.Image) buildSignetTiles(int id, double dpr) {
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
    const Color.fromARGB(kSignetPlusDelta, 0, 0, 255),
  );
  return (mod, plus);
}

class RenderSignetPainter extends CustomPainter {
  RenderSignetPainter({required this.modTile, required this.plusTile});

  final ui.Image modTile;
  final ui.Image plusTile;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 必须先 modulate 后 plus:合成值域 [δ, 255-δ] 不触 clamp,黑白底
    // 信号严格对称;反序会在白底被截断。原理见 codec 库注释
    _drawTiled(canvas, rect, modTile, BlendMode.modulate);
    _drawTiled(canvas, rect, plusTile, BlendMode.plus);
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
      oldDelegate.modTile != modTile || oldDelegate.plusTile != plusTile;
}
