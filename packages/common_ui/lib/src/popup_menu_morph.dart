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
    this.anchorRectOf,
    required super.child,
  });
  final Animation<double> animation;
  final Rect anchor;
  final ShapeBorder shape;
  final Color color, shadowColor;
  final double elevation;
  final TextDirection textDirection;
  final _MenuChainRoute<dynamic> chainRoute;
  final Rect? Function()? anchorRectOf;

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
  double? _chainStartProgress;

  void _freezeForChainClose() {
    _chainStartProgress = _progress;
    markNeedsPaint();
  }

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
    _configuration.chainRoute.freezeForChainClose = _freezeForChainClose;
  }

  @override
  void detach() {
    _configuration.chainRoute.freezeForChainClose = null;
    _configuration.animation.removeListener(_tick);
    super.detach();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  double get _progress =>
      _chainStartProgress ?? _configuration.animation.value.clamp(0.0, 1.0);

  Rect get _source {
    final anchor = _configuration.anchorRectOf?.call() ?? _configuration.anchor;
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

  Matrix4? get _chainTransform {
    final group = _configuration.chainRoute.chainClose;
    return group?.transformAt(globalToLocal(group.pivot));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) return;
    // 单面板保留完整的轮廓形变；多面板冻结当前外形后共用整组收回进度。
    _configuration.chainRoute.menuPivotAlignment = _pointToAlignment(
      _source.center,
      Offset.zero & size,
    );
    final group = _configuration.chainRoute.chainClose;
    if (group != null) {
      context.pushOpacity(offset, (255 * group.opacity).round(), (
        context,
        offset,
      ) {
        context.pushTransform(
          needsCompositing,
          offset,
          _chainTransform!,
          _paintMorph,
        );
      });
    } else {
      _paintMorph(context, offset);
    }
  }

  void _paintMorph(PaintingContext context, Offset offset) {
    final progress = _progress;
    if (progress >= 1) {
      super.paint(context, offset);
      return;
    }
    if (progress <= 0) return;

    // 外形、边框、阴影与内容一起淡出，末帧不留下轮廓或切换到旧按钮截图。
    final visibility = (progress / .3).clamp(0.0, 1.0);
    context.pushOpacity(offset, (255 * visibility).round(), _paintFrame);
  }

  void _paintFrame(PaintingContext context, Offset offset) {
    final outline = _outline;
    final paintedPath = outline.shift(offset);
    final canvas = context.canvas;
    canvas.drawShadow(
      paintedPath,
      _configuration.shadowColor,
      _configuration.elevation * _progress,
      true,
    );
    canvas.drawPath(paintedPath, Paint()..color = _configuration.color);
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
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_configuration.chainRoute.chainClose != null) return false;
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
    final chain = _chainTransform;
    if (chain != null) transform.multiply(chain);
    if (_progress < 1) transform.multiply(_contentTransform);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _progress < 1 ? _frame : null;
}

/// 轮廓可以完整回到入口，入口本身保持实时绘制；在入口边缘渐隐避让图文，
/// 不截取旧画面、不隐藏按钮，也不增加手势识别器。
class _MenuAnchorGuard extends SingleChildRenderObjectWidget {
  const _MenuAnchorGuard({
    this.anchorRectOf,
    required this.animation,
    required super.child,
  });
  final Rect? Function()? anchorRectOf;
  final Animation<double> animation;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMenuAnchorGuard(anchorRectOf, animation);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMenuAnchorGuard renderObject,
  ) {
    renderObject.anchorRectOf = anchorRectOf;
    renderObject.animation = animation;
  }
}

class _RenderMenuAnchorGuard extends RenderProxyBox {
  _RenderMenuAnchorGuard(this._anchorRectOf, this._animation);
  Rect? Function()? _anchorRectOf;
  Animation<double> _animation;

  set animation(Animation<double> value) {
    if (_animation == value) return;
    if (attached) {
      _animation.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _animation = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  set anchorRectOf(Rect? Function()? value) {
    if (_anchorRectOf == value) return;
    _anchorRectOf = value;
    markNeedsPaint();
  }

  Rect? get _anchor {
    final rect = _anchorRectOf?.call();
    return rect == null
        ? null
        : Rect.fromPoints(
            globalToLocal(rect.topLeft),
            globalToLocal(rect.bottomRight),
          );
  }

  @override
  Rect get paintBounds {
    if (!hasSize || !attached) return super.paintBounds;
    final bounds = child?.paintBounds ?? (Offset.zero & size);
    final anchor = _anchor;
    return (anchor == null ? bounds : bounds.expandToInclude(anchor)).inflate(
      32,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final anchor = _anchor;
    // 菜单原本覆盖入口时保持正常覆盖，只保护菜单外的独立触发按钮。
    if (_animation.value >= 1 ||
        anchor == null ||
        anchor.isEmpty ||
        (Offset.zero & size).contains(anchor.center)) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    // 透明带覆盖入口，沿菜单方向在短距离内恢复不透明；避免硬裁剪留下凹口。
    final inset = math.min(12.0, anchor.shortestSide * .3);
    final feather = math.min(8.0, anchor.shortestSide * .2);
    late Rect band;
    late Alignment begin, end;
    if (anchor.center.dy < 0) {
      band = Rect.fromLTWH(0, anchor.bottom - inset, 1, feather);
      begin = Alignment.topCenter;
      end = Alignment.bottomCenter;
    } else if (anchor.center.dy > size.height) {
      band = Rect.fromLTWH(0, anchor.top + inset - feather, 1, feather);
      begin = Alignment.bottomCenter;
      end = Alignment.topCenter;
    } else if (anchor.center.dx < 0) {
      band = Rect.fromLTWH(anchor.right - inset, 0, feather, 1);
      begin = Alignment.centerLeft;
      end = Alignment.centerRight;
    } else {
      band = Rect.fromLTWH(anchor.left + inset - feather, 0, feather, 1);
      begin = Alignment.centerRight;
      end = Alignment.centerLeft;
    }
    final bounds = paintBounds;
    layer ??= ShaderMaskLayer();
    layer!
      ..shader = LinearGradient(
        begin: begin,
        end: end,
        colors: [
          Colors.white.withValues(
            alpha: ((_animation.value - .85) / .15).clamp(0.0, 1.0),
          ),
          Colors.white,
        ],
      ).createShader(band.shift(-bounds.topLeft))
      ..maskRect = bounds.shift(offset)
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(layer!, super.paint, offset);
  }
}
