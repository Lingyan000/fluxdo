import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:m3e_ui/m3e_ui.dart';

import 'morphing_dialog_anchor.dart';

/// 卡片与预览共享同一个运动表面，展开途中再交接正文。
///
/// 正文按最终宽度排版，在同一次 layout 中决定表面尺寸，无需逐帧回传
/// 测量结果。源卡片和正文只做等比缩放，长标题不会在飞行中反复换行。
class MorphingDialogShell extends StatelessWidget {
  const MorphingDialogShell({
    super.key,
    required this.animation,
    required this.child,
    this.anchorRect,
    this.source,
    this.anchorColor,
    this.anchorRadius = 10,
    this.targetRadius = 20,
    this.dialogWidth,
  });

  static const enterDuration = Duration(milliseconds: 420);
  static const exitDuration = Duration(milliseconds: 280);
  static const resizeDuration = Duration(milliseconds: 200);

  final Animation<double> animation;
  final Rect? anchorRect;
  final MorphingDialogSnapshot? source;
  final Widget child;
  final Color? anchorColor;
  final double anchorRadius;
  final double targetRadius;
  final double? dialogWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final reducedMotion = media.disableAnimations;
    final insets = EdgeInsets.fromLTRB(
      media.padding.left + 16,
      media.padding.top + 16,
      media.padding.right + 16,
      math.max(media.viewInsets.bottom, media.viewPadding.bottom) + 16,
    );
    return TweenAnimationBuilder<EdgeInsets>(
      tween: EdgeInsetsTween(begin: insets, end: insets),
      duration: reducedMotion ? Duration.zero : resizeDuration,
      curve: Curves.easeOutCubic,
      builder: (context, padding, child) => _DialogViewport(
        child: _DialogSurface(
          key: const ValueKey('morphing-shell'),
          animation: animation,
          anchorRect: source?.rect ?? anchorRect,
          source: source,
          padding: padding,
          anchorColor:
              anchorColor ??
              theme.cardTheme.color ??
              theme.colorScheme.surfaceContainerLow,
          color: theme.colorScheme.surface,
          sourceBackground: theme.scaffoldBackgroundColor,
          anchorRadius: anchorRadius,
          targetRadius: targetRadius,
          dialogWidth: dialogWidth,
          spatialCurve: M3eFlags.of(context).enabled
              ? Curves.easeInOutCubicEmphasized
              : Curves.easeInOutCubic,
          reducedMotion: reducedMotion,
          child: child!,
        ),
      ),
      child: reducedMotion
          ? RepaintBoundary(child: child)
          : AnimatedSize(
              duration: resizeDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              // 裁剪由飞行表面统一承担。
              clipBehavior: Clip.none,
              child: RepaintBoundary(child: child),
            ),
    );
  }
}

class _DialogViewport extends SingleChildRenderObjectWidget {
  const _DialogViewport({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDialogViewport();
}

class _RenderDialogViewport extends RenderShiftedBox {
  _RenderDialogViewport() : super(null);

  @override
  void performLayout() {
    size = constraints.biggest;
    final surface = child! as _RenderDialogSurface;
    surface.layout(BoxConstraints.loose(size), parentUsesSize: true);
    (surface.parentData! as BoxParentData).offset = surface.rect.topLeft;
  }
}

class _DialogSurface extends SingleChildRenderObjectWidget {
  const _DialogSurface({
    super.key,
    required this.animation,
    required this.anchorRect,
    required this.source,
    required this.padding,
    required this.anchorColor,
    required this.color,
    required this.sourceBackground,
    required this.anchorRadius,
    required this.targetRadius,
    required this.dialogWidth,
    required this.spatialCurve,
    required this.reducedMotion,
    required super.child,
  });

  final Animation<double> animation;
  final Rect? anchorRect;
  final MorphingDialogSnapshot? source;
  final EdgeInsets padding;
  final Color anchorColor;
  final Color color;
  final Color sourceBackground;
  final double anchorRadius;
  final double targetRadius;
  final double? dialogWidth;
  final Curve spatialCurve;
  final bool reducedMotion;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDialogSurface(this);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDialogSurface renderObject,
  ) {
    renderObject.configuration = this;
  }
}

class _RenderDialogSurface extends RenderShiftedBox {
  _RenderDialogSurface(this._configuration) : super(null);

  _DialogSurface _configuration;
  Rect rect = Rect.zero;
  Rect? _closingRect;
  Rect? _returnRect;
  double _reverseStart = 1;
  double _contentScale = 1;
  double _openness = 0;
  bool _orphaned = false;
  final _clipLayer = LayerHandle<ClipRRectLayer>();
  final _opacityLayer = LayerHandle<OpacityLayer>();
  final _transformLayer = LayerHandle<TransformLayer>();

  Animation<double> get _animation => _configuration.animation;

  set configuration(_DialogSurface value) {
    final animationChanged = _animation != value.animation;
    if (animationChanged && attached) _unlisten();
    _configuration = value;
    if (animationChanged && attached) _listen();
    markNeedsLayout();
  }

  void _listen() {
    _animation.addListener(markNeedsLayout);
    _animation.addStatusListener(_onStatus);
  }

  void _unlisten() {
    _animation.removeListener(markNeedsLayout);
    _animation.removeStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      // 从当前画面出发，正文加载和输入法变化不再改变返程轨迹。
      _closingRect = rect;
      _reverseStart = _animation.value;
      final currentSource = _configuration.source?.currentRect();
      _returnRect = currentSource ?? _configuration.anchorRect;
      _orphaned = _configuration.source != null && currentSource == null;
    } else if (status == AnimationStatus.forward) {
      _closingRect = null;
      _orphaned = false;
    } else if (status == AnimationStatus.dismissed) {
      _configuration.source?.restore();
    }
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    _opacityLayer.layer = null;
    _transformLayer.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    final config = _configuration;
    final viewport = Offset.zero & constraints.biggest;
    final available = config.padding.deflateRect(viewport);
    final width = math.min(
      config.dialogWidth ?? (viewport.width * 0.9).clamp(300.0, 500.0),
      math.max(0.0, available.width),
    );
    child!.layout(
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: math.max(
          0,
          math.min(viewport.height * 0.7, available.height),
        ),
      ),
      parentUsesSize: true,
    );
    final destination = Rect.fromCenter(
      center: available.center,
      width: child!.size.width,
      height: child!.size.height,
    );
    final anchor =
        config.anchorRect ??
        Rect.fromCenter(
          center: destination.center,
          width: destination.width * 0.96,
          height: destination.height * 0.96,
        );
    final raw = _animation.value.clamp(0.0, 1.0);
    _openness = raw;
    if (config.reducedMotion) {
      rect = destination;
      _openness = _animation.status == AnimationStatus.reverse ? 0 : 1;
    } else if (_closingRect != null) {
      final remaining = _reverseStart == 0
          ? 0.0
          : (raw / _reverseStart).clamp(0.0, 1.0);
      final progress = Curves.easeInOutCubic.transform(1 - remaining);
      rect = Rect.lerp(
        _closingRect,
        _orphaned ? _closingRect : (_returnRect ?? anchor),
        progress,
      )!;
    } else {
      rect = Rect.lerp(
        anchor,
        destination,
        config.spatialCurve.transform(raw),
      )!;
    }
    size = rect.size;
    _contentScale = child!.size.width == 0
        ? 1
        : math.min(1, size.width / child!.size.width);
    (child!.parentData! as BoxParentData).offset = Offset(
      (size.width - child!.size.width * _contentScale) / 2,
      0,
    );
  }

  double get _contentOpacity {
    if (_orphaned) return _surfaceOpacity;
    if (_configuration.source == null) {
      return Curves.easeOut.transform(_openness);
    }
    return const Interval(
      0.22,
      0.52,
      curve: Curves.easeOutCubic,
    ).transform(_openness);
  }

  double get _surfaceOpacity => _orphaned
      ? Curves.easeInOut.transform(
          _reverseStart == 0
              ? 0
              : (_animation.value / _reverseStart).clamp(0.0, 1.0),
        )
      : 1;

  double get _sourceOpacity =>
      1 -
      const Interval(
        0.10,
        0.25,
        curve: Curves.easeInOutCubic,
      ).transform(_openness);

  RRect _shape(Offset offset) {
    final t = Curves.easeOutCubic.transform(_openness);
    return RRect.fromRectAndRadius(
      offset & size,
      Radius.circular(
        ui.lerpDouble(
          _configuration.anchorRadius,
          _configuration.targetRadius,
          t,
        )!,
      ),
    );
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final config = _configuration;
    final opacity = _contentOpacity;
    final shape = _shape(offset);
    final effects = Curves.easeOutCubic.transform(_openness);
    context.canvas.drawShadow(
      Path()..addRRect(shape),
      Colors.black.withValues(alpha: 0.22 * _surfaceOpacity),
      12 * effects,
      true,
    );
    // 有来源时表面始终实心。半透明置顶卡的快照叠在页面底色上，
    // 起点仍是原来的颜色；展开后也不会透出列表文字。
    final background = config.source != null
        ? Color.lerp(config.sourceBackground, config.color, effects)!
        : config.anchorRect != null
        ? Color.lerp(config.anchorColor, config.color, effects)!
        : config.color.withValues(alpha: opacity);
    context.canvas.drawRRect(
      shape,
      Paint()
        ..color = background.withValues(alpha: background.a * _surfaceOpacity),
    );
    _clipLayer.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      _shape(Offset.zero),
      (context, offset) {
        if (opacity > 0) {
          _opacityLayer.layer = context.pushOpacity(
            offset,
            (opacity * 255).round(),
            (context, offset) {
              final childOffset = (child!.parentData! as BoxParentData).offset;
              _transformLayer.layer = context.pushTransform(
                needsCompositing,
                offset,
                Matrix4.identity()
                  ..translateByDouble(childOffset.dx, childOffset.dy, 0, 1)
                  ..scaleByDouble(_contentScale, _contentScale, 1, 1),
                (context, offset) => context.paintChild(child!, offset),
                oldLayer: _transformLayer.layer,
              );
            },
            oldLayer: _opacityLayer.layer,
          );
        }
        final source = config.source;
        final sourceOpacity = _sourceOpacity;
        if (source != null && sourceOpacity > 0 && !_orphaned) {
          final scale = math.min(size.width / source.rect.width, 1.04);
          final imageSize = source.rect.size * scale;
          context.canvas.drawImageRect(
            source.image,
            Rect.fromLTWH(
              0,
              0,
              source.image.width.toDouble(),
              source.image.height.toDouble(),
            ),
            Rect.fromLTWH(
              offset.dx + (size.width - imageSize.width) / 2,
              offset.dy,
              imageSize.width,
              imageSize.height,
            ),
            Paint()
              ..color = Colors.white.withValues(alpha: sourceOpacity)
              ..filterQuality = FilterQuality.medium,
          );
        }
      },
      oldLayer: _clipLayer.layer,
    );
  }

  @override
  bool hitTestSelf(Offset position) => _shape(Offset.zero).contains(position);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_animation.status != AnimationStatus.completed ||
        !_shape(Offset.zero).contains(position)) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: (child!.parentData! as BoxParentData).offset,
      position: position,
      hitTest: (result, position) => child!.hitTest(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    transform.scaleByDouble(_contentScale, _contentScale, 1, 1);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_animation.status == AnimationStatus.completed) {
      super.visitChildrenForSemantics(visitor);
    }
  }
}
