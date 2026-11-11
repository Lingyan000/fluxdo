import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 标签页选中标记：标签下方居中的一小段短横。
class ShortBarTabIndicator extends Decoration {
  const ShortBarTabIndicator({
    required this.color,
    this.width = 18,
    this.thickness = 2,
  });

  final Color color;
  final double width;
  final double thickness;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _ShortBarPainter(this);
}

class _ShortBarPainter extends BoxPainter {
  _ShortBarPainter(this.decoration);

  final ShortBarTabIndicator decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final w = math.min(decoration.width, size.width);
    final rect = Rect.fromLTWH(
      offset.dx + (size.width - w) / 2,
      offset.dy + size.height - decoration.thickness,
      w,
      decoration.thickness,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(decoration.thickness)),
      Paint()..color = decoration.color,
    );
  }
}

/// 导航选中标记的形状：只在指示区底部居中画一段短横（其余透明）。
///
/// 底部导航把指示器当成 `ShapeDecoration` 填充；用这个形状替换胶囊后，
/// 填充的只有短横本身，滑动动画、位置计算都不用改。
class ShortBarIndicatorShape extends OutlinedBorder {
  const ShortBarIndicatorShape({
    this.width = 16,
    this.thickness = 3,
    super.side,
  });

  final double width;
  final double thickness;

  Rect _bar(Rect rect) {
    final w = math.min(width, rect.width);
    return Rect.fromLTWH(
      rect.center.dx - w / 2,
      rect.bottom - thickness,
      w,
      thickness,
    );
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(_bar(rect), Radius.circular(thickness / 2)),
    );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShortBarIndicatorShape copyWith({BorderSide? side}) => ShortBarIndicatorShape(
    width: width,
    thickness: thickness,
    side: side ?? this.side,
  );

  @override
  ShapeBorder scale(double t) => ShortBarIndicatorShape(
    width: width * t,
    thickness: thickness * t,
    side: side.scale(t),
  );

  @override
  bool operator ==(Object other) =>
      other is ShortBarIndicatorShape &&
      other.width == width &&
      other.thickness == thickness &&
      other.side == side;

  @override
  int get hashCode => Object.hash(width, thickness, side);
}
