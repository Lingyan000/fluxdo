import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../providers/theme_provider.dart';
import '../theme/app_palettes.dart';
import 'seed_color_scheme.dart';

/// 外观设置页首帧开销的预热。
///
/// 首次进入外观设置页会一次性付两笔昂贵开销，叠加起来明显掉帧；再次进入
/// 时因引擎与 [SeedColorScheme] 都已缓存，所以只有第一次会顿：
///
/// 1. **MiSans 懒加载** — 引擎读 `FontManifest.json` 时只登记
///    family → asset 映射（`AssetManagerFontProvider::RegisterAsset`），真正
///    读取并解析 asset 字体发生在首次匹配该 family 时。字体分组里那行
///    `TextStyle(fontFamily: 'MiSans')` 是用户未选 MiSans 时全 App 唯一的
///    MiSans 用点，于是 19MB 可变字体的读取与 typeface 创建全落在这一帧，
///    实测约 35ms。
/// 2. **色卡网格的种子配色计算** — 原因见 [SeedColorScheme]。
///
/// 预热挂在进入设置页时：此时界面静止，且用户还要再点一次才进外观页，
/// 用 idle 优先级逐项排队（每项 1~2ms），既不与转场动画抢帧，也来得及做完。
///
/// 预热的组合必须与外观页首帧实际计算的 (种子色, 亮暗, 配色风格) 严格
/// 一致，否则白预热还占缓存：
/// - 色卡网格（调色板/动态色/自定义色）：跟随当前 schemeVariant；
/// - 主题模式卡：当前生效种子 × 亮/暗两种预览；
/// - 配色风格卡：当前生效种子 × 9 种风格。
class AppearanceWarmup {
  AppearanceWarmup._();

  /// 上次预热依据的 (来源, 种子色, 配色风格, 亮暗)，用于避免重复排任务；
  /// 主题变更后签名不同，会按新配色重新预热。
  static (int, int, int, int)? _lastSignature;

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
    );
    if (signature == _lastSignature) return;
    _lastSignature = signature;

    final scheduler = SchedulerBinding.instance;
    void queue(void Function() task) =>
        scheduler.scheduleTask(task, Priority.idle);

    queue(_warmUpMiSansTypeface);

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
  }

  /// 排版一次 MiSans 文本，触发字体 asset 的读取与 typeface 创建。
  static void _warmUpMiSansTypeface() {
    TextPainter(
        text: const TextSpan(
          text: 'MiSans',
          style: TextStyle(fontFamily: 'MiSans'),
        ),
        textDirection: TextDirection.ltr,
      )
      ..layout()
      ..dispose();
  }
}
