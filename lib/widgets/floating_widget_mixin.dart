import 'package:flutter/material.dart';

/// 可拖拽吸附浮窗的通用 mixin
///
/// 提供拖拽、松手吸附到屏幕边缘、屏幕旋转自适应等核心能力。
/// 使用方需要 `with TickerProviderStateMixin` 并在 initState/dispose 中
/// 调用 [initFloating] / [disposeFloating]。
///
/// 子类通过覆写 [floatingOverlap]、[floatingBottomMargin]、[floatingTopMargin]
/// 和 [initialRelativeY]、[initialRight] 来定制行为。
mixin FloatingWidgetMixin<T extends StatefulWidget> on State<T>, TickerProviderStateMixin<T> {

  // ─── 子类可覆写的配置 ─────────────────────────────────────────

  /// 吸附时超出屏幕边缘的像素数
  double get floatingOverlap => 20.0;

  /// Y 轴上方安全边距（加上状态栏）
  double get floatingTopMargin => 50.0;

  /// Y 轴下方安全边距（加上底部安全区）
  double get floatingBottomMargin => 50.0;

  /// 初始 Y 位置比例 (0.0 = 顶部, 1.0 = 底部)
  double get initialRelativeY => 0.5;

  /// 初始吸附在右侧
  bool get initialRight => true;

  // ─── 状态 ─────────────────────────────────────────────────────

  late AnimationController floatingAnimController;
  late Animation<Offset> _floatingAnimation;

  Offset floatingOffset = Offset.zero;
  bool floatingIsAdsorbed = false;
  bool floatingIsInitialized = false;
  bool floatingIsRight = true;

  /// Y 位置占可用高度的比例 (0.0~1.0)，屏幕旋转时保持
  double _floatingRelativeY = 0.5;

  Size _floatingScreenSize = Size.zero;
  EdgeInsets _floatingPadding = EdgeInsets.zero;

  // ─── 生命周期 ──────────────────────────────────────────────────

  void initFloating() {
    _floatingRelativeY = initialRelativeY;
    floatingIsRight = initialRight;

    floatingAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    floatingAnimController.addListener(() {
      setState(() {
        floatingOffset = _floatingAnimation.value;
      });
    });
    floatingAnimController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _saveRelativePosition();
        setState(() {
          floatingIsAdsorbed = true;
        });
      }
    });
  }

  void disposeFloating() {
    floatingAnimController.dispose();
  }

  /// 在 didChangeDependencies 中调用，处理屏幕尺寸变化
  void updateFloatingDependencies() {
    final newSize = MediaQuery.of(context).size;
    final newPadding = MediaQuery.of(context).padding;
    final sizeChanged = _floatingScreenSize != Size.zero && _floatingScreenSize != newSize;

    _floatingScreenSize = newSize;
    _floatingPadding = newPadding;

    if (!floatingIsInitialized) {
      final target = _absoluteFromRelative();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          floatingOffset = target;
          floatingIsAdsorbed = true;
          floatingIsInitialized = true;
        });
      });
      return;
    }

    if (sizeChanged) {
      if (floatingIsAdsorbed) {
        floatingOffset = _absoluteFromRelative();
      } else {
        // 非吸附态(拖拽刚松手/吸附动画途中)撞上尺寸剧变(折叠屏
        // 折叠):无条件把当前位置 clamp 进新屏幕范围,否则浮球可能
        // 停在屏外够不着。
        final maxX = newSize.width - _getFloatingWidth();
        final maxY = newSize.height - newPadding.bottom - 50;
        floatingOffset = Offset(
          floatingOffset.dx.clamp(0.0, maxX < 0 ? 0.0 : maxX),
          floatingOffset.dy.clamp(newPadding.top, maxY < newPadding.top ? newPadding.top : maxY),
        );
      }
    }
  }

  // ─── 拖拽手势 ──────────────────────────────────────────────────

  void onFloatingPanStart(DragStartDetails details) {
    floatingAnimController.stop();
    if (floatingIsAdsorbed) {
      final screenWidth = _floatingScreenSize.width;
      final selfWidth = _getFloatingWidth();
      double currentLeft;
      if (floatingIsRight) {
        currentLeft = screenWidth - selfWidth + floatingOverlap;
      } else {
        currentLeft = -floatingOverlap;
      }
      setState(() {
        floatingOffset = Offset(currentLeft, floatingOffset.dy);
        floatingIsAdsorbed = false;
      });
    }
  }

  void onFloatingPanUpdate(DragUpdateDetails details) {
    setState(() {
      floatingOffset += details.delta;
    });
  }

  void onFloatingPanEnd(DragEndDetails details) {
    _animateToEdge(details.velocity.pixelsPerSecond);
  }

  // ─── 位置计算 ──────────────────────────────────────────────────

  /// 获取浮窗自身宽度（子类可覆写，Pill 用 RenderBox 获取）
  double _getFloatingWidth() {
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    return renderBox?.size.width ?? 50;
  }

  double _getFloatingHeight() {
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    return renderBox?.size.height ?? 50;
  }

  void _saveRelativePosition() {
    final minY = _floatingPadding.top + floatingTopMargin;
    final selfHeight = _getFloatingHeight();
    final maxY = _floatingScreenSize.height - selfHeight - _floatingPadding.bottom - floatingBottomMargin;
    final range = maxY - minY;
    if (range > 0) {
      _floatingRelativeY = ((floatingOffset.dy - minY) / range).clamp(0.0, 1.0);
    }
    floatingIsRight = floatingOffset.dx > (_floatingScreenSize.width / 2);
  }

  Offset _absoluteFromRelative() {
    final selfWidth = _getFloatingWidth();
    final selfHeight = _getFloatingHeight();
    final minY = _floatingPadding.top + floatingTopMargin;
    final maxY = _floatingScreenSize.height - selfHeight - _floatingPadding.bottom - floatingBottomMargin;
    final y = minY + _floatingRelativeY * (maxY - minY);
    final x = floatingIsRight
        ? _floatingScreenSize.width - selfWidth + floatingOverlap
        : -floatingOverlap;
    return Offset(x, y);
  }

  Offset calculateFloatingTarget() {
    final selfWidth = _getFloatingWidth();
    final selfHeight = _getFloatingHeight();
    final double screenWidth = _floatingScreenSize.width;
    final currentCenterX = floatingOffset.dx + selfWidth / 2;

    double targetX;
    if (currentCenterX < screenWidth / 2) {
      targetX = -floatingOverlap;
    } else {
      targetX = screenWidth - selfWidth;
    }

    double targetY = floatingOffset.dy;
    final double topLimit = _floatingPadding.top + floatingTopMargin;
    final double bottomLimit = _floatingScreenSize.height - selfHeight - _floatingPadding.bottom - floatingBottomMargin;

    if (targetY < topLimit) targetY = topLimit;
    if (targetY > bottomLimit) targetY = bottomLimit;

    return Offset(targetX, targetY);
  }

  void _animateToEdge(Offset velocity) {
    final target = calculateFloatingTarget();
    _floatingAnimation = Tween<Offset>(
      begin: floatingOffset,
      end: target,
    ).animate(CurvedAnimation(parent: floatingAnimController, curve: Curves.easeOutBack));
    floatingAnimController.forward(from: 0);
  }

  // ─── 布局辅助 ──────────────────────────────────────────────────

  /// 构建 Positioned 的定位参数
  ({double? left, double? right, double top}) floatingPosition() {
    final top = floatingOffset.dy;
    if (floatingIsAdsorbed) {
      if (floatingIsRight) {
        return (left: null, right: -floatingOverlap, top: top);
      } else {
        return (left: -floatingOverlap, right: null, top: top);
      }
    }
    return (left: floatingOffset.dx, right: null, top: top);
  }
}
