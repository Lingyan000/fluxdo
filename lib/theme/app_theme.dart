import 'package:common_ui/common_ui.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:m3e_ui/m3e_ui.dart';

import '../providers/theme_provider.dart';
import '../widgets/common/fullscreen_swipe_back.dart';
import 'app_colors.dart';
import '../services/fonts/font_catalog.dart';
import 'shape_presets.dart';
import 'style_decorations.dart';
import 'theme_style.dart';

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

/// 图标按钮的统一配色：操作图标一律用次要色，选中态用选中 token。
///
/// 不设这一层时，Flutter 会把全局 `iconTheme`（正文图标的 onSurface）
/// 灌给没显式设色的图标按钮，与显式写次要色的按钮同处一行时深浅不一。
/// 顶栏图标由 AppBar 的图标主题覆盖，仍是强调色。
ButtonStyle _iconButtonColors(ColorScheme scheme, UiEmphasis emphasis) =>
    IconButton.styleFrom(foregroundColor: scheme.onSurfaceVariant).copyWith(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: 0.38);
        }
        if (states.contains(WidgetState.selected)) return emphasis.selected;
        return scheme.onSurfaceVariant;
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
  required bool pageBackground,
  ThemeStyle style = ThemeStyle.material,
}) {
  final m3e = themeState.m3eEnabled;
  final fullShape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.all(shapes.radius(9999)),
  );
  final roundButtonStyle = ButtonStyle(
    shape: WidgetStatePropertyAll(fullShape),
  );
  final buttonStyle = m3e ? _m3ePressedShapeStyle(shapes) : roundButtonStyle;
  // 强调 token：墨色控件的主题里，入口图标与选中标记一起换成墨色
  final emphasisColor = style.controls == ControlStyle.ink
      ? scheme.onSurface
      : scheme.primary;
  final emphasis = UiEmphasis(accent: emphasisColor, selected: emphasisColor);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: themeState.fontFamilyName,
    // 页面背景（自定义背景、主题纹理）：脚手架让出底色，由各页面独立的
    // 背景层显示；阅读内容通过 PageBackgroundScope 选择透明填充
    scaffoldBackgroundColor: pageBackground ? Colors.transparent : null,
    pageTransitionsTheme: fullscreenSwipeBack
        ? _fullscreenSwipePageTransitionsTheme
        : _pageTransitionsTheme,
    iconTheme: _appIconTheme(scheme.onSurface),
    primaryIconTheme: _appIconTheme(scheme.onPrimary),
    // 操作入口使用强调色；正文辅助图标仍继承 onSurface，业务状态可显式覆写。
    appBarTheme: AppBarThemeData(
      iconTheme: _appIconTheme(emphasis.accent),
      actionsIconTheme: _appIconTheme(emphasis.accent),
    ),
    listTileTheme: ListTileThemeData(iconColor: emphasis.accent),
    extensions: [
      M3eFlags(enabled: m3e),
      colors,
      colors.render,
      shapes,
      shapes.render,
      emphasis,
      _renderStyle(style, themeState.fontFamilyName),
      // 风格扩展两侧必须对称（ThemeData.lerp 对单边缺失不插值）
      style,
      SegmentedCardStyle(
        mode: switch (style.surfaces) {
          SurfaceStyle.filled => SegmentedCardMode.segmented,
          SurfaceStyle.outlined => SegmentedCardMode.outlined,
          SurfaceStyle.flat => SegmentedCardMode.flat,
        },
      ),
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
      style: (m3e ? _m3eIconButtonShapeStyle(shapes) : roundButtonStyle).merge(
        _iconButtonColors(scheme, emphasis),
      ),
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
  final themed = style.hasMaterialComponents
      ? base
      : _applyStyle(base, scheme, shapes, style, buttonStyle);
  return pageBackground ? _revealPageBackground(themed, scheme) : themed;
}

/// 有页面背景时，页面级的栏让背景透出来：
/// - 标题栏平时透明，内容滚到它下面时（scrolledUnder）才换成不透明底色，
///   不会透出滚动内容；
/// - 底部导航透明（底下由 [PageBackdrop] 垫一层对齐的背景副本）；
/// - 侧边导航与内容并排、不重叠，直接透明。
/// 阅读内容通过 PageBackgroundScope.contentColor 透出背景，面板、菜单
/// 等覆盖内容的表面使用各自的组件主题。
ThemeData _revealPageBackground(ThemeData theme, ColorScheme scheme) {
  final opaque = theme.appBarTheme.backgroundColor ?? scheme.surface;
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      backgroundColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.scrolledUnder)
            ? opaque
            : Colors.transparent,
      ),
    ),
    navigationBarTheme: theme.navigationBarTheme.copyWith(
      backgroundColor: Colors.transparent,
    ),
    navigationRailTheme: theme.navigationRailTheme.copyWith(
      backgroundColor: Colors.transparent,
    ),
  );
}

/// 标题字体的候选链：宋体 / 等宽 / 字体目录里的字体，带各平台回退。
///
/// 返回（首选字体, 回退链）。回退链末尾是通用字族名 `serif` /
/// `monospace`，调用方要把正文字体插在它前面（补标题字体缺的字，如等宽
/// 字体没有中文）。通用名必须放最后：它在不同引擎上可能映射到覆盖不全
/// 的字体，放前面会截走本该回退的字。
(String, List<String>, String?)? _titleFontChain(String? titleFont) {
  if (titleFont == null) return null;
  final candidates = switch (titleFont) {
    'serif' => <String>[
      // 下载了思源宋体时优先使用
      ?FontCatalog.byId('source-han-serif')?.family,
      'Songti SC',
      'STSong',
      'Noto Serif CJK SC',
      'Noto Serif SC',
      'SimSun',
    ],
    'mono' => <String>['FiraCode', 'Menlo', 'Consolas'],
    final id => <String>[?FontCatalog.byId(id)?.family],
  };
  if (candidates.isEmpty) return null;
  final generic = switch (titleFont) {
    'serif' => 'serif',
    'mono' => 'monospace',
    _ => null,
  };
  return (candidates.first, candidates.skip(1).toList(), generic);
}

TextStyle? _titleFont(TextStyle? style, String? titleFont) {
  final chain = _titleFontChain(titleFont);
  if (style == null || chain == null) return style;
  final (family, rest, generic) = chain;
  return style.copyWith(
    fontFamily: family,
    fontFamilyFallback: [
      ...rest,
      ?style.fontFamily,
      ...?style.fontFamilyFallback,
      ?generic,
    ],
  );
}

/// 帖子正文的排版风格（标题字体、引用块外观）。
FluxdoRenderStyle _renderStyle(ThemeStyle style, String? bodyFamily) {
  final chain = _titleFontChain(style.titleFont);
  final bar = style.quote == QuoteStyle.bar;
  return FluxdoRenderStyle(
    headingFontFamily: chain?.$1,
    headingFontFamilyFallback: chain == null
        ? null
        : [...chain.$2, ?bodyFamily, ?chain.$3],
    quoteBackground: !bar,
    quoteBarWidth: bar ? 2 : 4,
  );
}

/// 按界面风格调整组件主题（Material 风格不经过这里，外观保持不变）。
ThemeData _applyStyle(
  ThemeData base,
  ColorScheme scheme,
  UiShapes shapes,
  ThemeStyle style,
  ButtonStyle buttonStyle,
) {
  final ink = style.controls == ControlStyle.ink;
  // 墨色控件：浅色下近黑、深色下近白，前景取页面底色
  final control = ink ? scheme.onSurface : scheme.primary;
  final onControl = ink ? scheme.surface : scheme.onPrimary;
  final hairline = scheme.outlineVariant;
  final flat = style.surfaces == SurfaceStyle.flat;
  // 容器底色：描边 = 与页面同色；平铺 = 透明（让纸张纹理透出）
  final cardColor = flat ? Colors.transparent : scheme.surface;
  // 浮层（对话框、弹层、菜单）需要实底：平铺风格取比纸面略亮的一层
  final overlayColor = flat ? scheme.surfaceContainerLowest : scheme.surface;
  final elevation = style.shadows ? null : 0.0;
  final hairlineSide = BorderSide(color: hairline);

  WidgetStateProperty<Color?> selectedColor(Color on, Color? off) =>
      WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? on : off,
      );

  final navTint = style.navIndicator == NavIndicatorStyle.tint;
  final navBar = style.navIndicator == NavIndicatorStyle.bar;
  final navIndicatorColor = switch (style.navIndicator) {
    NavIndicatorStyle.pill => null,
    NavIndicatorStyle.tint => scheme.onSurface.withValues(alpha: 0.08),
    NavIndicatorStyle.bar => scheme.primary,
  };
  final ShapeBorder? navIndicatorShape = switch (style.navIndicator) {
    NavIndicatorStyle.pill => null,
    NavIndicatorStyle.tint => RoundedSuperellipseBorder(
      borderRadius: shapes.borderRadius(10),
    ),
    NavIndicatorStyle.bar => const ShortBarIndicatorShape(),
  };
  final navIconTheme = WidgetStateProperty.resolveWith(
    (s) => IconThemeData(
      color: s.contains(WidgetState.selected)
          ? scheme.onSurface
          : scheme.onSurfaceVariant,
    ),
  );
  final navLabel = WidgetStateProperty.resolveWith(
    (s) => TextStyle(
      fontSize: 12,
      color: s.contains(WidgetState.selected)
          ? scheme.onSurface
          : scheme.onSurfaceVariant,
      fontWeight: s.contains(WidgetState.selected)
          ? FontWeight.w600
          : FontWeight.w400,
    ),
  );

  final InputBorder? inputBorder = switch (style.inputs) {
    InputStyle.filled => null,
    InputStyle.outlined => OutlineInputBorder(
      borderRadius: shapes.borderRadius(8),
      borderSide: hairlineSide,
    ),
    InputStyle.underline => UnderlineInputBorder(
      borderSide: BorderSide(color: scheme.outline),
    ),
  };
  final InputBorder? focusedInputBorder = switch (style.inputs) {
    InputStyle.filled => null,
    InputStyle.outlined => OutlineInputBorder(
      borderRadius: shapes.borderRadius(8),
      borderSide: BorderSide(color: control, width: 1.5),
    ),
    InputStyle.underline => UnderlineInputBorder(
      borderSide: BorderSide(color: control, width: 1.5),
    ),
  };

  final textTheme = base.textTheme.copyWith(
    displayLarge: _titleFont(base.textTheme.displayLarge, style.titleFont),
    displayMedium: _titleFont(base.textTheme.displayMedium, style.titleFont),
    displaySmall: _titleFont(base.textTheme.displaySmall, style.titleFont),
    headlineLarge: _titleFont(base.textTheme.headlineLarge, style.titleFont),
    headlineMedium: _titleFont(base.textTheme.headlineMedium, style.titleFont),
    headlineSmall: _titleFont(base.textTheme.headlineSmall, style.titleFont),
    titleLarge: _titleFont(base.textTheme.titleLarge, style.titleFont),
  );

  return base.copyWith(
    textTheme: textTheme,
    dividerTheme: DividerThemeData(color: hairline, thickness: 0.6, space: 1),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: style.shadows ? null : 0,
    ),
    listTileTheme: ink
        ? base.listTileTheme.copyWith(iconColor: scheme.onSurfaceVariant)
        : null,
    cardTheme: base.cardTheme.copyWith(
      color: cardColor,
      elevation: 0,
      shape: RoundedSuperellipseBorder(
        borderRadius: shapes.borderRadius(12),
        side: hairlineSide,
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: overlayColor,
      surfaceTintColor: Colors.transparent,
      elevation: elevation,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(shapes.radius(20)),
        side: style.shadows ? BorderSide.none : hairlineSide,
      ),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: overlayColor,
      modalBackgroundColor: overlayColor,
      surfaceTintColor: Colors.transparent,
      elevation: elevation,
      modalElevation: elevation,
      dragHandleColor: scheme.outline,
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: overlayColor,
      elevation: style.shadows ? null : 0,
      shape: RoundedSuperellipseBorder(
        borderRadius: shapes.borderRadius(12),
        side: style.shadows ? BorderSide.none : hairlineSide,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(overlayColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(elevation),
        shape: WidgetStatePropertyAll(
          RoundedSuperellipseBorder(
            borderRadius: shapes.borderRadius(10),
            side: style.shadows ? BorderSide.none : hairlineSide,
          ),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.12)
              : control,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.38)
              : onControl,
        ),
      ).merge(buttonStyle),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
      ).merge(buttonStyle),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        side: WidgetStateProperty.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.disabled) ? hairline : scheme.outline,
          ),
        ),
      ).merge(buttonStyle),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(control))
          .merge(buttonStyle),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      backgroundColor: control,
      foregroundColor: onControl,
      elevation: elevation,
      focusElevation: elevation,
      hoverElevation: elevation,
      highlightElevation: elevation,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: selectedColor(onControl, null),
      trackColor: selectedColor(control, null),
      trackOutlineColor: selectedColor(control, null),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: selectedColor(control, null),
      checkColor: WidgetStatePropertyAll(onControl),
    ),
    radioTheme: RadioThemeData(fillColor: selectedColor(control, null)),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Colors.transparent,
      selectedColor: control,
      checkmarkColor: onControl,
      side: WidgetStateBorderSide.resolveWith(
        (s) => BorderSide(
          color: s.contains(WidgetState.selected) ? control : hairline,
        ),
      ),
      // RawChip 只对 labelStyle 的 color 做状态解析，需用 WidgetStateColor
      // 只换颜色，保留主题的字体（否则会丢掉用户选的正文字体）
      labelStyle: (base.textTheme.labelLarge ?? const TextStyle()).copyWith(
        color: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? onControl
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: elevation,
      indicatorColor: navIndicatorColor,
      indicatorShape: navIndicatorShape,
      iconTheme: navTint || navBar ? navIconTheme : null,
      labelTextStyle: navTint || navBar ? navLabel : null,
    ),
    navigationRailTheme: base.navigationRailTheme.copyWith(
      backgroundColor: scheme.surface,
      indicatorColor: navIndicatorColor,
      indicatorShape: navIndicatorShape,
      selectedIconTheme: IconThemeData(color: scheme.onSurface),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    ),
    tabBarTheme: TabBarThemeData(
      indicator: switch (style.navIndicator) {
        NavIndicatorStyle.pill => null,
        NavIndicatorStyle.tint => UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.onSurface, width: 2),
        ),
        NavIndicatorStyle.bar => ShortBarTabIndicator(color: scheme.primary),
      },
      indicatorSize: TabBarIndicatorSize.label,
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      dividerColor: hairline,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: inputBorder == null
        ? base.inputDecorationTheme
        : InputDecorationThemeData(
            border: inputBorder,
            enabledBorder: inputBorder,
            focusedBorder: focusedInputBorder,
            filled: false,
          ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: control,
      thumbColor: control,
      inactiveTrackColor: scheme.surfaceContainerHighest,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.22),
      selectionHandleColor: scheme.primary,
    ),
  );
}
