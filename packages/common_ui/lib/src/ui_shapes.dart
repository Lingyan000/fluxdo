import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 圆角形状 token：调用方写设计值，按当前主题的形状风格换算。
///
/// - 普通圆角：`设计值 × scale`，再按 [max] 封顶；
/// - 胶囊 / 圆形（设计值 ≥ [fullThreshold]，如 9999）：不缩放，只在
///   设有 [max] 时收成上限（方正风格下胶囊按钮也变直角）。
///
/// 默认 [standard] 恒等换算，外观与引入本类之前逐像素一致。宿主通过
/// `ThemeData.extensions` 注入，并同步 [current] 供拿不到 context 的
/// 绘制代码（画板、静态函数、布局缓存）使用。
@immutable
class UiShapes extends ThemeExtension<UiShapes> {
  const UiShapes({this.scale = 1.0, this.max});

  /// 恒等换算（默认圆角）。
  static const UiShapes standard = UiShapes();

  /// 当前生效的形状风格，供无 context 的代码使用；宿主在构建主题时同步。
  static UiShapes current = standard;

  /// 视为胶囊 / 圆形的设计值下限。
  static const double fullThreshold = 100;

  /// 普通圆角的缩放系数。
  final double scale;

  /// 圆角上限（含胶囊），null 表示不封顶。
  final double? max;

  bool get isStandard => scale == 1.0 && max == null;

  /// 设计值 [design] 换算后的圆角半径。
  double resolve(double design) {
    if (design >= fullThreshold) return max ?? design;
    final scaled = design * scale;
    final limit = max;
    return limit == null ? scaled : math.min(scaled, limit);
  }

  Radius radius(double design) => Radius.circular(resolve(design));

  BorderRadius borderRadius(double design) =>
      BorderRadius.circular(resolve(design));

  /// 圆形按钮 / 图标底座的形状：不封顶的风格是正圆，设有 [max] 的风格
  /// 收成圆角方（与胶囊同一规则）。头像、状态圆点等不走这里，始终是圆。
  ShapeBorder circle({BorderSide side = BorderSide.none}) {
    final limit = max;
    return limit == null
        ? CircleBorder(side: side)
        : RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(limit),
            side: side,
          );
  }

  @override
  UiShapes copyWith({double? scale, double? max}) =>
      UiShapes(scale: scale ?? this.scale, max: max ?? this.max);

  @override
  UiShapes lerp(covariant UiShapes? other, double t) {
    if (other == null) return this;
    final a = max;
    final b = other.max;
    return UiShapes(
      scale: scale + (other.scale - scale) * t,
      // 一侧不封顶时整体换档，避免从"无限"插值
      max: a == null || b == null ? (t < 0.5 ? a : b) : a + (b - a) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UiShapes && other.scale == scale && other.max == max;

  @override
  int get hashCode => Object.hash(scale, max);
}

extension UiShapesContext on BuildContext {
  /// 当前主题的形状风格；未注入时为 [UiShapes.standard]。
  UiShapes get shapes =>
      Theme.of(this).extension<UiShapes>() ?? UiShapes.standard;
}
