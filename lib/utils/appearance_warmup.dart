import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../providers/theme_provider.dart';
import '../theme/app_palettes.dart';
import '../theme/theme_preview_cache.dart';
import '../theme/theme_registry.dart';
import '../theme/theme_spec.dart';
import 'seed_color_scheme.dart';

/// 外观设置页首帧开销的预热。
///
/// 首次进入外观设置页要为色卡网格、配色风格卡、主题模式卡与主题画廊
/// 计算几十套配色（原因见 [SeedColorScheme]、[ThemePreviewCache]），集中
/// 在首帧会明显掉帧；再次进入时都已缓存，所以只有第一次会顿。
///
/// 预热挂在进入设置页时：此时界面静止，且用户还要再点一次才进外观页，
/// 用 idle 优先级逐项排队（每项 1~2ms），既不与转场动画抢帧，也来得及做完。
///
/// 预热的组合必须与外观页首帧实际计算的 (种子色, 亮暗, 配色风格) 严格
/// 一致，否则白预热还占缓存：
/// - 色卡网格（调色板/动态色/自定义色）：跟随当前 schemeVariant；
/// - 主题模式卡：当前生效种子 × 亮/暗两种预览；
/// - 配色风格卡：当前生效种子 × 9 种风格；
/// - 主题画廊：全部主题的缩略图配色（[ThemePreviewCache]）。
class AppearanceWarmup {
  AppearanceWarmup._();

  /// 上次预热依据的配色签名，用于避免重复排任务；主题、强调色等变更
  /// 后签名不同，会按新配色重新预热。
  static Object? _lastSignature;

  static void schedule({
    required ThemeState themeState,
    required Brightness brightness,
  }) {
    final variant = themeState.schemeVariant;
    final signature = (
      themeState.accentSource.index,
      themeState.effectiveSeedColor.toARGB32(),
      variant.index,
      brightness.index,
      themeState.themeId,
      Object.hashAllUnordered(
        themeState.themeAccents.entries.map((e) => '${e.key}=${e.value}'),
      ),
      themeState.blackEnabled,
    );
    if (signature == _lastSignature) return;
    _lastSignature = signature;

    final scheduler = SchedulerBinding.instance;
    void queue(void Function() task) =>
        scheduler.scheduleTask(task, Priority.idle);

    // 色卡网格：动态色卡 + 内置调色板（跟随当前配色风格）
    for (final seed in <Color>{
      themeState.effectiveSeedColor,
      ...AppPalettes.builtins.map((p) => p.seedColor),
    }) {
      queue(
        () => SeedColorScheme.from(
          seedColor: seed,
          brightness: brightness,
          variant: variant,
        ),
      );
    }

    // 色卡网格：自定义色（跟随当前 variant）
    for (final seed in themeState.customColors) {
      queue(
        () => SeedColorScheme.from(
          seedColor: seed,
          brightness: brightness,
          variant: variant,
        ),
      );
    }

    // 主题模式卡的亮/暗预览（中性/纯黑开关的合成复用同一缓存）
    for (final previewBrightness in Brightness.values) {
      queue(
        () => SeedColorScheme.from(
          seedColor: themeState.effectiveSeedColor,
          brightness: previewBrightness,
          variant: variant,
        ),
      );
    }

    // 配色风格卡：当前生效种子 × 9 种风格
    for (final previewVariant in DynamicSchemeVariant.values) {
      queue(
        () => SeedColorScheme.from(
          seedColor: themeState.effectiveSeedColor,
          brightness: brightness,
          variant: previewVariant,
        ),
      );
    }

    // 主题画廊：每个主题一张缩略图（同族只画当前或族内第一个，这里
    // 全族预热，多出的几项代价可忽略）
    for (final spec in ThemeRegistry.all.where(
      (s) => s.group != ThemeGroup.festival,
    )) {
      queue(
        () => ThemePreviewCache.schemeOf(
          spec: spec,
          brightness: brightness,
          accentId: themeState.accentFor(spec),
          seed: themeState.effectiveSeedColor,
          variant: variant,
          black: themeState.blackEnabled,
        ),
      );
    }
  }
}
