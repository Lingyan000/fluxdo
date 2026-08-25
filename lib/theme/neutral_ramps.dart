import 'package:flutter/material.dart';

/// 中性表面层：中性/纯黑/透明三个开关下的全部中性 role。
///
/// 默认主题（未开任何开关）不走这里——浅/深/跟随系统的表面由种子色
/// fromSeed 完整生成，带轻微色相（见 theme_resolver.dart）。只有开关
/// 路径的中性 role 来自本类：无色相中性灰——不随强调色变化、不被
/// 种子色染色。
///
/// 容器阶梯（surfaceContainer*）用黑白 alpha 在 surface 上叠加派生，
/// 层级单调递增，避免 fromSeed 生成的色相偏移。
class NeutralRamp {
  const NeutralRamp({
    required this.surface,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.surfaceDim,
    required this.surfaceBright,
    required this.surfaceContainerLowest,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.outline,
    required this.outlineVariant,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.shadow,
    required this.scrim,
  });

  final Color surface;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color surfaceDim;
  final Color surfaceBright;
  final Color surfaceContainerLowest;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color outline;
  final Color outlineVariant;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color shadow;
  final Color scrim;

  /// overlay 以 [alpha] 叠加到 base 上。
  static Color _over(Color base, Color overlay, double alpha) =>
      Color.alphaBlend(overlay.withValues(alpha: alpha), base);

  static const _white = Color(0xFFFFFFFF);
  static const _black = Color(0xFF000000);

  /// 浅色中性层（中性开关）：surface 近白，容器阶梯向下微微压暗。
  static final NeutralRamp light = NeutralRamp(
    surface: const Color(0xFFF7F7F8),
    onSurface: const Color(0xFF1E1E20),
    onSurfaceVariant: const Color(0xFF5D5D61),
    outline: const Color(0xFF76767B),
    outlineVariant: const Color(0xFFDEDEE2),
    inverseSurface: const Color(0xFF2E2E31),
    onInverseSurface: const Color(0xFFF4F4F5),
    shadow: _black,
    scrim: _black,
    surfaceBright: _white,
    surfaceDim: _over(const Color(0xFFF7F7F8), _black, 0.10),
    surfaceContainerLowest: _white,
    surfaceContainerLow: _over(const Color(0xFFF7F7F8), _black, 0.02),
    surfaceContainer: _over(const Color(0xFFF7F7F8), _black, 0.035),
    surfaceContainerHigh: _over(const Color(0xFFF7F7F8), _black, 0.055),
    surfaceContainerHighest: _over(const Color(0xFFF7F7F8), _black, 0.075),
  );

  /// 深色中性层（中性开关）：surface 近黑，容器阶梯向上抬亮。
  static final NeutralRamp dark = NeutralRamp(
    surface: const Color(0xFF131315),
    onSurface: const Color(0xFFF2F2F4),
    onSurfaceVariant: const Color(0xFFC6C6CA),
    outline: const Color(0xFF8C8C91),
    outlineVariant: const Color(0xFF3A3A3E),
    inverseSurface: const Color(0xFFF2F2F4),
    onInverseSurface: const Color(0xFF1E1E20),
    shadow: _black,
    scrim: _black,
    surfaceDim: const Color(0xFF0C0C0E),
    surfaceBright: _over(const Color(0xFF131315), _white, 0.14),
    surfaceContainerLowest: _over(const Color(0xFF131315), _black, 0.30),
    surfaceContainerLow: _over(const Color(0xFF131315), _white, 0.03),
    surfaceContainer: _over(const Color(0xFF131315), _white, 0.05),
    surfaceContainerHigh: _over(const Color(0xFF131315), _white, 0.07),
    surfaceContainerHighest: _over(const Color(0xFF131315), _white, 0.10),
  );

  /// 纯黑中性层（AMOLED）：surface 纯黑，容器阶梯比深色更亮一点，
  /// 保证卡片/菜单在纯黑底上仍可分辨。
  static final NeutralRamp black = NeutralRamp(
    surface: _black,
    onSurface: dark.onSurface,
    onSurfaceVariant: dark.onSurfaceVariant,
    outline: dark.outline,
    outlineVariant: dark.outlineVariant,
    inverseSurface: dark.inverseSurface,
    onInverseSurface: dark.onInverseSurface,
    shadow: _black,
    scrim: _black,
    surfaceDim: _black,
    surfaceBright: _over(_black, _white, 0.16),
    surfaceContainerLowest: _black,
    surfaceContainerLow: _over(_black, _white, 0.05),
    surfaceContainer: _over(_black, _white, 0.07),
    surfaceContainerHigh: _over(_black, _white, 0.10),
    surfaceContainerHighest: _over(_black, _white, 0.13),
  );

  /// 透明中性层：在 [base] 基础上给表面类 role 加透明度，
  /// 让用户背景图透出来。
  ///
  /// 透明度分档有讲究：
  /// - 卡片层（Low，帖子正文容器）保持 0.92 以上，保证阅读区可读性；
  /// - 对话框/菜单层（High/Highest）接近不透明，浮层不能被背景干扰；
  /// - scaffold 背景不在这里处理，由 ThemeData 单独设为全透明。
  ///
  /// 浮层根背景的用色约定：模态浮层（showAppBottomSheet/对话框，底下
  /// 有 barrier 压暗内容）根背景用 surface，保持半透明质感；锚定面板
  /// （通知快捷面板、搜索过滤面板，底下是未压暗的内容）用
  /// `ColorScheme.overlaySurface`（theme_resolver.dart）——透明模式
  /// 下取接近不透明的 containerHigh 避免透字，普通模式仍是 surface。
  factory NeutralRamp.transparent(NeutralRamp base) => NeutralRamp(
    surface: base.surface.withValues(alpha: 0.72),
    onSurface: base.onSurface,
    onSurfaceVariant: base.onSurfaceVariant,
    outline: base.outline,
    outlineVariant: base.outlineVariant,
    inverseSurface: base.inverseSurface,
    onInverseSurface: base.onInverseSurface,
    shadow: base.shadow,
    scrim: base.scrim,
    surfaceDim: base.surfaceDim.withValues(alpha: 0.72),
    surfaceBright: base.surfaceBright.withValues(alpha: 0.72),
    surfaceContainerLowest: base.surfaceContainerLowest.withValues(alpha: 0.80),
    surfaceContainerLow: base.surfaceContainerLow.withValues(alpha: 0.92),
    surfaceContainer: base.surfaceContainer.withValues(alpha: 0.88),
    surfaceContainerHigh: base.surfaceContainerHigh.withValues(alpha: 0.94),
    surfaceContainerHighest: base.surfaceContainerHighest.withValues(
      alpha: 0.95,
    ),
  );
}
