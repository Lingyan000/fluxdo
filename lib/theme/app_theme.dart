import 'package:common_ui/common_ui.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../providers/theme_provider.dart';
import '../widgets/common/fullscreen_swipe_back.dart';
import 'app_colors.dart';
import 'shape_presets.dart';

/// Material Symbols 全局轴默认：fill=0 走线框，weight/grade/opticalSize
/// 给出与现有视觉匹配的中性值。状态类图标需在使用处显式传 `fill: 1`。
IconThemeData _appIconTheme(Color color) => IconThemeData(
  color: color,
  size: 24,
  fill: 0,
  weight: 400,
  grade: 0,
  opticalSize: 24,
);

/// 页面转场:框架在 Android 的默认(PredictiveBack,常规导航兜底到
/// FadeForwards)是入场/离场两页各套一个整页 FadeTransition —— Impeller
/// 下每个半透明整页 = 一次全屏 saveLayer 离屏,且 Impeller 没有 Skia 的
/// raster cache,转场每帧都在重光栅化两个页面。详情页↔列表页这种复杂
/// 内容在 120Hz(8.3ms 预算)下每帧 raster 10~50ms,整段转场连串掉帧
/// (诊断日志里 NAV 后成串的纯 raster 大帧,即"一般场景动不动抽")。
/// 统一换 Cupertino 滑动转场:纯平移 + 边缘阴影,零整页 saveLayer。
/// Android 用拷贝改造的 PredictiveBackCupertinoPageTransitionsBuilder:
/// 系统预测返回手势保留原生 shared-element 预览,其余导航(push/按钮
/// 返回)降级到 Cupertino 而非官方硬编码的 FadeForwards。
const _pageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: InterruptiblePageTransitionsBuilder(
      PredictiveBackCupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.iOS: InterruptiblePageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.macOS: InterruptiblePageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.windows: InterruptiblePageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.linux: InterruptiblePageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
  },
);

/// 「全屏侧滑返回」开启时的转场:移动端在原转场树里追加整页 iOS 式
/// 返回手势(转场视觉不变,仅扩大手势探测区);桌面端保持边缘手势。
const _fullscreenSwipePageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: InterruptiblePageTransitionsBuilder(
      FullscreenSwipeBackTransitionsBuilder(
        PredictiveBackCupertinoPageTransitionsBuilder(),
      ),
    ),
    TargetPlatform.iOS: InterruptiblePageTransitionsBuilder(
      FullscreenSwipeBackTransitionsBuilder(CupertinoPageTransitionsBuilder()),
    ),
    TargetPlatform.macOS: InterruptiblePageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.windows: InterruptiblePageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.linux: InterruptiblePageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
  },
);

/// M3E 按钮按压形变,参数对照 Compose ButtonSmallTokens 标准:
/// ContainerShapeRound = CornerFull(Stadium)→ PressedContainerShape =
/// CornerSmall(8dp)。形状插值由 Material 内部 ImplicitlyAnimatedWidget
/// 完成,theme 注入全局生效;时长对齐规格用的 DefaultEffects 弹簧
/// (spring(1.0, 1600) 收敛 ≈180ms,规格注释明确"不允许过冲",
/// Material 的 fastOutSlowIn 曲线正好同为无过冲缓动)。
ButtonStyle _m3ePressedShapeStyle(UiShapes shapes) => ButtonStyle(
  animationDuration: const Duration(milliseconds: 180),
  shape: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.pressed)
        ? RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(8))
        : RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(shapes.radius(9999)),
          ),
  ),
);

/// IconButton 版本:在按压形变之上叠加 selected 态形状(Compose
/// IconToggleButtonShapes 语义:pressed > checked > 默认)。选中的
/// 切换图标按钮从全圆变小圆角方,给 36 处 isSelected 调用点免费的
/// M3E 切换标志动效;时长同 DefaultEffects。
ButtonStyle _m3eIconButtonShapeStyle(UiShapes shapes) => ButtonStyle(
  animationDuration: const Duration(milliseconds: 180),
  shape: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.pressed)) {
      return RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(8));
    }
    if (states.contains(WidgetState.selected)) {
      return RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(12));
    }
    return RoundedSuperellipseBorder(
      borderRadius: BorderRadius.all(shapes.radius(9999)),
    );
  }),
);

/// light/dark 共用的 ThemeData 装配(两侧必须对称,尤其 M3eFlags ——
/// ThemeData.lerp 对单边缺失的 extension 不插值而是瞬时并入)。
ThemeData buildAppTheme(
  ColorScheme scheme,
  AppColors colors,
  UiShapes shapes,
  ThemeState themeState, {
  required bool fullscreenSwipeBack,
  required bool transparent,
}) {
  final m3e = themeState.m3eEnabled;
  final fullShape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.all(shapes.radius(9999)),
  );
  final roundButtonStyle = ButtonStyle(
    shape: WidgetStatePropertyAll(fullShape),
  );
  final buttonStyle = m3e ? _m3ePressedShapeStyle(shapes) : roundButtonStyle;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: themeState.fontFamilyName,
    // 透明模式：脚手架让出背景，由各页面独立背景层的用户图片透出
    scaffoldBackgroundColor: transparent ? Colors.transparent : null,
    pageTransitionsTheme: fullscreenSwipeBack
        ? _fullscreenSwipePageTransitionsTheme
        : _pageTransitionsTheme,
    iconTheme: _appIconTheme(scheme.onSurface),
    primaryIconTheme: _appIconTheme(scheme.onPrimary),
    // 操作入口使用强调色；正文辅助图标仍继承 onSurface，业务状态可显式覆写。
    appBarTheme: AppBarThemeData(
      iconTheme: _appIconTheme(scheme.primary),
      actionsIconTheme: _appIconTheme(scheme.primary),
    ),
    listTileTheme: ListTileThemeData(iconColor: scheme.primary),
    extensions: [
      M3eFlags(enabled: m3e),
      colors,
      colors.render,
      shapes,
      shapes.render,
    ],
    // year2023: false 启用进度条/滑块的 M3E 翻新(圆角端点/track gap/
    // stop indicator/16dp 滑轨+竖条 thumb)。字段虽标记 deprecated,但
    // trackGap 等新样式只由它驱动,官方 M3E 独立包落地前只能走这里。
    // circularTrackPadding 归零:新样式默认 4dp 内边距会把存量
    // SizedBox(20) 小圈的可画区吃掉 8dp。
    // ignore: deprecated_member_use
    progressIndicatorTheme: ProgressIndicatorThemeData(
      // ignore: deprecated_member_use
      year2023: !m3e,
      circularTrackPadding: EdgeInsets.zero,
    ),
    // ignore: deprecated_member_use
    sliderTheme: SliderThemeData(year2023: !m3e),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    iconButtonTheme: IconButtonThemeData(
      style: m3e ? _m3eIconButtonShapeStyle(shapes) : roundButtonStyle,
    ),
    navigationBarTheme: NavigationBarThemeData(indicatorShape: fullShape),
    navigationRailTheme: NavigationRailThemeData(indicatorShape: fullShape),
    tooltipTheme: TooltipThemeData(
      decoration: ShapeDecoration(
        color: scheme.inverseSurface,
        shape: RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(4)),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(shapes.radius(28)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(top: shapes.radius(28)),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(shapes.radius(16)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(style: roundButtonStyle),
    searchBarTheme: SearchBarThemeData(
      shape: WidgetStatePropertyAll(fullShape),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(8)),
    ),
    snackBarTheme: SnackBarThemeData(
      shape: RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(4)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(4)),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(12)),
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedSuperellipseBorder(borderRadius: shapes.borderRadius(20)),
      elevation: 3,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
    ),
  );
}
