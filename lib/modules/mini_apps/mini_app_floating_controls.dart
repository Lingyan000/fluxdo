import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/s.dart';
import 'mini_app_dock_liquid_shape.dart';
import 'mini_app_glass_backdrop.dart';

/// 圆弧与全屏工具条共用一个可变形表面，拖动和转场均可即时接手。
class MiniAppFullscreenDock extends StatefulWidget {
  const MiniAppFullscreenDock({
    super.key,
    required this.onExit,
    required this.onMenu,
    required this.landscape,
    this.onRotate,
    this.captureBackdrop,
    this.samplingEnabled = true,
  });
  final VoidCallback onExit;
  final VoidCallback? onRotate;
  final ValueChanged<BuildContext> onMenu;
  final bool landscape;
  final MiniAppGlassCapture? captureBackdrop;
  final bool samplingEnabled;

  @override
  State<MiniAppFullscreenDock> createState() => _MiniAppFullscreenDockState();
}

class _MiniAppFullscreenDockState extends State<MiniAppFullscreenDock>
    with TickerProviderStateMixin {
  static const _hitWidth = 44.0, _height = 52.0, _edgeGap = 6.0;
  static const _verticalGap = 8.0;
  late final AnimationController _morph =
      AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 320),
          reverseDuration: const Duration(milliseconds: 260),
        )
        ..addListener(_rebuild)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _dropAmount = 0;
        });
  late final AnimationController _settle =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addListener(() {
        setState(() {
          _location = Offset.lerp(
            _snapFrom,
            _snapTo,
            Curves.easeOutCubic.transform(_settle.value),
          )!;
          final remaining = (_location.dx - _snapTo.dx).abs() * _travel.dx;
          _dropAmount =
              _snapDrop *
              math.max(
                (remaining / 36).clamp(0, 1),
                1 - Curves.easeOutCubic.transform(_settle.value),
              );
          _tail = Offset(_right ? 30 : -30, 0);
        });
      });
  Offset _location = const Offset(1, .22);
  Offset _snapFrom = Offset.zero, _snapTo = Offset.zero;
  Offset _lastPointer = Offset.zero;
  Offset _dragDistance = Offset.zero, _tail = const Offset(30, 0);
  double _dropAmount = 0, _pickupDrop = 0, _snapDrop = 0;
  Size _area = Size.zero;
  bool _right = true, _expanded = false, _dragging = false, _pressed = false;
  Timer? _hideTimer;
  final _toneTracker = SurfaceToneTracker();
  late final _tone = AnimationController(
    vsync: this,
    value: .5,
    duration: const Duration(milliseconds: 240),
  )..addListener(_rebuild);

  void _sampleColor(SurfaceColorSample sample) {
    if (!_toneTracker.update(sample.luminance)) return;
    final target = _toneTracker.darkInk ? 1.0 : 0.0;
    if (_reduced) {
      _tone.value = target;
    } else {
      _tone.animateTo(target, curve: Curves.easeInOut);
    }
  }

  double get _progress => Curves.easeInOutCubic.transform(_morph.value);
  double get _menuWidth => math.min(
    widget.onRotate == null ? 104.0 : 152.0,
    math.max(_hitWidth, _area.width - 2 * _edgeGap),
  );
  double get _surfaceWidth => ui.lerpDouble(_hitWidth, _menuWidth, _progress)!;
  Offset get _travel => Offset(
    math.max(0, _area.width - _hitWidth - 2 * _edgeGap),
    math.max(0, _area.height - _height - 2 * _verticalGap),
  );
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  void _rebuild() => setState(() {});

  Offset _bounded(Offset value) {
    final travel = _travel;
    final extra = travel.dx == 0
        ? 0.0
        : ((_surfaceWidth - _hitWidth) / travel.dx).clamp(0.0, 1.0);
    return Offset(
      value.dx.clamp(_right ? extra : 0, _right ? 1 : 1 - extra),
      value.dy.clamp(0, 1),
    );
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_expanded && !_pressed) {
      _hideTimer = Timer(const Duration(seconds: 4), () => _expand(false));
    }
  }

  void _continueMorph() {
    if (_reduced) {
      _morph.value = _expanded ? 1 : 0;
    } else {
      _expanded ? _morph.forward() : _morph.reverse();
    }
  }

  void _expand(bool value) {
    _hideTimer?.cancel();
    setState(() => _expanded = value);
    _continueMorph();
    _scheduleHide();
  }

  void _hold(DragDownDetails details) {
    // 按下即停在当前帧，不等待识别成拖动后才接手吸附/变形动画。
    _settle.stop();
    _morph.stop();
    _hideTimer?.cancel();
    _pressed = true;
    _lastPointer = details.globalPosition;
    _dragDistance = Offset.zero;
    _pickupDrop = _dropAmount;
    setState(() {});
  }

  void _drag(DragUpdateDetails details) {
    // 使用屏幕坐标差，控件自身移动不改变下一帧的手指位移。
    // 每帧更新基点，碰到边界后反向移动不会积累一段无效拖动。
    final delta = details.globalPosition - _lastPointer;
    _lastPointer = details.globalPosition;
    final travel = _travel;
    setState(() {
      _location = _bounded(
        _bounded(_location) +
            Offset(
              travel.dx == 0 ? 0 : delta.dx / travel.dx,
              travel.dy == 0 ? 0 : delta.dy / travel.dy,
            ),
      );
      if (_progress < .01 && !_reduced) {
        _dragDistance += delta;
        _dropAmount = math.max(
          _pickupDrop,
          (_dragDistance.distance / 48).clamp(0, 1),
        );
        // 靠边拉出时尾部指向原位；脱离后只保留柔和的运动拖尾。
        final target = -_dragDistance;
        _tail = target.distance < 40
            ? target
            : Offset.lerp(_tail, -delta * 5, .38)!;
      }
    });
  }

  void _release() {
    if (!_pressed) return;
    _pressed = false;
    setState(() => _dragging = false);
    _snap();
    _continueMorph();
    _scheduleHide();
  }

  void _snap() {
    var current = _bounded(_location);
    final extra = _surfaceWidth - _hitWidth;
    final left = _edgeGap + current.dx * _travel.dx - (_right ? extra : 0);
    final right = left + _surfaceWidth / 2 >= _area.width / 2;
    if (right != _right && _travel.dx > 0) {
      // 展开时换边保持整块菜单的位置，避免改锚点造成跳跃。
      current = Offset(
        ((left + (right ? extra : 0) - _edgeGap) / _travel.dx).clamp(0, 1),
        current.dy,
      );
    }
    setState(() {
      _right = right;
      _location = current;
    });
    _snapFrom = current;
    _snapTo = Offset(_right ? 1 : 0, current.dy);
    _snapDrop = _dropAmount;
    if (_reduced ||
        ((_snapFrom - _snapTo).distance < .001 && _dropAmount == 0)) {
      setState(() {
        _location = _snapTo;
        _dropAmount = 0;
      });
    } else {
      _settle.forward(from: 0);
    }
  }

  void _moveVertically(double delta) {
    _settle.stop();
    setState(() {
      _location = _bounded(
        _location + Offset(0, _travel.dy == 0 ? 0 : delta / _travel.dy),
      );
    });
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _settle.dispose();
    _morph.dispose();
    _tone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final media = MediaQuery.of(context);
    final glass = GlassSettingsScope.of(context)
        .allowsBlur(highContrast: media.highContrast);
    return LayoutBuilder(
      builder: (context, constraints) {
        _area = constraints.biggest;
        final p = _progress;
        final location = _bounded(_location);
        final width = _surfaceWidth;
        final left =
            _edgeGap +
            location.dx * _travel.dx -
            (_right ? width - _hitWidth : 0);
        final top = _verticalGap + location.dy * _travel.dy;
        final size = Size(width, _height);
        final arc = insetMiniAppArc(
          _DockMorphShape(
            progress: p,
            right: _right,
          ).getOuterPath(Offset.zero & size),
          size,
          p,
          _right,
        );
        final drop = _dropAmount * (1 - p);
        final shape = drop > 0
            ? MiniAppDockLiquidShape(
                arc: arc,
                size: size,
                amount: drop,
                tail: _tail,
              )
            : MiniAppDockLiquidShape.outline(arc);
        final materialProgress = math.max(p, drop);
        final icons = const Interval(
          .42,
          1,
          curve: Curves.easeOut,
        ).transform(p);
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              _expanded ? _expand(false) : widget.onExit();
            },
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                height: _height,
                child: TapRegion(
                  onTapOutside: (_) {
                    if (!_pressed) _expand(false);
                  },
                  child: MediaQuery(
                    data: media.copyWith(
                      // 仅把手使用更小的拖动阈值，不改变游戏自身的手势策略。
                      gestureSettings: const DeviceGestureSettings(
                        touchSlop: 4,
                      ),
                    ),
                    child: Semantics(
                      button: true,
                      label: _expanded
                          ? l.miniApp_hideControls
                          : l.miniApp_showControls,
                      onIncrease: () => _moveVertically(-48),
                      onDecrease: () => _moveVertically(48),
                      child: GestureDetector(
                        key: const ValueKey('mini-app-fullscreen-dock'),
                        behavior: HitTestBehavior.opaque,
                        dragStartBehavior: DragStartBehavior.down,
                        onPanDown: _hold,
                        onPanStart: (_) => setState(() => _dragging = true),
                        onPanUpdate: _drag,
                        onPanEnd: (_) => _release(),
                        onPanCancel: _release,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _expand(!_expanded);
                        },
                        child: CustomPaint(
                          key: const ValueKey('mini-app-show-controls'),
                          painter: _DockEdgePainter(
                            shape: shape,
                            progress: materialProgress,
                            glass: glass,
                            active: _expanded || _dragging,
                            ink: _tone.value,
                          ),
                          foregroundPainter: _DockEdgePainter(
                            shape: shape,
                            progress: materialProgress,
                            glass: glass,
                            active: _expanded || _dragging,
                            rim: true,
                            rimContrast: 1 - p,
                            ink: _tone.value,
                            dark:
                                Theme.of(context).brightness == Brightness.dark,
                          ),
                          child: ClipPath(
                            clipper: ShapeBorderClipper(shape: shape),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (widget.captureBackdrop != null)
                                  MiniAppGlassBackdrop(
                                    capture: widget.captureBackdrop!,
                                    enabled:
                                        widget.samplingEnabled &&
                                        !_pressed &&
                                        !_settle.isAnimating,
                                    showBackdrop: glass && materialProgress > 0,
                                    onSample: _sampleColor,
                                  ),
                                if (materialProgress > 0)
                                  Opacity(
                                    opacity: const Interval(
                                      0,
                                      .6,
                                    ).transform(materialProgress),
                                    child: GlassSurface(
                                      key: const ValueKey(
                                        'mini-app-dock-glass',
                                      ),
                                      recipe: p > 0
                                          ? GlassRecipe.toolbar
                                          : GlassRecipe.navigation,
                                      shape: shape,
                                      opticalShape: const StadiumBorder(),
                                      drawFallbackBorder: false,
                                      drawOpticalBorder: false,
                                    ),
                                  ),
                                if (p > 0)
                                  IgnorePointer(
                                    ignoring: !_expanded || p < .7 || _dragging,
                                    child: ExcludeSemantics(
                                      excluding: !_expanded || p < .7,
                                      child: Opacity(
                                        opacity: icons,
                                        child: ImageFiltered(
                                          enabled:
                                              icons < .999 &&
                                              !media.disableAnimations,
                                          imageFilter: ui.ImageFilter.blur(
                                            sigmaX: 2.5 * (1 - icons),
                                            sigmaY: 2.5 * (1 - icons),
                                          ),
                                          child: OverflowBox(
                                            minWidth: _menuWidth,
                                            maxWidth: _menuWidth,
                                            alignment: _right
                                                ? Alignment.centerRight
                                                : Alignment.centerLeft,
                                            child: Material(
                                              type: MaterialType.transparency,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 4,
                                                    ),
                                                child: Row(
                                                  children: [
                                                    if (widget.onRotate != null)
                                                      Expanded(
                                                        child: IconButton(
                                                          key: const ValueKey(
                                                            'mini-app-rotate',
                                                          ),
                                                          tooltip:
                                                              widget.landscape
                                                              ? l.miniApp_portrait
                                                              : l.miniApp_landscape,
                                                          onPressed: () {
                                                            _expand(false);
                                                            widget.onRotate!();
                                                          },
                                                          icon: const Icon(
                                                            Symbols
                                                                .screen_rotation_rounded,
                                                            size: 21,
                                                          ),
                                                        ),
                                                      ),
                                                    Expanded(
                                                      child: IconButton(
                                                        key: const ValueKey(
                                                          'mini-app-fullscreen-exit',
                                                        ),
                                                        tooltip: l
                                                            .miniApp_exitFullscreen,
                                                        onPressed:
                                                            widget.onExit,
                                                        icon: const Icon(
                                                          Symbols
                                                              .fullscreen_exit_rounded,
                                                          size: 23,
                                                        ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: Builder(
                                                        builder: (anchor) =>
                                                            IconButton(
                                                              key:
                                                                  const ValueKey(
                                                                    'mini-app-menu-button',
                                                                  ),
                                                              tooltip: l
                                                                  .miniApp_more,
                                                              onPressed: () {
                                                                widget.onMenu(
                                                                  anchor,
                                                                );
                                                                _expand(false);
                                                              },
                                                              icon: const Icon(
                                                                Symbols
                                                                    .more_horiz_rounded,
                                                                size: 23,
                                                              ),
                                                            ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 用同一轮廓把圆弧内凹面逐渐展开为胶囊的外凸面，端点始终圆润。
class _DockMorphShape extends ShapeBorder {
  const _DockMorphShape({required this.progress, required this.right});
  final double progress;
  final bool right;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
  @override
  ShapeBorder scale(double t) => this;
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final p = progress;
    final radius = ui.lerpDouble(19.75, 24, p)!;
    final bend = ui.lerpDouble(-14.25, 24, p)!;
    // 圆头逐渐转为胶囊的四分之一圆角，共用切线，过零时也没有直角或尾巴。
    final angle = 3 * math.pi / 4 * p;
    final tangent = Offset(-math.cos(angle), -math.sin(angle));
    final arcHandle = radius * 4 / 3 * math.tan(math.pi / 16);
    final capHandle = ui.lerpDouble(2.75 * 4 / 3, arcHandle, p)!;
    final innerHandle = ui.lerpDouble(14.25 * .5522847498, arcHandle, p)!;
    final joinX = radius / math.sqrt2 * p;
    final joinY = ui.lerpDouble(14.25, radius / math.sqrt2, p)!;
    final extent = math.max(
      bend,
      math.max(capHandle, joinX + math.max(0, -tangent.dx) * capHandle),
    );
    final width = rect.width - 21.5 * (1 - p);
    final end = width - extent;
    final join = Offset(end + joinX, joinY);
    final capControl = join - tangent * capHandle;
    final innerControl = join + tangent * innerHandle;
    final path = Path()
      ..moveTo(radius, -radius)
      ..arcTo(
        Rect.fromCircle(center: Offset(radius, 0), radius: radius),
        -math.pi / 2,
        -math.pi,
        false,
      )
      ..lineTo(end, radius);
    path
      ..cubicTo(
        end + capHandle,
        radius,
        capControl.dx,
        capControl.dy,
        join.dx,
        join.dy,
      )
      ..cubicTo(
        innerControl.dx,
        innerControl.dy,
        end + bend,
        innerHandle,
        end + bend,
        0,
      )
      ..cubicTo(
        end + bend,
        -innerHandle,
        innerControl.dx,
        -innerControl.dy,
        join.dx,
        -join.dy,
      )
      ..cubicTo(
        capControl.dx,
        -capControl.dy,
        end + capHandle,
        -radius,
        end,
        -radius,
      )
      ..lineTo(radius, -radius)
      ..close();
    final positioned = path.shift(Offset(13.5 * (1 - p), rect.height / 2));
    if (right) return positioned.shift(rect.topLeft);
    return positioned
        .transform(
          (Matrix4.identity()
                ..translateByDouble(rect.width, 0, 0, 1)
                ..scaleByDouble(-1, 1, 1, 1))
              .storage,
        )
        .shift(rect.topLeft);
  }
}

class _DockEdgePainter extends CustomPainter {
  const _DockEdgePainter({
    required this.shape,
    required this.progress,
    required this.glass,
    required this.active,
    this.rim = false,
    this.dark = false,
    this.rimContrast = 0,
    this.ink = .5,
  });
  final ShapeBorder shape;
  final double progress;
  final double rimContrast;
  final double ink;
  final bool glass, active, rim, dark;

  @override
  void paint(Canvas canvas, Size size) {
    final path = shape.getOuterPath(Offset.zero & size);
    final p = progress;
    final tint = Color.lerp(
      AdaptiveSurfaceColors.lightInk,
      AdaptiveSurfaceColors.darkInk,
      ink,
    )!;
    if (rim) {
      // 只保留一层随背景明暗变化的柔和轮廓，不再叠黑白双描边。
      final edge = Color.lerp(Colors.white, tint, rimContrast)!;
      final strength = ui.lerpDouble(dark ? .20 : .55, .68, rimContrast)!;
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              edge.withValues(alpha: strength),
              edge.withValues(
                alpha: strength * ui.lerpDouble(.12, .65, rimContrast)!,
              ),
              edge.withValues(
                alpha: strength * ui.lerpDouble(.5, .85, rimContrast)!,
              ),
            ],
          ).createShader(Offset.zero & size)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .65,
      );
      return;
    }
    canvas.drawShadow(
      path,
      Colors.black.withValues(alpha: .12 * (1 - ink)),
      2,
      true,
    );
    if (p >= 1) return;
    // 收拢后只画弧线，不持续对游戏做背景滤镜；展开才接入公共玻璃材质。
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: glass
              ? [
                  tint.withValues(alpha: .58),
                  tint.withValues(alpha: .28),
                  tint.withValues(alpha: active ? .60 : .46),
                ]
              : [tint.withValues(alpha: .85), tint.withValues(alpha: .85)],
        ).createShader(Offset.zero & size)
        ..color = Colors.white.withValues(alpha: 1 - p),
    );
  }

  @override
  bool shouldRepaint(_DockEdgePainter oldDelegate) =>
      shape != oldDelegate.shape ||
      progress != oldDelegate.progress ||
      rimContrast != oldDelegate.rimContrast ||
      ink != oldDelegate.ink ||
      glass != oldDelegate.glass ||
      rim != oldDelegate.rim ||
      dark != oldDelegate.dark ||
      active != oldDelegate.active;
}
