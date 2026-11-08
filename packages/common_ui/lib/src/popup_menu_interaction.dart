part of 'dismissible_popup_menu.dart';

/// 每条菜单链共用一次按压：父菜单展开子菜单后，手指仍由原识别器持有。
class _MenuPressSession {
  final List<_MenuDragRegionState> regions = [];
  _MenuDragRegionState? _movingRegion;
  _MenuDragTargetState? _highlighted;
  Timer? _dwell;
  int? _frame;
  int? pointer;
  bool held = false;
  bool disposed = false;
  bool feedback = true;
  Offset _origin = Offset.zero;
  Offset _position = Offset.zero;
  Offset? _landedAt;

  _MenuDragRegionState? get active {
    for (final region in regions.reversed) {
      if (region.mounted &&
          region.widget.route.isCurrent &&
          region.widget.route.animation?.status != AnimationStatus.reverse) {
        return region;
      }
    }
    return null;
  }

  void begin(Offset position) {
    if (disposed) return;
    held = true;
    _origin = _position = position;
    _landedAt = null;
    _update();
  }

  void move(Offset position) {
    if (!held || disposed) return;
    _position = position;
    if (_landedAt != null && (position - _landedAt!).distance > 6) {
      _landedAt = null;
    }
    _frame ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frame = null;
      if (held && !disposed) _update();
    });
  }

  void _update() {
    final region = active;
    if (region == null) return;
    if (_movingRegion != region) {
      _movingRegion?.release();
      _movingRegion = region;
      region.press();
    }
    region.pull(_position - _origin);
    final target = region.targetAt(_position);
    if (_highlighted == target) return;
    _dwell?.cancel();
    _dwell = null;
    _highlighted?.highlight(false);
    _highlighted = target;
    target?.highlight(true);
    if (target == null) return;
    if (feedback) HapticFeedback.selectionClick();
    if (!target.widget.opensSubmenu || _landedAt != null) return;
    _dwell = Timer(const Duration(milliseconds: 400), () {
      if (!held || disposed || !target.mounted || _highlighted != target) {
        return;
      }
      _landedAt = _position;
      target.invoke();
    });
  }

  void end(Offset position) {
    if (!held || disposed) return;
    _position = position;
    _update();
    final target = _landedAt == null ? active?.targetAt(position) : null;
    cancel();
    target?.invoke();
  }

  void cancel() {
    held = false;
    pointer = null;
    _landedAt = null;
    _dwell?.cancel();
    _dwell = null;
    if (_frame case final frame?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
    }
    _frame = null;
    _highlighted?.highlight(false);
    _highlighted = null;
    _movingRegion?.release();
    _movingRegion = null;
  }

  void dispose() {
    cancel();
    disposed = true;
  }
}

class _MenuInteractionScope extends InheritedWidget {
  const _MenuInteractionScope({required this.session, required super.child});
  final _MenuPressSession session;
  static _MenuPressSession of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_MenuInteractionScope>()!
      .session;
  @override
  bool updateShouldNotify(_MenuInteractionScope oldWidget) =>
      session != oldWidget.session;
}

/// 复用原行的 InkWell 回调，CheckedPopupMenuItem、自定义 onTap 的顺序不变。
class _MenuDragTarget extends StatefulWidget {
  const _MenuDragTarget({
    required this.child,
    this.enabled = true,
    this.opensSubmenu = false,
    this.selected = false,
    this.round = false,
    this.onInvoke,
  });
  final Widget child;
  final bool enabled, opensSubmenu, selected, round;
  final VoidCallback? onInvoke;
  @override
  State<_MenuDragTarget> createState() => _MenuDragTargetState();
}

class _MenuDragTargetState extends State<_MenuDragTarget> {
  bool _highlighted = false;
  late _MenuPressSession session;
  VoidCallback? get action {
    if (!mounted || !widget.enabled) return null;
    if (widget.onInvoke != null) return widget.onInvoke;
    VoidCallback? result;
    void visit(Element element) {
      if (result != null) return;
      if (element.widget case InkWell(onTap: final callback?)) {
        result = callback;
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return result;
  }

  void invoke() => action?.call();
  void highlight(bool value) {
    if (mounted && value != _highlighted) setState(() => _highlighted = value);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    session = _MenuInteractionScope.of(context);
  }

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    behavior: HitTestBehavior.translucent,
    child: widget.round
        ? Stack(
            children: [
              widget.child,
              if (_highlighted)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: const CircleBorder(),
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: .12),
                      ),
                    ),
                  ),
                ),
            ],
          )
        : _MenuRowSurface(
            selected: widget.selected,
            highlighted: _highlighted,
            child: widget.child,
          ),
  );
}

/// 已打开的菜单：普通点按交给原行；划选与长列表滚动参加同一个手势竞争。
class _MenuRowRecognizer extends OneSequenceGestureRecognizer {
  _MenuRowRecognizer({super.debugOwner});
  bool Function(PointerDownEvent)? onStart;
  ValueChanged<Offset>? onMove, onEnd;
  VoidCallback? onCancel;
  int? _pointer;
  Offset? _release;
  bool _accepted = false;
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _pointer == null &&
      event.buttons == kPrimaryButton &&
      super.isPointerAllowed(event);
  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!(onStart?.call(event) ?? false)) return;
    _pointer = event.pointer;
    _accepted = false;
    _release = null;
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      onMove?.call(event.position);
    } else if (event is PointerUpEvent) {
      _release = event.position;
      if (_accepted) {
        _finish();
      } else {
        resolve(GestureDisposition.accepted);
      }
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      resolve(GestureDisposition.rejected);
      rejectGesture(event.pointer);
    }
  }

  void _finish() {
    final release = _release;
    _pointer = null;
    _release = null;
    if (release != null) onEnd?.call(release);
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer != _pointer) return;
    _accepted = true;
    if (_release != null) _finish();
  }

  @override
  void rejectGesture(int pointer) {
    stopTrackingPointer(pointer);
    if (_pointer != pointer) return;
    _pointer = null;
    _release = null;
    onCancel?.call();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
  @override
  String get debugDescription => 'menu row selection';
}

class _MenuDragRegion extends StatefulWidget {
  const _MenuDragRegion({required this.route, required this.child});
  final _MenuChainRoute<dynamic> route;
  final Widget child;
  @override
  State<_MenuDragRegion> createState() => _MenuDragRegionState();
}

class _MenuDragRegionState extends State<_MenuDragRegion>
    with TickerProviderStateMixin {
  final _hitKey = GlobalKey();
  late final _lift = AnimationController.unbounded(vsync: this);
  late final _x = AnimationController.unbounded(vsync: this);
  late final _y = AnimationController.unbounded(vsync: this);
  late final session = widget.route.pressSession;
  bool _reduced = false;
  bool _holding = false;
  static final _trackSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 120),
  );
  static final _releaseSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 311,
    ratio: .593,
  );
  @override
  void initState() {
    super.initState();
    session.regions.add(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && session.held) session.move(session._position);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _lift.value = _x.value = _y.value = 0;
    }
  }

  void _spring(
    AnimationController controller,
    double to,
    SpringDescription spring,
  ) {
    if (_reduced || !mounted) return;
    controller.animateWith(
      SpringSimulation(
        spring,
        controller.value,
        to,
        controller.velocity,
        snapToEnd: true,
      ),
    );
  }

  void press() {
    if (!_holding) setState(() => _holding = true);
    _spring(_lift, 1, _releaseSpring);
  }

  void pull(Offset delta) {
    if (!mounted || _reduced) return;
    final box = _hitKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final limit = math.min(10.0, box.size.shortestSide * 7 / 32);
    if (limit <= 0) return;
    double resist(double d) =>
        limit * (1 - 1 / (d.abs() * .55 / limit + 1)) * d.sign;
    _spring(_x, resist(delta.dx), _trackSpring);
    _spring(_y, resist(delta.dy), _trackSpring);
  }

  void release() {
    if (!mounted) return;
    if (_holding) setState(() => _holding = false);
    _spring(_lift, 0, _releaseSpring);
    _spring(_x, 0, _releaseSpring);
    _spring(_y, 0, _releaseSpring);
  }

  _MenuDragTargetState? targetAt(Offset global) {
    final box = _hitKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final hits = BoxHitTestResult();
    box.hitTest(hits, position: box.globalToLocal(global));
    for (final hit in hits.path) {
      if (hit.target case RenderMetaData(
        metaData: final _MenuDragTargetState target,
      )) {
        if (target.session == session && target.action != null) return target;
      }
    }
    return null;
  }

  @override
  void dispose() {
    session.regions.remove(this);
    if (session._movingRegion == this) session._movingRegion = null;
    _lift.dispose();
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MenuInteractionScope(
    session: session,
    child: RawGestureDetector(
      excludeFromSemantics: true,
      gestures: {
        _MenuRowRecognizer:
            GestureRecognizerFactoryWithHandlers<_MenuRowRecognizer>(
              () => _MenuRowRecognizer(debugOwner: this),
              (r) => r
                ..onStart = (event) {
                  if (session.held || targetAt(event.position) == null) {
                    return false;
                  }
                  session.pointer = event.pointer;
                  session.begin(event.position);
                  return true;
                }
                ..onMove = session.move
                ..onEnd = session.end
                ..onCancel = session.cancel,
            ),
      },
      child: AbsorbPointer(
        absorbing: _holding,
        child: RepaintBoundary(
          child: _MenuElasticTransform(
            key: _hitKey,
            lift: _lift,
            x: _x,
            y: _y,
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}

class _MenuElasticTransform extends SingleChildRenderObjectWidget {
  const _MenuElasticTransform({
    super.key,
    required this.lift,
    required this.x,
    required this.y,
    required super.child,
  });
  final Animation<double> lift, x, y;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMenuElastic(lift, x, y)..screenBounds = _bounds(context);

  Rect _bounds(BuildContext context) {
    final view = View.of(context);
    final ratio = view.devicePixelRatio;
    final size = view.physicalSize / ratio;
    return Rect.fromLTRB(
      view.padding.left / ratio + 8,
      view.padding.top / ratio + 8,
      size.width - view.padding.right / ratio - 8,
      size.height -
          math.max(view.padding.bottom, view.viewInsets.bottom) / ratio -
          8,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMenuElastic renderObject,
  ) {
    renderObject.screenBounds = _bounds(context);
  }
}

class _RenderMenuElastic extends RenderProxyBox {
  _RenderMenuElastic(this.lift, this.x, this.y);
  final Animation<double> lift, x, y;
  Rect _screenBounds = Rect.zero;
  set screenBounds(Rect value) {
    if (value == _screenBounds) return;
    _screenBounds = value;
    markNeedsPaint();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    for (final a in [lift, x, y]) {
      a.addListener(_tick);
    }
  }

  @override
  void detach() {
    for (final a in [lift, x, y]) {
      a.removeListener(_tick);
    }
    super.detach();
  }

  Matrix4 get motion {
    if (size.isEmpty || (lift.value == 0 && x.value == 0 && y.value == 0)) {
      return Matrix4.identity();
    }
    final swell = 1 + lift.value * math.min(.06, 8 / size.longestSide);
    final sx = math.min(
      swell * (1 + x.value.abs() / size.width * .5),
      math.max(1.0, _screenBounds.width / size.width),
    );
    final sy = math.min(
      swell * (1 + y.value.abs() / size.height * .5),
      math.max(1.0, _screenBounds.height / size.height),
    );
    final origin = localToGlobal(Offset.zero);
    double keptInside(double value, double low, double high) =>
        low <= high ? value.clamp(low, high) : value;
    final tx = keptInside(
      size.width / 2 * (1 - sx) + x.value,
      _screenBounds.left - origin.dx,
      _screenBounds.right - origin.dx - size.width * sx,
    );
    final ty = keptInside(
      size.height / 2 * (1 - sy) + y.value,
      _screenBounds.top - origin.dy,
      _screenBounds.bottom - origin.dy - size.height * sy,
    );
    return Matrix4.diagonal3Values(sx, sy, 1)..setTranslationRaw(tx, ty, 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || (lift.value == 0 && x.value == 0 && y.value == 0)) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      motion,
      super.paint,
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(motion);
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: motion,
        position: position,
        hitTest: (result, local) => super.hitTest(result, position: local),
      );
}

/// 按钮截图只活到退出动画结束；原按钮隐藏时仍保持布局和同一条指针路径。
class _MenuSourceImage {
  _MenuSourceImage({
    required this.image,
    required this.anchorOf,
    required this.onReveal,
  });
  final ui.Image image;
  final Rect Function() anchorOf;
  final VoidCallback onReveal;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onReveal();
    image.dispose();
  }
}

/// 按住入口打开后沿同一指针划选；滚动区域先等待点击容差时间。
class _MenuAnchorRecognizer extends OneSequenceGestureRecognizer {
  _MenuAnchorRecognizer({super.debugOwner});
  Duration delay = Duration.zero;
  bool Function()? canOpen;
  ValueChanged<PointerDownEvent>? onOpen;
  ValueChanged<PointerMoveEvent>? onMove;
  ValueChanged<PointerUpEvent>? onUp;
  VoidCallback? onCancel;
  PointerDownEvent? _down;
  Timer? _timer;
  bool _opened = false;
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _down == null &&
      event.buttons == kPrimaryButton &&
      super.isPointerAllowed(event);
  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!(canOpen?.call() ?? false)) return;
    _down = event;
    _opened = false;
    startTrackingPointer(event.pointer, event.transform);
    if (delay == Duration.zero) {
      _open();
    } else {
      _timer = Timer(delay, _open);
    }
  }

  void _open() {
    _timer?.cancel();
    final down = _down;
    if (down == null || _opened) return;
    _opened = true;
    resolve(GestureDisposition.accepted);
    onOpen?.call(down);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (down == null || down.pointer != event.pointer) return;
    if (event is PointerMoveEvent) {
      if (_opened) {
        onMove?.call(event);
      } else if ((event.position - down.position).distance >
          computeHitSlop(event.kind, gestureSettings)) {
        resolve(GestureDisposition.rejected);
      }
    } else if (event is PointerUpEvent) {
      _open();
      onUp?.call(event);
      _reset();
    } else if (event is PointerCancelEvent) {
      if (_opened) onCancel?.call();
      resolve(GestureDisposition.rejected);
      _reset();
    }
  }

  void _reset() {
    _timer?.cancel();
    final pointer = _down?.pointer;
    _down = null;
    if (pointer != null) stopTrackingPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    if (_down?.pointer != pointer) return;
    if (_opened) onCancel?.call();
    _reset();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
  @override
  String get debugDescription => 'menu anchor press';
}

// Navigator 推送路由默认取消活跃指针。先从它的记录中释放，保留已获胜的划选手势。
void _carryMenuPointer(NavigatorState navigator, int? pointer) {
  if (pointer == null) return;
  final listener = navigator.context.findRenderObject();
  if (listener is RenderPointerListener) {
    listener.onPointerCancel?.call(PointerCancelEvent(pointer: pointer));
  }
}
