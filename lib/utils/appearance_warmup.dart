import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../providers/theme_provider.dart';
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
/// 2. **20 多次种子配色计算** — 原因见 [SeedColorScheme]。
///
/// 预热挂在进入设置页时：此时界面静止，且用户还要再点一次才进外观页，
/// 用 idle 优先级逐项排队（每项 1~2ms），既不与转场动画抢帧，也来得及做完。
class AppearanceWarmup {
  AppearanceWarmup._();

  /// 上次预热依据的 (种子色, 配色风格, 亮暗)，用于避免重复排任务；
  /// 主题变更后签名不同，会按新配色重新预热。
  static (int, int, int)? _lastSignature;

  static void schedule({
    required ThemeState themeState,
    required Brightness brightness,
  }) {
    final effectiveSeed = themeState.useDynamicColor
        ? (themeState.dynamicPrimary ?? themeState.seedColor)
        : themeState.seedColor;
    final variant = themeState.schemeVariant;

    final signature = (
      effectiveSeed.toARGB32(),
      variant.index,
      brightness.index,
    );
    if (signature == _lastSignature) return;
    _lastSignature = signature;

    final scheduler = SchedulerBinding.instance;
    void queue(void Function() task) =>
        scheduler.scheduleTask(task, Priority.idle);

    queue(_warmUpMiSansTypeface);

    // 色卡网格：动态色 + 预设色 + 自定义色
    for (final seed in <Color>[
      effectiveSeed,
      ...ThemeNotifier.presetColors,
      ...themeState.customColors,
    ]) {
      queue(
        () => SeedColorScheme.from(
          seedColor: seed,
          brightness: brightness,
          variant: variant,
        ),
      );
    }

    // 主题模式卡的亮 / 暗预览
    for (final previewBrightness in Brightness.values) {
      queue(
        () => SeedColorScheme.from(
          seedColor: effectiveSeed,
          brightness: previewBrightness,
          variant: variant,
        ),
      );
    }

    // 配色风格卡：9 种风格
    for (final previewVariant in DynamicSchemeVariant.values) {
      queue(
        () => SeedColorScheme.from(
          seedColor: effectiveSeed,
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
