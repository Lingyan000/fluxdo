import 'package:flutter/material.dart';

import 'color_contrast.dart';

/// 中性表面层：一套 ColorScheme 的全部中性 role。
///
/// Material 主题（未开纯黑/透明）不走这里——表面由种子色 fromSeed 完整
/// 生成，带轻微色相（见 theme_resolver.dart）。简约主题、纯黑/透明修饰
/// 用下面的内置三套（无色相中性灰，不被种子色染色）；固定配色主题用
/// [NeutralRamp.derive] 从主题关键色推导。
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

  /// 本类提供的 ColorScheme role 名（与上面的字段一一对应）。
  static const Set<String> roleNames = {
    'surface',
    'onSurface',
    'onSurfaceVariant',
    'surfaceDim',
    'surfaceBright',
    'surfaceContainerLowest',
    'surfaceContainerLow',
    'surfaceContainer',
    'surfaceContainerHigh',
    'surfaceContainerHighest',
    'outline',
    'outlineVariant',
    'inverseSurface',
    'onInverseSurface',
    'shadow',
    'scrim',
  };

  /// overlay 以 [alpha] 叠加到 base 上。
  static Color _over(Color base, Color overlay, double alpha) =>
      Color.alphaBlend(overlay.withValues(alpha: alpha), base);

  static const _white = Color(0xFFFFFFFF);
  static const _black = Color(0xFF000000);

  /// 浅色中性层（简约主题）：surface 近白，容器阶梯向下微微压暗。
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

  /// 深色中性层（简约主题）：surface 近黑，容器阶梯向上抬亮。
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

  /// 简约主题的浅色层：纯白底、不带色相的锌灰阶梯。层级以细线描边
  /// 区分为主（见 ThemeStyle.surfaces），容器色只做极轻的明度台阶。
  static const NeutralRamp zincLight = NeutralRamp(
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF09090B),
    onSurfaceVariant: Color(0xFF67676F),
    outline: Color(0xFF8B8B93),
    outlineVariant: Color(0xFFE4E4E7),
    inverseSurface: Color(0xFF18181B),
    onInverseSurface: Color(0xFFFAFAFA),
    shadow: _black,
    scrim: _black,
    surfaceDim: Color(0xFFE4E4E7),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFFAFAFA),
    surfaceContainer: Color(0xFFF5F5F6),
    surfaceContainerHigh: Color(0xFFEFEFF1),
    surfaceContainerHighest: Color(0xFFE9E9EC),
  );

  /// 简约主题的深色层：近黑底、锌灰阶梯。
  static const NeutralRamp zincDark = NeutralRamp(
    surface: Color(0xFF09090B),
    onSurface: Color(0xFFFAFAFA),
    onSurfaceVariant: Color(0xFFA1A1AA),
    outline: Color(0xFF71717A),
    outlineVariant: Color(0xFF27272A),
    inverseSurface: Color(0xFFFAFAFA),
    onInverseSurface: Color(0xFF18181B),
    shadow: _black,
    scrim: _black,
    surfaceDim: Color(0xFF050506),
    surfaceBright: Color(0xFF27272A),
    surfaceContainerLowest: Color(0xFF050506),
    surfaceContainerLow: Color(0xFF0F0F12),
    surfaceContainer: Color(0xFF141417),
    surfaceContainerHigh: Color(0xFF1C1C20),
    surfaceContainerHighest: Color(0xFF232328),
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

  /// 由固定配色主题的关键色推导完整中性层。
  ///
  /// 容器阶梯沿用上面三套的叠加档位（浅色向下压暗、深色向上抬亮），
  /// 保证固定配色主题与内置中性层的层级手感一致。[pureBlack] 时表面换成
  /// 纯黑、阶梯用纯黑档位，前景色仍取主题自己的。
  ///
  /// 文字类 role 对最深的容器（surfaceContainerHighest）补足对比度：
  /// 文字可能出现在任何一级容器上，按最坏情况保证。
  factory NeutralRamp.derive({
    required Brightness brightness,
    required Color surface,
    required Color onSurface,
    required Color onSurfaceVariant,
    required Color outlineVariant,
    Color? outline,
    bool pureBlack = false,
  }) {
    final isLight = brightness == Brightness.light;
    final base = pureBlack && !isLight ? _black : surface;
    final List<double> ladder;
    final Color ladderTint;
    final Color dim;
    final Color bright;
    final Color lowest;
    if (isLight) {
      ladder = const [0.02, 0.035, 0.055, 0.075];
      ladderTint = _black;
      dim = _over(base, _black, 0.10);
      bright = _over(base, _white, 0.60);
      lowest = _over(base, _white, 0.60);
    } else if (pureBlack) {
      ladder = const [0.05, 0.07, 0.10, 0.13];
      ladderTint = _white;
      dim = _black;
      bright = _over(_black, _white, 0.16);
      lowest = _black;
    } else {
      ladder = const [0.03, 0.05, 0.07, 0.10];
      ladderTint = _white;
      dim = _over(base, _black, 0.35);
      bright = _over(base, _white, 0.14);
      lowest = _over(base, _black, 0.30);
    }
    final highest = _over(base, ladderTint, ladder[3]);
    final fg = ColorContrast.ensure(onSurface, highest, ColorContrast.text);
    final fgMuted = ColorContrast.ensure(
      onSurfaceVariant,
      highest,
      ColorContrast.text,
    );
    return NeutralRamp(
      surface: base,
      onSurface: fg,
      onSurfaceVariant: fgMuted,
      outline: ColorContrast.ensure(
        outline ?? Color.lerp(fgMuted, base, 0.3)!,
        base,
        ColorContrast.graphic,
      ),
      outlineVariant: outlineVariant,
      inverseSurface: fg,
      onInverseSurface: base,
      shadow: _black,
      scrim: _black,
      surfaceDim: dim,
      surfaceBright: bright,
      surfaceContainerLowest: lowest,
      surfaceContainerLow: _over(base, ladderTint, ladder[0]),
      surfaceContainer: _over(base, ladderTint, ladder[1]),
      surfaceContainerHigh: _over(base, ladderTint, ladder[2]),
      surfaceContainerHighest: highest,
    );
  }
}
