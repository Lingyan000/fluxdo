// 玻璃的背景截取：每帧在根部统一截一次玻璃背后的内容，缩小后模糊，
// 所有玻璃面共用这张图，各自用普通画笔从中取样，不再逐个读取背景。
//
// 改编自 prism_ui（https://github.com/chen08209/prism_ui）的
// lib/liquid_glass_capture.dart 与 lib/liquid_glass.dart，
// Copyright chen08209，GNU GPL v3.0。保留了截取、分层、像素对齐与
// 色带复用的做法，去掉了本项目不用的雾化层、按住保留、分组与遮罩层。
//
// 与每块玻璃各套一层 BackdropFilter 相比：
// - 不打断当前渲染 pass、不拷贝屏幕，玻璃只是一次普通绘制；
// - 截取按玻璃的模糊程度缩小（模糊 sigma 在截取图上约占四个像素，
//   最多缩到 1/8），模糊在小图上做；
// - 画面静止时沿用上一张截取，不重新截取也不重新模糊；
// - 只用画笔 shader 与离屏图片，Skia 与 Impeller 都可用。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 截取的模糊在截取图上至少占的像素数。内容按截取像素整格落位（防止亚像素
/// 滚动时闪烁），截取像素越大，滚动时玻璃里的背景越是一格一格地跳：两个
/// 像素时导航胶囊的截取每格约 2.3dp（DPR 3），背景停住几帧再跳一下，看着
/// 不跟手；四个像素时每格约 1dp、每次跳动减半，静态也更细腻
const double _captureFrost = 4;
const int _maxDivisor = 8;
const double _maxCaptureSide = 2048;

/// 缩小后的截取按线性采样读，本身就带这么多像素的柔化
const double _captureSoftness = 0.5;

/// 图层内容可能画出其记录范围的距离
const double _overflow = 64;

/// Impeller 按尺寸缓存图层与模糊的离屏目标几帧；截取图尺寸随内容移动逐
/// 像素变化会每帧都错过缓存，按步长取整
const double _atlasStep = 32;

/// 玻璃在模糊的这么多 sigma 之外读到的不足 1%，压在这之外的玻璃不算重叠
const double _levelReach = 2.5;

/// 截取宿主：放在应用根部，包住所有可能出现玻璃的内容（导航、弹层、提示）。
/// 宿主之外的玻璃面退回逐块背景模糊。
class GlassCaptureHost extends StatelessWidget {
  const GlassCaptureHost({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  /// 测试用：累计截取次数与最近一次的统计
  @visibleForTesting
  static int debugCaptures = 0;

  @visibleForTesting
  static ({int snapshots, int panes})? debugLastCapture;

  @override
  Widget build(BuildContext context) {
    return _GlassCaptureHostBox(
      enabled: enabled,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      child: child,
    );
  }
}

class _GlassCaptureHostBox extends SingleChildRenderObjectWidget {
  const _GlassCaptureHostBox({
    required this.enabled,
    required this.devicePixelRatio,
    super.child,
  });

  final bool enabled;
  final double devicePixelRatio;

  @override
  _RenderGlassCaptureHost createRenderObject(BuildContext context) =>
      _RenderGlassCaptureHost(
        enabled: enabled,
        devicePixelRatio: devicePixelRatio,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGlassCaptureHost renderObject,
  ) {
    renderObject
      ..enabled = enabled
      ..devicePixelRatio = devicePixelRatio;
  }
}

class _RenderGlassCaptureHost extends RenderProxyBox {
  _RenderGlassCaptureHost({
    required bool enabled,
    required double devicePixelRatio,
  }) : _enabled = enabled,
       _devicePixelRatio = devicePixelRatio;

  final _layer = LayerHandle<_GlassHostLayer>();

  bool _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _enabled;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_enabled) {
      _release();
      super.paint(context, offset);
      return;
    }
    final layer = _layer.layer ??= _GlassHostLayer();
    layer
      ..devicePixelRatio = _devicePixelRatio
      ..bounds = offset & size;
    context.pushLayer(layer, super.paint, offset);
  }

  // 还沿用本轮截取的玻璃面会继续从中取样，换一轮让它们回退
  void _release() {
    if (_layer.layer != null) {
      _layer.layer = null;
      _GlassHostLayer._pass++;
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }
}

class _GlassHostLayer extends ContainerLayer {
  static int _pass = 0;

  double devicePixelRatio = 1;
  Rect bounds = Rect.zero;

  final _atlases = <({ui.Image image, List<_Band> bands})>[];

  // 离开图层树但还活着的玻璃面（如被新路由盖住）会一直握着上次取样的图
  var _panes = <_GlassPaneLayer>{};

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (!_hasHostAbove) _capture();
    super.addToScene(builder);
  }

  bool get _hasHostAbove {
    for (Layer? above = parent; above != null; above = above.parent) {
      if (above is _GlassHostLayer) return true;
    }
    return false;
  }

  @override
  void dispose() {
    for (final pane in _panes) {
      pane._dropCaptured();
    }
    _panes = {};
    for (final atlas in _atlases) {
      atlas.image.dispose();
    }
    _atlases.clear();
    super.dispose();
  }

  /// 压在先画的玻璃之上的玻璃升一层，读的截取里含着下面那块玻璃
  void _capture() {
    _pass++;
    final found = <_Behind>[];
    _gather(this, Matrix4.identity(), this, Matrix4.identity(), [], found);
    final panes = {for (final entry in found) entry.pane};
    for (final pane in _panes.difference(panes)) {
      pane._dropCaptured();
    }
    _panes = panes;
    final placed = <_Behind>[];
    for (final entry in found) {
      if (_place(entry)) {
        placed.add(entry);
      } else {
        entry.pane._captureNothing(_pass);
      }
    }
    var levels = 0;
    for (final (index, entry) in placed.indexed) {
      for (final before in placed.take(index)) {
        if ((identical(entry.root, this) ||
                before.ancestors.contains(entry.root)) &&
            before.device.overlaps(entry.reach)) {
          entry.level = math.max(entry.level, before.level + 1);
        }
      }
      levels = math.max(levels, entry.level + 1);
    }
    var snapshots = 0;
    for (var level = 0; level < levels; level++) {
      final members = [
        for (final entry in placed)
          if (entry.level == level) entry,
      ];
      final (:atlas, :taken) = _snapshot(level, members);
      if (taken) snapshots++;
      for (final entry in members) {
        _publish(entry, atlas);
      }
    }
    while (_atlases.length > levels) {
      _atlases.removeLast().image.dispose();
    }
    assert(() {
      GlassCaptureHost.debugCaptures++;
      GlassCaptureHost.debugLastCapture = (
        snapshots: snapshots,
        panes: placed.length,
      );
      return true;
    }());
  }

  void _gather(
    ContainerLayer layer,
    Matrix4 toHost,
    ContainerLayer root,
    Matrix4 rootToHost,
    List<ContainerLayer> chain,
    List<_Behind> found,
  ) {
    chain.add(layer);
    for (Layer? child = layer.firstChild; child != null;) {
      switch (child) {
        case final _GlassPaneLayer pane:
          found.add(_Behind(pane, toHost, root, rootToHost, chain.toSet()));
        case final ContainerLayer container:
          final offscreen = _drawsOffscreen(container);
          _gather(
            container,
            _within(container, toHost),
            offscreen ? container : root,
            offscreen ? toHost : rootToHost,
            chain,
            found,
          );
      }
      child = child.nextSibling;
    }
    chain.removeLast();
  }

  /// 槽位对齐到截取图的像素：玻璃移动而内容不动时，内容落在同样的像素上
  bool _place(_Behind entry) {
    final pane = entry.pane;
    final blur = pane.blur;
    final storage = entry.toHost.storage;
    final stretch = math.max(storage[0].abs(), storage[5].abs());
    final device = entry.device;
    if (stretch == 0 || device.isEmpty || !device.overlaps(bounds)) {
      return false;
    }
    final reach = (3 * blur + pane.bend + 2) * stretch;
    entry.reach = device.inflate((_levelReach * blur + pane.bend) * stretch);
    final covered = device.inflate(reach).intersect(bounds);
    final longest = math.max(covered.width, covered.height) * devicePixelRatio;
    final divisor = math.max(
      math.min(
        _maxDivisor,
        math.max(
          1,
          (blur * stretch * devicePixelRatio / _captureFrost).floor(),
        ),
      ),
      (longest / _maxCaptureSide).ceil(),
    );
    final scale = devicePixelRatio / divisor;
    final frost = blur * stretch * scale;
    final softness = divisor > 1 ? _captureSoftness : 0.0;
    final left = (covered.left * scale).floorToDouble();
    final top = (covered.top * scale).floorToDouble();
    final right = (covered.right * scale).ceilToDouble();
    final bottom = (covered.bottom * scale).ceilToDouble();
    entry
      ..texelsPerDp = scale
      ..blurSigma = frost > softness
          ? math.sqrt(frost * frost - softness * softness)
          : 0.0
      ..slot = Rect.fromLTRB(
        left / scale,
        top / scale,
        right / scale,
        bottom / scale,
      )
      ..texels = Size(right - left, bottom - top);
    return true;
  }

  ({ui.Image atlas, bool taken}) _snapshot(int level, List<_Behind> members) {
    // 模糊相同的槽位排在一起，由同一层模糊；不模糊的单独成带
    final classes = <Object, List<_Behind>>{};
    for (final entry in members) {
      (classes[entry.blurSigma == 0 ? entry : entry.blurSigma] ??= []).add(
        entry,
      );
    }
    double step(double extent) => (extent / _atlasStep).ceil() * _atlasStep;
    final bands = <_Band>[];
    final pictures = <ui.Picture>[];
    var top = 0.0;
    for (final entries in classes.values) {
      var bottom = 0.0;
      var width = 0.0;
      for (final entry in entries) {
        entry.place = Offset(0, top + bottom) & entry.texels;
        bottom += entry.texels.height;
        width = math.max(width, entry.texels.width);
      }
      final rect = Rect.fromLTWH(0, top, step(width), step(bottom));
      final sigma = entries.first.blurSigma;
      final drawn = <Object?>[sigma, rect.size];
      final recorder = ui.PictureRecorder();
      // Impeller 按图层覆盖范围缩放大半径模糊，先铺满整带
      final canvas = Canvas(recorder)
        ..drawRect(
          Offset.zero & rect.size,
          Paint()
            ..color = const Color(0x00000000)
            ..blendMode = BlendMode.src,
        );
      for (final entry in entries) {
        final place = entry.place.shift(-rect.topLeft);
        drawn
          ..add(place)
          ..add(entry.slot)
          ..addAll(entry.rootToHost.storage);
        canvas
          ..save()
          ..clipRect(place)
          ..translate(place.left, place.top)
          ..scale(entry.texelsPerDp)
          ..translate(-entry.slot.left, -entry.slot.top)
          ..transform(entry.rootToHost.storage);
        _Replay(canvas, drawn, entry).run();
        canvas.restore();
      }
      bands.add((rect: rect, sigma: sigma, drawn: drawn));
      pictures.add(recorder.endRecording());
      top = rect.bottom;
    }
    final size = Size(
      bands.fold(0.0, (width, band) => math.max(width, band.rect.width)),
      top,
    );
    final previous = level < _atlases.length ? _atlases[level] : null;
    final last = previous?.bands ?? const <_Band>[];
    if (previous != null &&
        previous.image.width == size.width &&
        previous.image.height == size.height &&
        last.length == bands.length &&
        bands.indexed.every(
          (band) =>
              band.$2.rect == last[band.$1].rect &&
              listEquals(band.$2.drawn, last[band.$1].drawn),
        )) {
      for (final picture in pictures) {
        picture.dispose();
      }
      return (atlas: previous.image, taken: false);
    }
    // Skia 的图片会一直引用绘制它的内容，从上一张截取拷贝会把之前每一张
    // 都串着留在内存里，只在 Impeller 上复用未变的色带
    final carry = ui.ImageFilter.isShaderFilterSupported;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final (index, band) in bands.indexed) {
      final picture = pictures[index];
      final old = carry
          ? last.where((old) => listEquals(old.drawn, band.drawn)).firstOrNull
          : null;
      if (old != null) {
        canvas.drawImageRect(
          previous!.image,
          old.rect,
          band.rect,
          Paint()
            ..filterQuality = FilterQuality.none
            ..blendMode = BlendMode.src,
        );
      } else {
        final sigma = band.sigma;
        canvas
          ..save()
          ..clipRect(band.rect);
        if (sigma > 0) {
          canvas.saveLayer(
            band.rect,
            Paint()
              ..imageFilter = ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.clamp,
              ),
          );
        }
        // Impeller 按图层还原时的变换应用滤镜，平移放进图层里面
        canvas
          ..save()
          ..translate(band.rect.left, band.rect.top)
          ..drawPicture(picture)
          ..restore();
        if (sigma > 0) canvas.restore();
        canvas.restore();
      }
      picture.dispose();
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(size.width.toInt(), size.height.toInt());
    picture.dispose();
    if (previous == null) {
      _atlases.add((image: image, bands: bands));
    } else {
      previous.image.dispose();
      _atlases[level] = (image: image, bands: bands);
    }
    return (atlas: image, taken: true);
  }

  void _publish(_Behind entry, ui.Image atlas) {
    entry.pane._captureFrom(
      _pass,
      atlas,
      _sampling(entry),
      identical(entry.root, this) ? BlendMode.srcOver : BlendMode.src,
    );
  }

  /// 玻璃局部坐标（dp，自左上角）到截取图像素的映射，与取样钳位范围
  List<double> _sampling(_Behind slot) {
    final pane = slot.pane;
    final storage = slot.toHost.storage;
    final place = slot.place;
    final scale = slot.texelsPerDp;
    final texelsPerPaneX = storage[0] * scale;
    final texelsPerPaneY = storage[5] * scale;
    final originX =
        place.left +
        (storage[0] * pane.rect.left + storage[12] - slot.slot.left) * scale;
    final originY =
        place.top +
        (storage[5] * pane.rect.top + storage[13] - slot.slot.top) * scale;
    return [
      -originX / texelsPerPaneX,
      -originY / texelsPerPaneY,
      1 / texelsPerPaneX,
      1 / texelsPerPaneY,
      place.left + 0.5,
      place.top + 0.5,
      place.right - 0.5,
      place.bottom - 0.5,
    ];
  }
}

typedef _Band = ({Rect rect, double sigma, List<Object?> drawn});

class _Behind {
  _Behind(this.pane, this.toHost, this.root, this.rootToHost, this.ancestors);

  final _GlassPaneLayer pane;
  final Matrix4 toHost;

  /// 宿主，或其下离玻璃最近的离屏图层：背景滤镜在那里只能读到该层自己的内容
  final ContainerLayer root;
  final Matrix4 rootToHost;
  final Set<ContainerLayer> ancestors;

  late final Rect device = MatrixUtils.transformRect(toHost, pane.rect);

  /// 先画的玻璃落在这个范围里，就会出现在本玻璃读到的内容中
  Rect reach = Rect.zero;
  Rect slot = Rect.zero;
  double texelsPerDp = 1;
  double blurSigma = 0;
  Size texels = Size.zero;
  Rect place = Rect.zero;
  int level = 0;
}

/// 图层当前给子级的变换（[Layer.applyTransform] 可能还是上一帧的）
Matrix4? _geometry(ContainerLayer layer) {
  Matrix4 applied(Layer child) {
    final matrix = Matrix4.identity();
    layer.applyTransform(child, matrix);
    return matrix;
  }

  return switch (layer) {
    TransformLayer(:final transform?, :final offset) =>
      offset == Offset.zero
          ? transform
          : (Matrix4.translationValues(offset.dx, offset.dy, 0)
              ..multiply(transform)),
    OffsetLayer(:final offset) || LeaderLayer(:final offset) =>
      offset == Offset.zero
          ? null
          : Matrix4.translationValues(offset.dx, offset.dy, 0),
    FollowerLayer(:final firstChild?) => applied(firstChild),
    _ => null,
  };
}

Matrix4 _within(ContainerLayer layer, Matrix4 toHost) {
  final geometry = _geometry(layer);
  return geometry == null ? toHost : (toHost.clone()..multiply(geometry));
}

/// 会离屏绘制、让其中的背景滤镜只读到本层内容的图层。半透明图层不算：
/// 淡入淡出中的玻璃仍读页面，并随图层一起淡化
bool _drawsOffscreen(Layer layer) {
  return switch (layer) {
    ClipRectLayer(:final clipBehavior) ||
    ClipRRectLayer(:final clipBehavior) ||
    ClipRSuperellipseLayer(:final clipBehavior) ||
    ClipPathLayer(
      :final clipBehavior,
    ) => clipBehavior == Clip.antiAliasWithSaveLayer,
    ColorFilterLayer() ||
    ImageFilterLayer() ||
    ShaderMaskLayer() ||
    BackdropFilterLayer() => true,
    _ => false,
  };
}

/// 把玻璃所在根图层里、玻璃之前画的内容按引擎合成的方式重画到截取上
class _Replay {
  _Replay(this.canvas, this.drawn, this.entry) : _toHost = [entry.rootToHost];

  final Canvas canvas;
  final List<Object?> drawn;
  final _Behind entry;
  final List<Matrix4> _toHost;

  // 图层的效果在其下第一次有内容绘制时才应用
  final _entered = <(ContainerLayer, Matrix4?, bool)>[];
  final _saves = <int>[];

  void run() => _walk(entry.root, root: true);

  bool _walk(ContainerLayer layer, {required bool root}) {
    if (!root && !entry.ancestors.contains(layer) && !_mayShow(layer)) {
      return false;
    }
    final geometry = _geometry(layer);
    final outer = _toHost.last;
    _toHost.add(geometry == null ? outer : (outer.clone()..multiply(geometry)));
    _entered.add((layer, geometry, root));
    var reached = false;
    for (Layer? child = layer.firstChild; child != null && !reached;) {
      switch (child) {
        case _ when identical(child, entry.pane):
          reached = true;
        case final _GlassPaneLayer pane
            when pane._capturedPass == _GlassHostLayer._pass:
          if (pane._captured case final picture? when _shows(pane.rect)) {
            _draw(picture);
          }
        case final PictureLayer recorded:
          if (recorded.picture case final picture?
              when _shows(recorded.canvasBounds.inflate(_overflow))) {
            _draw(picture);
          }
        case final ContainerLayer container:
          reached = _walk(container, root: false);
      }
      child = child.nextSibling;
    }
    _leave();
    _toHost.removeLast();
    return reached;
  }

  bool _mayShow(ContainerLayer layer) {
    if (layer is OpacityLayer && layer.alpha == 0) return false;
    final clip = layer.describeClipBounds();
    return clip == null || _shows(clip);
  }

  bool _shows(Rect bounds) =>
      MatrixUtils.transformRect(_toHost.last, bounds).overlaps(entry.slot);

  void _draw(ui.Picture picture) {
    while (_saves.length < _entered.length) {
      _saves.add(_apply(_entered[_saves.length]));
    }
    final shift = _wholeTexelShift();
    canvas
      ..save()
      ..translate(shift.dx, shift.dy)
      ..drawPicture(picture)
      ..restore();
    drawn.add(picture);
  }

  /// 内容按截取图的整像素落位：列表以亚像素滚动时，截取逐像素整体移动，
  /// 不会每帧闪烁
  Offset _wholeTexelShift() {
    final m = _toHost.last.storage;
    if (m[1] != 0 || m[4] != 0 || m[3] != 0 || m[7] != 0) return Offset.zero;
    final scale = entry.texelsPerDp;
    double by(double translation, double stretch) {
      final texels = translation * scale;
      return stretch == 0
          ? 0
          : (texels.roundToDouble() - texels) / (scale * stretch);
    }

    return Offset(by(m[12], m[0]), by(m[13], m[5]));
  }

  int _apply((ContainerLayer, Matrix4?, bool) entered) {
    final (layer, geometry, root) = entered;
    var saves = 0;
    if (geometry != null) {
      canvas
        ..save()
        ..transform(geometry.storage);
      drawn.addAll(geometry.storage);
      saves++;
    }
    final effect = root ? null : _effectOf(layer);
    if (effect case (final paint, final key)?) {
      canvas.saveLayer(null, paint);
      drawn
        ..add(layer.runtimeType)
        ..add(key);
      saves++;
    }
    if (_clip(layer)) saves++;
    return saves;
  }

  static (Paint, Object?)? _effectOf(ContainerLayer layer) => switch (layer) {
    OpacityLayer(:final alpha?) when alpha < 255 => (
      Paint()..color = Color.fromARGB(alpha, 0, 0, 0),
      alpha,
    ),
    ColorFilterLayer(:final colorFilter?) => (
      Paint()..colorFilter = colorFilter,
      colorFilter,
    ),
    ImageFilterLayer(:final imageFilter?) => (
      Paint()..imageFilter = imageFilter,
      imageFilter,
    ),
    ShaderMaskLayer(:final shader) => (Paint(), shader),
    _ => null,
  };

  bool _clip(ContainerLayer layer) {
    final Object clip;
    switch (layer) {
      case ClipRectLayer(:final clipRect?, :final clipBehavior)
          when clipBehavior != Clip.none:
        canvas
          ..save()
          ..clipRect(clipRect, doAntiAlias: clipBehavior != Clip.hardEdge);
        clip = clipRect;
      case ClipRRectLayer(:final clipRRect?, :final clipBehavior)
          when clipBehavior != Clip.none:
        canvas
          ..save()
          ..clipRRect(clipRRect, doAntiAlias: clipBehavior != Clip.hardEdge);
        clip = clipRRect;
      case ClipRSuperellipseLayer(
            :final clipRSuperellipse?,
            :final clipBehavior,
          )
          when clipBehavior != Clip.none:
        canvas
          ..save()
          ..clipRSuperellipse(
            clipRSuperellipse,
            doAntiAlias: clipBehavior != Clip.hardEdge,
          );
        clip = clipRSuperellipse;
      case ClipPathLayer(:final clipPath?, :final clipBehavior)
          when clipBehavior != Clip.none:
        canvas
          ..save()
          ..clipPath(clipPath, doAntiAlias: clipBehavior != Clip.hardEdge);
        clip = clipPath;
      default:
        final bounds = layer.describeClipBounds();
        if (bounds == null) return false;
        canvas
          ..save()
          ..clipRect(bounds);
        clip = bounds;
    }
    drawn.add(clip);
    return true;
  }

  void _leave() {
    final (layer, _, root) = _entered.removeLast();
    if (_saves.length <= _entered.length) return;
    final saves = _saves.removeLast();
    if (layer case ShaderMaskLayer(
      :final shader?,
      :final maskRect?,
      :final blendMode?,
    ) when !root) {
      canvas
        ..translate(maskRect.left, maskRect.top)
        ..drawRect(
          Offset.zero & maskRect.size,
          Paint()
            ..shader = shader
            ..blendMode = blendMode,
        );
      drawn
        ..add(maskRect)
        ..add(blendMode);
    }
    for (var index = 0; index < saves; index++) {
      canvas.restore();
    }
    drawn.add(saves);
  }
}

/// 玻璃面的背景：在宿主里按统一截取绘制（有折射 shader 时走光学材质，
/// 否则只是模糊后的背景），不在宿主里时退回一层背景模糊。
///
/// 只画背景，不画色罩与描边，由 GlassSurface 在其上叠加；不做形状裁切，
/// 由调用方限制可见范围（与原来的 BackdropFilter 一致）。
class GlassBackdrop extends LeafRenderObjectWidget {
  const GlassBackdrop({
    super.key,
    required this.blurSigma,
    this.program,
    this.opticalUniforms,
    this.bend = 0,
  }) : assert(program == null || opticalUniforms != null);

  /// 主模糊 sigma（逻辑像素）
  final double blurSigma;

  /// 折射 shader；为 null 时只画模糊后的背景
  final ui.FragmentProgram? program;

  /// 按玻璃尺寸给出 shader 在取样映射之后的 uniform（见 glass_surface.frag）
  final List<double> Function(Size size)? opticalUniforms;

  /// 折射与色散向外取样的最远距离（逻辑像素），截取要多留出这么多
  final double bend;

  @override
  RenderGlassBackdrop createRenderObject(BuildContext context) =>
      RenderGlassBackdrop(
        blurSigma: blurSigma,
        program: program,
        opticalUniforms: opticalUniforms,
        bend: bend,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderGlassBackdrop renderObject,
  ) {
    renderObject
      ..blurSigma = blurSigma
      ..program = program
      ..opticalUniforms = opticalUniforms
      ..bend = bend;
  }
}

class RenderGlassBackdrop extends RenderBox {
  RenderGlassBackdrop({
    required double blurSigma,
    ui.FragmentProgram? program,
    List<double> Function(Size size)? opticalUniforms,
    double bend = 0,
  }) : _blurSigma = blurSigma,
       _program = program,
       _opticalUniforms = opticalUniforms,
       _bend = bend;

  final _layer = LayerHandle<_GlassPaneLayer>();

  double _blurSigma;
  set blurSigma(double value) {
    if (value == _blurSigma) return;
    _blurSigma = value;
    markNeedsPaint();
  }

  ui.FragmentProgram? _program;
  set program(ui.FragmentProgram? value) {
    if (identical(value, _program)) return;
    _program = value;
    markNeedsPaint();
  }

  List<double> Function(Size size)? _opticalUniforms;
  set opticalUniforms(List<double> Function(Size size)? value) {
    _opticalUniforms = value;
    markNeedsPaint();
  }

  double _bend;
  set bend(double value) {
    if (value == _bend) return;
    _bend = value;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      _layer.layer = null;
      return;
    }
    final program = _program;
    final pane = _layer.layer ??= _GlassPaneLayer();
    pane
      ..rect = offset & size
      ..blur = _blurSigma
      ..bend = program == null ? 0 : _bend
      ..program = program
      ..look = program == null ? const [] : _opticalUniforms!(size);
    context.addLayer(pane);
  }

  @override
  void dispose() {
    _layer.layer = null;
    super.dispose();
  }
}

class _GlassPaneLayer extends Layer {
  ui.FragmentProgram? program;
  Rect rect = Rect.zero;
  double blur = 0;
  double bend = 0;
  List<double> look = const [];

  int _capturedPass = -1;
  ui.Picture? _captured;
  ui.FragmentShader? _shader;
  (ui.Image, BlendMode, ui.FragmentProgram?, List<double>)? _captureKey;

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  void dispose() {
    _dropCaptured();
    super.dispose();
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (_capturedPass == _GlassHostLayer._pass) {
      if (_captured case final picture?) {
        builder.addPicture(Offset.zero, picture);
      }
      return;
    }
    // 不在宿主里（截图、独立视图等）：退回一层背景模糊
    _dropCaptured();
    builder.pushClipRect(rect);
    builder.pushBackdropFilter(
      ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.clamp),
    );
    builder.pop();
    builder.pop();
  }

  /// 按宿主截取到 [atlas] 里的背景绘制，直到宿主下一轮截取
  void _captureFrom(
    int pass,
    ui.Image atlas,
    List<double> mapping,
    BlendMode blendMode,
  ) {
    _capturedPass = pass;
    final program = this.program;
    final uniforms = <double>[
      atlas.width.toDouble(),
      atlas.height.toDouble(),
      -rect.left,
      -rect.top,
      1,
      1,
      ...mapping,
      ...look,
    ];
    if (_captureKey case (final image, final mode, final shaded, final values)?
        when _captured != null &&
            identical(image, atlas) &&
            mode == blendMode &&
            identical(shaded, program) &&
            listEquals(values, uniforms)) {
      return;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (program == null) {
      // 只要模糊：截取里已经带着模糊，按映射把对应部分贴上
      canvas.drawImageRect(
        atlas,
        Rect.fromLTWH(
          -mapping[0] / mapping[2],
          -mapping[1] / mapping[3],
          rect.width / mapping[2],
          rect.height / mapping[3],
        ),
        rect,
        Paint()
          ..filterQuality = FilterQuality.low
          ..blendMode = blendMode,
      );
    } else {
      final shader = _shader ??= program.fragmentShader();
      shader.setImageSampler(0, atlas, filterQuality: FilterQuality.low);
      for (final (index, value) in uniforms.indexed) {
        shader.setFloat(index, value);
      }
      canvas.drawRect(
        rect,
        Paint()
          ..shader = shader
          ..blendMode = blendMode,
      );
    }
    _hold(recorder.endRecording());
    _captureKey = (atlas, blendMode, program, uniforms);
  }

  /// 本轮截取里看不到这块玻璃，什么都不画
  void _captureNothing(int pass) {
    _capturedPass = pass;
    _dropCaptured();
  }

  // shader 会一直取样最后设给它的图，直到释放
  void _dropCaptured() {
    _hold(null);
    _captureKey = null;
    _shader?.dispose();
    _shader = null;
  }

  void _hold(ui.Picture? captured) {
    _captured?.dispose();
    _captured = captured;
  }
}
