import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_palettes.dart';
import 'package:fluxdo/utils/appearance_warmup.dart';
import 'package:fluxdo/utils/seed_color_scheme.dart';

void main() {
  testWidgets('预热覆盖外观页首帧用到的全部配色组合', (tester) async {
    SeedColorScheme.resetCache();

    const customColor = Color(0xFF123456);
    const themeState = ThemeState(
      mode: ThemeMode.system,
      seedColor: Colors.blue,
      schemeVariant: DynamicSchemeVariant.tonalSpot,
      customColors: [customColor],
    );

    AppearanceWarmup.schedule(
      themeState: themeState,
      brightness: Brightness.light,
    );

    // idle 任务只在帧间空闲时执行，推进到全部跑完。
    await tester.idle();
    await tester.pump();

    // 预热后，外观页首帧要用的组合应当全部命中缓存，不再触发计算。
    final countAfterWarmup = SeedColorScheme.cachedCount;
    expect(countAfterWarmup, greaterThan(0));

    // 色卡网格：当前生效种子 + 内置调色板（跟随当前 variant，此处 tonalSpot）
    for (final seed in <Color>{
      Colors.blue,
      ...AppPalettes.builtins.map((p) => p.seedColor),
    }) {
      SeedColorScheme.from(seedColor: seed, brightness: Brightness.light);
    }
    // 自定义色卡
    SeedColorScheme.from(seedColor: customColor, brightness: Brightness.light);
    // 主题模式卡的亮/暗预览
    SeedColorScheme.from(seedColor: Colors.blue, brightness: Brightness.dark);
    // 配色风格卡：当前生效种子 × 9 种风格
    for (final variant in DynamicSchemeVariant.values) {
      SeedColorScheme.from(
        seedColor: Colors.blue,
        brightness: Brightness.light,
        variant: variant,
      );
    }

    expect(
      SeedColorScheme.cachedCount,
      countAfterWarmup,
      reason: '外观页首帧不应再产生未命中的配色计算',
    );
  });

  testWidgets('配色风格对任意来源生效，预热组合跟随 variant', (tester) async {
    SeedColorScheme.resetCache();

    // 自定义来源 + 非默认配色风格：调色板色卡也应按 vibrant 预热
    const themeState = ThemeState(
      mode: ThemeMode.system,
      accentSource: AccentSource.custom,
      seedColor: Color(0xFF123456),
      schemeVariant: DynamicSchemeVariant.vibrant,
    );

    AppearanceWarmup.schedule(
      themeState: themeState,
      brightness: Brightness.light,
    );

    await tester.idle();
    await tester.pump();

    final countAfterWarmup = SeedColorScheme.cachedCount;

    // 配色风格卡：自定义种子 × 9 种风格
    for (final variant in DynamicSchemeVariant.values) {
      SeedColorScheme.from(
        seedColor: const Color(0xFF123456),
        brightness: Brightness.light,
        variant: variant,
      );
    }
    // 调色板色卡：跟随当前 variant（vibrant）
    for (final palette in AppPalettes.builtins) {
      SeedColorScheme.from(
        seedColor: palette.seedColor,
        brightness: Brightness.light,
        variant: DynamicSchemeVariant.vibrant,
      );
    }
    // 主题模式卡的亮/暗预览
    SeedColorScheme.from(
      seedColor: const Color(0xFF123456),
      brightness: Brightness.dark,
      variant: DynamicSchemeVariant.vibrant,
    );

    expect(
      SeedColorScheme.cachedCount,
      countAfterWarmup,
      reason: '非默认配色风格下首帧不应再产生未命中的配色计算',
    );
  });
}
