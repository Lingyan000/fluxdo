// AppIcon —— 统一图标渲染 widget。
//
// 用法：
//   AppIcon(AppIcons.close)                          // 字体图标
//   AppIcon(AppIcons.bookmark, fill: 1)              // 字体图标 + fill 切换
//   AppIcon(AppIcons.smileyOutline, fill: 1)         // 自绘图标 + fill 切换
//
// IconData 也能直接当 AppIconSpec 用（隐式转换由 `IconDataToSpec.asSpec` 提供，
// 或者更省事 —— [AppIcon] 的构造函数同时接受 `IconData`/`AppIconSpec`，自动适配）。
//
// 全局默认参数由 [IconTheme] 决定（main.dart 注入 fill=0、weight=400、size=24）。
import 'package:material_ui/material_ui.dart';

import 'app_icons.dart';

class AppIcon extends StatelessWidget {
  /// 接受 [IconData]（字体图标）或 [AppIconSpec]（含自绘）。
  final Object icon;

  /// 0..1。null 时跟随 [IconTheme]（默认 0）。
  final double? fill;

  /// null 时跟随 [IconTheme]（默认 24）。
  final double? size;

  /// null 时跟随 [IconTheme]。
  final Color? color;

  /// 自绘 painter 的笔画粗细。仅自绘图标生效。
  final double strokeWidth;

  /// 透传 [Icon.semanticLabel]。
  final String? semanticLabel;

  const AppIcon(
    this.icon, {
    super.key,
    this.fill,
    this.size,
    this.color,
    this.strokeWidth = 2.0,
    this.semanticLabel,
  }) : assert(
          icon is IconData || icon is AppIconSpec,
          'AppIcon.icon must be IconData or AppIconSpec',
        );

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final effectiveSize = size ?? theme.size ?? 24;
    final effectiveColor = color ?? theme.color ?? Colors.black;
    final effectiveFill = fill ?? theme.fill ?? 0;

    final spec = icon is IconData
        ? AppFontIcon(icon as IconData)
        : icon as AppIconSpec;

    return switch (spec) {
      AppFontIcon(:final data) => Icon(
          data,
          size: effectiveSize,
          color: effectiveColor,
          fill: effectiveFill,
          semanticLabel: semanticLabel,
        ),
      AppCustomIcon(:final painterBuilder, :final designSize) => SizedBox(
          width: effectiveSize,
          height: effectiveSize * designSize.height / designSize.width,
          child: CustomPaint(
            painter: painterBuilder(
              color: effectiveColor,
              fill: effectiveFill,
              strokeWidth: strokeWidth,
            ),
            size: Size(
              effectiveSize,
              effectiveSize * designSize.height / designSize.width,
            ),
          ),
        ),
    };
  }
}
