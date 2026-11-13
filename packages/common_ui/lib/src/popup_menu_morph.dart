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
      borderRadius: context.shapes.borderRadius(10),
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

/// 临界阻尼弹簧按时间采样成的曲线:route 仍用线性时长驱动,形态由弹簧决定。
/// [response] 是弹簧周期,[span] 是曲线覆盖的时长(均为秒);末端归一,保证到点。
///
/// [velocity] 是起步速度相对弹簧角频率的比例:0 为从静止起步,接近 1 为一出手
/// 就满速、随即减速(手指松开后立即响应的形态)。
class _SpringCurve extends Curve {
  const _SpringCurve(this.response, this.span, {this.velocity = 0});
  final double response, span, velocity;

  double _at(double seconds) {
    final double omega = 2 * math.pi / response;
    return 1 -
        (1 + omega * (1 - velocity) * seconds) * math.exp(-omega * seconds);
  }

  @override
  double transformInternal(double t) => _at(span * t) / _at(span);
}

/// 形变的三条进度:位置、尺寸、透明度共用同一个线性驱动,各自套用曲线。
class _MenuMorphMotion {
  _MenuMorphMotion(
    Animation<double> parent, {
    required Curve moveIn,
    required Curve growIn,
    required Curve fadeIn,
    required Curve moveOut,
    required Curve growOut,
    required Curve fadeOut,
  }) : move = CurvedAnimation(
         parent: parent,
         curve: moveIn,
         reverseCurve: moveOut,
       ),
       grow = CurvedAnimation(
         parent: parent,
         curve: growIn,
         reverseCurve: growOut,
       ),
       opacity = CurvedAnimation(
         parent: parent,
         curve: fadeIn,
         reverseCurve: fadeOut,
       );

  _MenuMorphMotion.menu(Animation<double> parent)
    : this(
        parent,
        moveIn: _kMenuOpenMove,
        growIn: _kMenuOpenGrow,
        fadeIn: _kMenuFadeIn,
        moveOut: _kMenuCloseMove,
        growOut: _kMenuCloseGrow,
        fadeOut: _kMenuFadeOut,
      );

  _MenuMorphMotion.submenu(Animation<double> parent)
    : this(
        parent,
        moveIn: _kSubmenuOpen,
        growIn: _kSubmenuOpen,
        fadeIn: _kSubmenuFadeIn,
        moveOut: _kSubmenuClose,
        growOut: _kSubmenuClose,
        fadeOut: _kSubmenuFadeOut,
      );

  final CurvedAnimation move, grow, opacity;

  void dispose() {
    move.dispose();
    grow.dispose();
    opacity.dispose();
  }
}

/// 内容只布局一次。动画改变绘制轮廓与位置，不逐帧改变文字排版或行高。
///
/// [scaleContent] 为 true 时内容随轮廓宽度等比缩放(菜单从入口长出);
/// 为 false 时内容保持原尺寸,由轮廓向下揭开(子面板从入口行升起)。
class _MenuMorphTransition extends SingleChildRenderObjectWidget {
  const _MenuMorphTransition({
    super.key,
    required this.motion,
    required this.anchor,
    required this.shape,
    required this.shapes,
    required this.color,
    required this.shadowColor,
    required this.elevation,
    required this.textDirection,
    this.scaleContent = true,
    this.anchorRectOf,
    required super.child,
  });
  final _MenuMorphMotion motion;
  final Rect anchor;
  final ShapeBorder shape;
  final UiShapes shapes;
  final Color color, shadowColor;
  final double elevation;
  final TextDirection textDirection;
  final bool scaleContent;
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

  set configuration(_MenuMorphTransition value) {
    if (attached && value.motion != _configuration.motion) {
      _configuration.motion.grow.removeListener(_tick);
      value.motion.grow.addListener(_tick);
    }
    _configuration = value;
    _tick();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _configuration.motion.grow.addListener(_tick);
  }

  @override
  void detach() {
    _configuration.motion.grow.removeListener(_tick);
    super.detach();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  double get _move => _configuration.motion.move.value.clamp(0.0, 1.0);
  double get _grow => _configuration.motion.grow.value.clamp(0.0, 1.0);
  double get _opacity => _configuration.motion.opacity.value.clamp(0.0, 1.0);
  bool get _settled => _move >= 1 && _grow >= 1;

  Rect get _source {
    final anchor = _configuration.anchorRectOf?.call() ?? _configuration.anchor;
    return Rect.fromPoints(
      globalToLocal(anchor.topLeft),
      globalToLocal(anchor.bottomRight),
    );
  }

  /// 中心与尺寸分开插值:中心先到位,尺寸随后长满。
  Rect get _frame {
    final source = _source;
    final extent = Size.lerp(source.size, size, _grow)!;
    return Rect.fromCenter(
      center: Offset.lerp(source.center, size.center(Offset.zero), _move)!,
      width: extent.width,
      height: extent.height,
    );
  }

  ShapeBorder get _frameShape => ShapeBorder.lerp(
    RoundedSuperellipseBorder(
      borderRadius: _configuration.shapes.borderRadius(
        _source.shortestSide / 2,
      ),
    ),
    _configuration.shape,
    _grow,
  )!;

  Path get _outline => _frameShape.getOuterPath(
    _frame,
    textDirection: _configuration.textDirection,
  );

  /// 菜单上离入口最远的角;入口与菜单在某个方向上居中对齐时该方向取中。
  Alignment get _farCorner {
    final offset = _source.center - size.center(Offset.zero);
    double away(double delta) => delta.abs() < 1 ? 0 : -delta.sign;
    return Alignment(away(offset.dx), away(offset.dy));
  }

  Matrix4 get _contentTransform {
    final frame = _frame;
    if (!_configuration.scaleContent) {
      // 面板被屏幕边缘挤开时,头部从入口行的位置滑到最终位置,不与入口错位重影。
      return Matrix4.translationValues(
        _source.left * (1 - _grow),
        frame.top,
        0,
      );
    }
    // 内容按轮廓宽度等比缩放,贴住远离入口的那一角:靠近入口的边先冲出再回收,
    // 远端的边单调到位,内容跟着它走才不会来回摆;不足的部分由轮廓裁掉。
    final scale = math.min(1.0, frame.width / size.width);
    final pin = _farCorner;
    final content = size * scale;
    return Matrix4.identity()
      ..translateByDouble(
        frame.center.dx +
            pin.x * (frame.width - content.width) / 2 -
            content.width / 2,
        frame.center.dy +
            pin.y * (frame.height - content.height) / 2 -
            content.height / 2,
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
    final opacity = _opacity;
    if (_settled && opacity >= 1) {
      super.paint(context, offset);
      return;
    }
    if (opacity <= 0) return;
    // 外形、边框、阴影与内容一起淡入淡出，末帧不留下轮廓或切换到旧按钮截图。
    context.pushOpacity(offset, (255 * opacity).round(), _paintFrame);
  }

  void _paintFrame(PaintingContext context, Offset offset) {
    if (_settled) {
      super.paint(context, offset);
      return;
    }
    final outline = _outline;
    final paintedPath = outline.shift(offset);
    final canvas = context.canvas;
    canvas.drawShadow(
      paintedPath,
      _configuration.shadowColor,
      _configuration.elevation * _grow,
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
      context.pushTransform(
        needsCompositing,
        offset,
        _contentTransform,
        (context, offset) => super.paint(context, offset),
      );
    }, clipBehavior: Clip.antiAlias);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hasSize || _opacity <= 0) return false;
    if (_settled) return super.hitTest(result, position: position);
    if (!_outline.contains(position)) return false;
    if (_opacity > .5) {
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
    if (!_settled) transform.multiply(_contentTransform);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _settled ? null : _frame;
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
