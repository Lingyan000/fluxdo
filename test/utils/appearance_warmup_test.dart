import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
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

    // 色卡网格：动态色/当前种子 + 14 个预设色 + 自定义色
    for (final seed in <Color>[
      Colors.blue,
      ...ThemeNotifier.presetColors,
      customColor,
    ]) {
      SeedColorScheme.from(seedColor: seed, brightness: Brightness.light);
    }
    // 主题模式卡的亮/暗预览
    SeedColorScheme.from(seedColor: Colors.blue, brightness: Brightness.dark);
    // 配色风格卡的 9 种风格
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
}
