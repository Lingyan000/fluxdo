part of 'dismissible_popup_menu.dart';

/// 在原菜单项外提供独立的圆角墨水层，保留菜单项自身的激活、禁用与语义。
class _MenuRowSurface extends StatelessWidget {
  const _MenuRowSurface({
    required this.child,
    this.selected = false,
    this.highlighted = false,
  });
  final Widget child;
  final bool selected;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Theme(
        data: theme.copyWith(
          hoverColor: colors.onSurface.withValues(alpha: .08),
          highlightColor: colors.onSurface.withValues(alpha: .12),
          focusColor: colors.primary.withValues(alpha: .12),
          splashFactory: NoSplash.splashFactory,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: ShapeDecoration(
              shape: shape,
              color: highlighted
                  ? colors.onSurface.withValues(alpha: .12)
                  : selected
                  ? colors.secondaryContainer.withValues(alpha: .55)
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 内容只布局一次。动画改变绘制轮廓与位置，不逐帧改变文字排版或行高。
class _MenuMorphTransition extends SingleChildRenderObjectWidget {
  const _MenuMorphTransition({
    super.key,
    required this.animation,
    required this.anchor,
    required this.shape,
    required this.color,
    required this.shadowColor,
    required this.elevation,
    required this.textDirection,
    required this.chainRoute,
    this.source,
    required super.child,
  });
  final Animation<double> animation;
  final Rect anchor;
  final ShapeBorder shape;
  final Color color, shadowColor;
  final double elevation;
  final TextDirection textDirection;
  final _MenuChainRoute<dynamic> chainRoute;
  final _MenuSourceImage? source;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMenuMorph(this);

  @override
  void updateRenderObject(BuildContext context, _RenderMenuMorph renderObject) {
    renderObject.configuration = this;
  }
}

class _RenderMenuMorph extends RenderProxyBox {
  _RenderMenuMorph(this._configuration);
  _MenuMorphTransition _configuration;

  set configuration(_MenuMorphTransition value) {
    if (attached && value.animation != _configuration.animation) {
      _configuration.animation.removeListener(_tick);
      value.animation.addListener(_tick);
    }
    _configuration = value;
    _tick();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _configuration.animation.addListener(_tick);
  }

  @override
  void detach() {
    _configuration.animation.removeListener(_tick);
    super.detach();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  double get _progress => _configuration.animation.value.clamp(0.0, 1.0);

  Rect get _source {
    final anchor = _configuration.source?.anchorOf() ?? _configuration.anchor;
    return Rect.fromPoints(
      globalToLocal(anchor.topLeft),
      globalToLocal(anchor.bottomRight),
    );
  }

  Rect get _frame => Rect.lerp(_source, Offset.zero & size, _progress)!;

  ShapeBorder get _frameShape => ShapeBorder.lerp(
    RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(_source.shortestSide / 2),
    ),
    _configuration.shape,
    _progress,
  )!;

  Path get _outline => _frameShape.getOuterPath(
    _frame,
    textDirection: _configuration.textDirection,
  );

  double get _contentOpacity => ((_progress - .22) / .78).clamp(0.0, 1.0);

  Matrix4 get _contentTransform {
    final frame = _frame;
    final scale = .96 + .04 * _progress;
    return Matrix4.identity()
      ..translateByDouble(
        frame.center.dx - size.width * scale / 2,
        frame.top,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Rect get paintBounds => hasSize && attached
      ? (Offset.zero & size).expandToInclude(_source).inflate(32)
      : super.paintBounds;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) return;
    final progress = _progress;
    // 一级与各级子菜单整链收起时，共用真实触发按钮中心作为目标。
    _configuration.chainRoute.menuPivotAlignment = _pointToAlignment(
      _configuration.anchor.center,
      localToGlobal(Offset.zero) & size,
    );
    if (progress >= 1) {
      super.paint(context, offset);
      return;
    }
    if (progress <= 0) {
      _paintSource(context.canvas, offset);
      return;
    }

    final outline = _outline;
    final visibility = (progress / .3).clamp(0.0, 1.0);
    final paintedPath = outline.shift(offset);
    final canvas = context.canvas;
    canvas.drawShadow(
      paintedPath,
      _configuration.shadowColor.withValues(
        alpha: _configuration.shadowColor.a * visibility,
      ),
      _configuration.elevation * progress,
      true,
    );
    canvas.drawPath(
      paintedPath,
      Paint()
        ..color = _configuration.color.withValues(
          alpha: _configuration.color.a * visibility,
        ),
    );
    _frameShape.paint(
      canvas,
      _frame.shift(offset),
      textDirection: _configuration.textDirection,
    );

    context.pushClipPath(needsCompositing, offset, _frame, outline, (
      context,
      offset,
    ) {
      context.pushOpacity(offset, (255 * _contentOpacity).round(), (
        context,
        offset,
      ) {
        context.pushTransform(
          needsCompositing,
          offset,
          _contentTransform,
          (context, offset) => super.paint(context, offset),
        );
      });
    }, clipBehavior: Clip.antiAlias);
    _paintSource(context.canvas, offset);
  }

  void _paintSource(Canvas canvas, Offset offset) {
    final image = _configuration.source?.image;
    final alpha = (1 - _progress / .48).clamp(0.0, 1.0);
    if (image == null || alpha <= 0) return;
    final source = _source;
    final drift = (_frame.center - source.center) * .16;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      source.shift(offset + drift),
      Paint()
        ..color = Color.fromRGBO(255, 255, 255, alpha)
        ..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hasSize || _progress <= 0) return false;
    if (_progress >= 1) return super.hitTest(result, position: position);
    if (!_outline.contains(position)) return false;
    if (_contentOpacity > .5) {
      result.addWithPaintTransform(
        transform: _contentTransform,
        position: position,
        hitTest: (result, position) =>
            super.hitTestChildren(result, position: position),
      );
    }
    // 变形面板本身接收命中，防止开合中点击面板穿透到遮罩。
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_progress < 1) transform.multiply(_contentTransform);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _progress < 1 ? _frame : null;
}
