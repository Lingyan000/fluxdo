import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../utils/motion_springs.dart';

/// 社区前景只有这一份位移；拖动、吸附和反向操作共用同一个控制器。
class MiniAppSheetController extends ChangeNotifier {
  MiniAppSheetController(TickerProvider vsync)
    : _animation = AnimationController.unbounded(vsync: vsync) {
    _animation.addListener(notifyListeners);
  }
  final AnimationController _animation;
  Completer<void>? _opened;
  double extent = 1;
  double refreshExtent = 116;
  bool reduceMotion = false, expressive = true;
  bool visited = false,
      dragging = false,
      armed = false,
      refreshArmed = false,
      refreshing = false;
  double _pullVelocity = 0;
  double _target = 0, _heldVelocity = 0, _dragOrigin = 0;
  bool _holding = false, _directDrag = false;
  bool _feedbackVisible = true;
  int _motion = 0;
  bool _disposed = false;

  bool get isOpen => _opened != null;
  double get offset => _animation.value.clamp(0, extent);
  RefreshRevealGeometry get _geometry => RefreshRevealGeometry(
    viewportExtent: extent,
    topInset: 0,
    contentExtent: refreshExtent,
  );
  double get galleryOpacity =>
      refreshing ? 0 : _geometry.revealProgress(offset);
  // 后页从轻微收拢、蒙色逐步恢复到原尺寸；所有视觉都由同一位移驱动。
  double get galleryExpansion => Curves.easeInOut.transform(
    ((offset - _geometry.revealStart) /
            (extent - _geometry.revealStart).clamp(1.0, double.infinity))
        .clamp(0, 1),
  );
  double get feedbackOpacity => !_feedbackVisible
      ? 0
      : 1 -
            Curves.easeInOut.transform(
              ((offset - _geometry.secondaryExtent) /
                      ((extent - _geometry.secondaryExtent) * .65).clamp(
                        80.0,
                        260.0,
                      ))
                  .clamp(0, 1),
            );
  bool get galleryActive => isOpen || galleryOpacity > 0;

  void reveal(RefreshRevealNotification event) {
    if (isOpen) return;
    final wasDragging = dragging;
    final wasRefreshing = refreshing;
    dragging = event.dragging;
    armed = event.armed;
    refreshArmed = event.refreshArmed;
    refreshing = event.refreshing;
    if (dragging) {
      _feedbackVisible = true;
      final distance = event.progress * 168;
      final geometry =
          event.geometry ??
          RefreshRevealGeometry(viewportExtent: extent, topInset: 0);
      refreshExtent = geometry.refreshExtent;
      _pullVelocity = event.velocity * geometry.velocityFactor(distance);
      _motion++;
      _animation.value = geometry.offsetFor(distance).clamp(0, extent);
      // 深拉就挂载真实广场；普通刷新不创建页面，也不请求应用目录。
      if (galleryOpacity > 0) visited = true;
    } else if (wasDragging || wasRefreshing != refreshing) {
      _settle(
        refreshing ? refreshExtent : 0,
        wasDragging ? _pullVelocity : _animation.velocity,
      );
    }
    notifyListeners();
  }

  Future<void> open() {
    final velocity = isOpen ? _animation.velocity : _pullVelocity;
    _opened ??= Completer<void>();
    final future = _opened!.future;
    visited = true;
    _feedbackVisible = dragging;
    dragging = false;
    _settle(extent, velocity);
    return future;
  }

  void close() {
    _feedbackVisible = false;
    _settle(0, _animation.velocity);
  }

  /// 保留屏幕上的位移，将二楼会话交回两段式刷新；不重播归零动画。
  void resumePull() {
    _motion++;
    _animation.stop();
    _target = _heldVelocity = _pullVelocity = 0;
    _holding = _directDrag = false;
    final opened = _opened;
    _opened = null;
    opened?.complete();
    notifyListeners();
  }

  /// 设置关闭手势时立即恢复首页，结束旧的二楼会话。
  void reset() {
    _motion++;
    _animation.stop();
    _target = _pullVelocity = _heldVelocity = 0;
    _holding = _directDrag = dragging = armed = refreshArmed = refreshing =
        false;
    final opened = _opened;
    _opened = null;
    _animation.value = 0;
    opened?.complete();
    notifyListeners();
  }

  /// 按下就接住正在运动的页面，点击/手势取消时继续原来的目标。
  void holdMotion() {
    if (!isOpen || !_animation.isAnimating) return;
    _heldVelocity = _animation.velocity;
    _motion++;
    _animation.stop();
    _holding = true;
    notifyListeners();
  }

  void beginCloseDrag() {
    holdMotion();
    _motion++;
    _animation.stop();
    _holding = false;
    _directDrag = true;
    _feedbackVisible = false;
    _dragOrigin = offset;
    notifyListeners();
  }

  void updateCloseDrag(double delta) {
    if (!_directDrag) return;
    _animation.value = (offset + delta).clamp(0, extent);
  }

  void endCloseDrag(double velocity) {
    final travel = offset - _dragOrigin;
    // 已进入广场后按本次意图吸附，短距离反向滑动也能撤销前一次开关。
    // 不再要求从全屏拖回固定的 78% 位置才能关闭。
    final target = velocity.abs() >= 500
        ? (velocity > 0 ? extent : 0.0)
        : travel.abs() >= 36
        ? (travel > 0 ? extent : 0.0)
        : _target;
    _settle(target, velocity);
  }

  void cancelCloseDrag() {
    if (!_holding && !_directDrag) return;
    _settle(_target, _holding ? _heldVelocity : 0);
  }

  void resize(double newExtent) {
    if (extent == newExtent) return;
    final wasAtOpen = _target > 0;
    extent = newExtent;
    if (isOpen) _settle(wasAtOpen ? extent : 0, _animation.velocity);
  }

  Future<void> _settle(double target, double velocity) async {
    final motion = ++_motion;
    _target = target;
    _holding = false;
    _directDrag = false;
    try {
      if (reduceMotion) {
        _animation.value = target;
      } else if (!expressive) {
        final animation = _animation.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
        notifyListeners();
        await animation.orCancel;
      } else {
        final animation = _animation.animateWith(
          SpringSimulation(
            isOpen
                ? SpringDescription.withDampingRatio(
                    mass: 1,
                    stiffness: M3eMotion.defaultSpatial.stiffness,
                    ratio: 1,
                  )
                : kHeaderSpringDescription,
            _animation.value,
            target,
            velocity.clamp(-2400, 2400),
            tolerance: const Tolerance(distance: .5, velocity: 10),
          ),
        );
        notifyListeners();
        await animation.orCancel;
      }
      // 被接管的动画即便已经完成 Future，也不能执行迟到的收尾。
      if (_disposed || motion != _motion) return;
      _animation.value = target;
      if (target == 0 && isOpen) {
        final opened = _opened!;
        _opened = null;
        dragging = armed = refreshArmed = refreshing = false;
        opened.complete();
      }
      notifyListeners();
    } on TickerCanceled {
      // 新手势或新目标已取得位移所有权。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _opened?.complete();
    _animation.dispose();
    super.dispose();
  }
}
