import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_model_manager/ai_model_manager.dart';

import '../../l10n/s.dart';
import '../../providers/app_icon_provider.dart';
import '../../providers/locale_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/platform_utils.dart';
import '../settings_model.dart';

/// 外观设置数据声明
List<SettingsGroup> buildAppearanceGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    // ── 语言 ──────────────────────────────────────────────────────
    SettingsGroup(
      title: l10n.appearance_language,
      icon: Icons.language_outlined,
      items: [
        CustomModel(
          id: 'language',
          title: l10n.appearance_language,
          builder: (context, ref) {
            final locale = ref.watch(localeProvider);
            final label = _localeLabel(context.l10n, locale);
            return ListTile(
              leading: Icon(
                Icons.translate,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showLanguagePicker(context, ref, locale),
            );
          },
        ),
      ],
    ),

    // ── 主题模式 ───────────────────────────────────────────────────
    SettingsGroup(
      title: l10n.appearance_themeMode,
      icon: Icons.brightness_6_outlined,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'themeMode',
          title: l10n.appearance_themeMode,
          builder: (context, ref) {
            final themeState = ref.watch(themeProvider);
            final currentMode = themeState.mode;
            final effectiveSeed = themeState.useDynamicColor
                ? (themeState.dynamicPrimary ?? themeState.seedColor)
                : themeState.seedColor;
            final theme = Theme.of(context);
            final l10n = context.l10n;

            // 为每种模式生成预览配色
            final variant = themeState.schemeVariant;
            final lightScheme = ColorScheme.fromSeed(
              seedColor: effectiveSeed,
              brightness: Brightness.light,
              dynamicSchemeVariant: variant,
            );
            final darkScheme = ColorScheme.fromSeed(
              seedColor: effectiveSeed,
              brightness: Brightness.dark,
              dynamicSchemeVariant: variant,
            );

            final modes = [
              (ThemeMode.system, Icons.auto_mode, l10n.appearance_modeAuto, null),
              (ThemeMode.light, Icons.light_mode, l10n.appearance_modeLight, lightScheme),
              (ThemeMode.dark, Icons.dark_mode, l10n.appearance_modeDark, darkScheme),
            ];

            return Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Row(
                  children: [
                    for (int i = 0; i < modes.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(
                        child: _ThemeModeCard(
                          mode: modes[i].$1,
                          icon: modes[i].$2,
                          label: modes[i].$3,
                          previewScheme: modes[i].$4,
                          lightScheme: lightScheme,
                          darkScheme: darkScheme,
                          isSelected: modes[i].$1 == currentMode,
                          currentTheme: theme,
                          onTap: () => ref
                              .read(themeProvider.notifier)
                              .setThemeMode(modes[i].$1),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ],
    ),

    // ── 主题色 ────────────────────────────────────────────────────
    SettingsGroup(
      title: l10n.appearance_themeColor,
      icon: Icons.color_lens_outlined,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'themeColor',
          title: l10n.appearance_themeColor,
          builder: (context, ref) => const _ThemeColorSection(),
        ),
      ],
    ),

    // ── 应用图标（仅 iOS/Android）────────────────────────────────
    SettingsGroup(
      title: l10n.appearance_appIcon,
      icon: Icons.app_shortcut_outlined,
      wrapInCard: false,
      items: [
        PlatformConditionalModel(
          condition: () => !kIsWeb && (Platform.isIOS || Platform.isAndroid),
          inner: CustomModel(
            id: 'appIcon',
            title: l10n.appearance_appIcon,
            builder: (context, ref) {
              final iconState = ref.watch(appIconProvider);
              final theme = Theme.of(context);
              final isDark = theme.brightness == Brightness.dark;

              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    _buildIconOption(
                      context,
                      ref,
                      style: AppIconStyle.classic,
                      label: context.l10n.appearance_iconClassic,
                      assetPath: isDark
                          ? 'assets/images/icon_default_dark_preview.png'
                          : 'assets/images/icon_default_preview.png',
                      isSelected:
                          iconState.currentStyle == AppIconStyle.classic,
                      isChanging: iconState.isChanging,
                      theme: theme,
                    ),
                    const SizedBox(width: 20),
                    _buildIconOption(
                      context,
                      ref,
                      style: AppIconStyle.modern,
                      label: context.l10n.appearance_iconModern,
                      assetPath: isDark
                          ? 'assets/images/icon_modern_preview.png'
                          : 'assets/images/icon_modern_light_preview.png',
                      isSelected:
                          iconState.currentStyle == AppIconStyle.modern,
                      isChanging: iconState.isChanging,
                      theme: theme,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),

    // ── 字体 ──────────────────────────────────────────────────────
    SettingsGroup(
      title: l10n.appearance_font,
      icon: Icons.font_download_outlined,
      items: [
        CustomModel(
          id: 'font',
          title: l10n.appearance_font,
          builder: (context, ref) {
            final fontFamily =
                ref.watch(themeProvider.select((s) => s.fontFamily));
            final l10n = context.l10n;
            final options = <(String, AppFontFamily)>[
              (l10n.appearance_fontSystem, AppFontFamily.system),
              ('MiSans', AppFontFamily.miSans),
            ];

            return RadioGroup<AppFontFamily>(
              groupValue: fontFamily,
              onChanged: (value) {
                if (value != null) {
                  ref.read(themeProvider.notifier).setFontFamily(value);
                }
              },
              child: Column(
                children: [
                  for (final (label, ff) in options)
                    RadioListTile<AppFontFamily>(
                      title: Text(
                        label,
                        style: ff == AppFontFamily.miSans
                            ? const TextStyle(fontFamily: 'MiSans')
                            : null,
                      ),
                      value: ff,
                    ),
                ],
              ),
            );
          },
        ),
      ],
    ),

    // ── 屏幕帧率（仅 Android）──────────────────────────────────────
    SettingsGroup(
      title: l10n.appearance_displayMode,
      icon: Icons.monitor_outlined,
      items: [
        PlatformConditionalModel(
          condition: () => !kIsWeb && Platform.isAndroid,
          inner: ActionModel(
            id: 'displayMode',
            title: l10n.appearance_displayMode,
            icon: Icons.monitor_heart_outlined,
            getDynamicSubtitle: (ref) {
              final rate = ref
                  .watch(preferencesProvider)
                  .displayModeRefreshRate;
              return rate == 0
                  ? context.l10n.appearance_displayModeAuto
                  : '${rate}Hz';
            },
            onTap: (context, ref) => _showDisplayModeSheet(context, ref),
          ),
        ),
      ],
    ),

    // ── 对话框模糊 ──────────────────────────────────────────────────
    SettingsGroup(
      title: l10n.appearance_dialogBlur,
      icon: Icons.blur_on_outlined,
      items: [
        SwitchModel(
          id: 'dialogBlur',
          title: l10n.appearance_dialogBlur,
          subtitle: l10n.appearance_dialogBlurDesc,
          icon: Icons.blur_on_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).dialogBlur,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setDialogBlur(v),
        ),
      ],
    ),
  ];
}

// ── 语言选择器辅助函数 ───────────────────────────────────────────

void _showLanguagePicker(
  BuildContext context,
  WidgetRef ref,
  Locale? currentLocale,
) {
  final l10n = context.l10n;
  final options = <(String, Locale?)>[
    (l10n.appearance_languageSystem, null),
    (l10n.appearance_languageZhCN, const Locale('zh', 'CN')),
    (l10n.appearance_languageZhTW, const Locale('zh', 'TW')),
    (l10n.appearance_languageZhHK, const Locale('zh', 'HK')),
    (l10n.appearance_languageEn, const Locale('en', 'US')),
  ];

  showAppBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, locale) in options)
              ListTile(
                title: Text(label),
                trailing: _localeKey(locale) == _localeKey(currentLocale)
                    ? Icon(
                        Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  ref.read(localeProvider.notifier).setLocale(locale);
                  final effectiveLocale =
                      locale ??
                      WidgetsBinding.instance.platformDispatcher.locale;
                  AiL10n.configureLocale(effectiveLocale);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      );
    },
  );
}

// ── 屏幕帧率选择器（仅 Android）────────────────────────────────

Future<void> _showDisplayModeSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  await showAppBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _DisplayModeSheetBody(),
  );
}

class _DisplayModeSheetBody extends ConsumerStatefulWidget {
  const _DisplayModeSheetBody();

  @override
  ConsumerState<_DisplayModeSheetBody> createState() =>
      _DisplayModeSheetBodyState();
}

class _DisplayModeSheetBodyState
    extends ConsumerState<_DisplayModeSheetBody> {
  late Future<_DisplayModeData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DisplayModeData> _load() async {
    final modes = await FlutterDisplayMode.supported;
    final active = await FlutterDisplayMode.active;
    return _DisplayModeData(modes: modes, active: active);
  }

  Future<void> _apply(int rate, List<DisplayMode> modes, DisplayMode active) async {
    await ref
        .read(preferencesProvider.notifier)
        .setDisplayModeRefreshRate(rate);
    try {
      if (rate == 0) {
        await FlutterDisplayMode.setPreferredMode(DisplayMode.auto);
      } else {
        final matches = modes
            .where((m) => m.refreshRate.round() == rate)
            .toList();
        if (matches.isNotEmpty) {
          final picked = matches.firstWhere(
            (m) => m.width == active.width && m.height == active.height,
            orElse: () => matches.first,
          );
          await FlutterDisplayMode.setPreferredMode(picked);
        }
      }
    } catch (e) {
      debugPrint('[DisplayMode] 切换刷新率失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return SafeArea(
      child: FutureBuilder<_DisplayModeData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError || snapshot.data == null) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                snapshot.error?.toString() ?? 'unknown error',
                style: theme.textTheme.bodyMedium,
              ),
            );
          }

          final data = snapshot.data!;
          final currentRate =
              ref.watch(preferencesProvider).displayModeRefreshRate;

          // 去重 + 高到低排序
          final uniqueRates = <int>{};
          for (final m in data.modes) {
            uniqueRates.add(m.refreshRate.round());
          }
          final sortedRates = uniqueRates.toList()
            ..sort((a, b) => b.compareTo(a));

          final activeRate = data.active.refreshRate.round();

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  l10n.appearance_displayMode,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: SingleChildScrollView(
                  child: RadioGroup<int>(
                    groupValue: currentRate,
                    onChanged: (value) async {
                      if (value == null) return;
                      await _apply(value, data.modes, data.active);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<int>(
                          value: 0,
                          title: Text(l10n.appearance_displayModeAuto),
                        ),
                        for (final rate in sortedRates)
                          RadioListTile<int>(
                            value: rate,
                            title: Text(
                              rate == activeRate
                                  ? '${rate}Hz  ·  [${l10n.appearance_languageSystem}]'
                                  : '${rate}Hz',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  l10n.appearance_displayModeRestartHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DisplayModeData {
  final List<DisplayMode> modes;
  final DisplayMode active;

  _DisplayModeData({required this.modes, required this.active});
}

String _localeLabel(AppLocalizations l10n, Locale? locale) {
  if (locale == null) return l10n.appearance_languageSystem;
  switch ('${locale.languageCode}_${locale.countryCode}') {
    case 'zh_CN':
      return l10n.appearance_languageZhCN;
    case 'zh_TW':
      return l10n.appearance_languageZhTW;
    case 'zh_HK':
      return l10n.appearance_languageZhHK;
    case 'en_US':
      return l10n.appearance_languageEn;
    default:
      return l10n.appearance_languageSystem;
  }
}

String _localeKey(Locale? locale) {
  if (locale == null) return 'system';
  return locale.countryCode != null
      ? '${locale.languageCode}_${locale.countryCode}'
      : locale.languageCode;
}

// ── 应用图标辅助函数 ──────────────────────────────────────────────

Widget _buildIconOption(
  BuildContext context,
  WidgetRef ref, {
  required AppIconStyle style,
  required String label,
  required String assetPath,
  required bool isSelected,
  required bool isChanging,
  required ThemeData theme,
}) {
  return GestureDetector(
    onTap: isChanging
        ? null
        : () async {
            final l10n = context.l10n;
            final success =
                await ref.read(appIconProvider.notifier).setIconStyle(style);
            if (!success) {
              ToastService.showError(l10n.appearance_switchIconFailed);
            }
          },
    child: Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary
                  : Colors.transparent,
              width: 2.5,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                Image.asset(
                  assetPath,
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                ),
                if (isChanging && isSelected)
                  Container(
                    width: 72,
                    height: 72,
                    color: Colors.black26,
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ],
    ),
  );
}

/// 主题模式选择卡片
///
/// 顶部绘制一个迷你 "屏幕" 模拟该模式下的配色，
/// 底部显示图标和文字，选中态高亮边框 + 勾选角标。
class _ThemeModeCard extends StatelessWidget {
  final ThemeMode mode;
  final IconData icon;
  final String label;

  /// 该模式对应的配色方案，system 模式为 null（需同时展示 light + dark）
  final ColorScheme? previewScheme;
  final ColorScheme lightScheme;
  final ColorScheme darkScheme;
  final bool isSelected;
  final ThemeData currentTheme;
  final VoidCallback onTap;

  const _ThemeModeCard({
    required this.mode,
    required this.icon,
    required this.label,
    required this.previewScheme,
    required this.lightScheme,
    required this.darkScheme,
    required this.isSelected,
    required this.currentTheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = currentTheme.colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: isSelected
              ? cs.secondaryContainer.withValues(alpha: 0.5)
              : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? cs.primary
                : cs.outlineVariant.withValues(alpha: 0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            // 迷你屏幕预览
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
              child: _buildPreview(),
            ),
            const SizedBox(height: 8),
            // 图标 + 文字
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: isSelected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: currentTheme.textTheme.labelSmall?.copyWith(
                      color: isSelected ? cs.primary : cs.onSurfaceVariant,
                      fontWeight:
                          isSelected ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 绘制迷你屏幕预览
  Widget _buildPreview() {
    if (mode == ThemeMode.system) {
      // 跟随系统：同一个屏幕，左半亮色右半暗色
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 64,
          child: CustomPaint(
            painter: _SplitThemePreviewPainter(
              lightScheme: lightScheme,
              darkScheme: darkScheme,
            ),
            size: Size.infinite,
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: 64,
        child: _buildMiniScreen(previewScheme!),
      ),
    );
  }

  /// 单个迷你屏幕：模拟 app bar + 内容行
  Widget _buildMiniScreen(ColorScheme scheme) {
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模拟 app bar
          Container(
            height: 10,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Row(
              children: [
                const SizedBox(width: 3),
                Container(
                  width: 16,
                  height: 5,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          // 模拟内容行
          _buildContentLine(scheme, 0.7),
          const SizedBox(height: 2),
          _buildContentLine(scheme, 0.5),
          const SizedBox(height: 2),
          // 模拟按钮
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              width: 14,
              height: 6,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildContentLine(ColorScheme scheme, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 4,
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 跟随系统预览：同一个屏幕背景，左半亮色右半暗色，
/// UI 元素在分界线处自然切换颜色。
class _SplitThemePreviewPainter extends CustomPainter {
  final ColorScheme lightScheme;
  final ColorScheme darkScheme;

  _SplitThemePreviewPainter({
    required this.lightScheme,
    required this.darkScheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midX = size.width / 2;
    final paint = Paint();

    // ── 背景：左亮右暗 ──
    paint.color = lightScheme.surface;
    canvas.drawRect(Rect.fromLTRB(0, 0, midX, size.height), paint);
    paint.color = darkScheme.surface;
    canvas.drawRect(Rect.fromLTRB(midX, 0, size.width, size.height), paint);

    final pad = 4.0;

    // ── app bar 背景条 ──
    _drawSplitRRect(
      canvas, size,
      rect: Rect.fromLTWH(pad, pad, size.width - pad * 2, 10),
      radius: 3,
      lightColor: lightScheme.surfaceContainerHighest,
      darkColor: darkScheme.surfaceContainerHighest,
    );

    // ── app bar 标题 ──
    _drawSplitRRect(
      canvas, size,
      rect: Rect.fromLTWH(pad + 3, pad + 2.5, 16, 5),
      radius: 2,
      lightColor: lightScheme.onSurface.withValues(alpha: 0.6),
      darkColor: darkScheme.onSurface.withValues(alpha: 0.6),
    );

    // ── 内容行 1 ──
    final y1 = pad + 13.0;
    _drawSplitRRect(
      canvas, size,
      rect: Rect.fromLTWH(pad, y1, (size.width - pad * 2) * 0.7, 4),
      radius: 2,
      lightColor: lightScheme.onSurface.withValues(alpha: 0.15),
      darkColor: darkScheme.onSurface.withValues(alpha: 0.15),
    );

    // ── 内容行 2 ──
    final y2 = y1 + 6;
    _drawSplitRRect(
      canvas, size,
      rect: Rect.fromLTWH(pad, y2, (size.width - pad * 2) * 0.5, 4),
      radius: 2,
      lightColor: lightScheme.onSurface.withValues(alpha: 0.15),
      darkColor: darkScheme.onSurface.withValues(alpha: 0.15),
    );

    // ── 按钮 ──
    final btnW = 14.0;
    final btnH = 6.0;
    final btnY = y2 + 8;
    _drawSplitRRect(
      canvas, size,
      rect: Rect.fromLTWH(size.width - pad - btnW, btnY, btnW, btnH),
      radius: 3,
      lightColor: lightScheme.primary,
      darkColor: darkScheme.primary,
    );

    // ── 中线分隔（半透明细线，暗示分界）──
    paint
      ..color = lightScheme.outline.withValues(alpha: 0.1)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(midX, 0), Offset(midX, size.height), paint);
  }

  /// 绘制一个跨越亮暗分界的圆角矩形，
  /// 左半用 lightColor，右半用 darkColor。
  void _drawSplitRRect(
    Canvas canvas,
    Size size, {
    required Rect rect,
    required double radius,
    required Color lightColor,
    required Color darkColor,
  }) {
    final midX = size.width / 2;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final paint = Paint();

    // 左半（亮色）
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, midX, size.height));
    paint.color = lightColor;
    canvas.drawRRect(rrect, paint);
    canvas.restore();

    // 右半（暗色）
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(midX, 0, size.width, size.height));
    paint.color = darkColor;
    canvas.drawRRect(rrect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SplitThemePreviewPainter oldDelegate) {
    return oldDelegate.lightScheme != lightScheme ||
        oldDelegate.darkScheme != darkScheme;
  }
}

// ══════════════════════════════════════════════════════════════════
// 主题色选择器
// ══════════════════════════════════════════════════════════════════

class _ThemeColorSection extends ConsumerStatefulWidget {
  const _ThemeColorSection();

  @override
  ConsumerState<_ThemeColorSection> createState() => _ThemeColorSectionState();
}

class _ThemeColorSectionState extends ConsumerState<_ThemeColorSection> {
  Color? _removableColor;
  final ScrollController _variantScrollCtrl = ScrollController();
  bool _didInitialScroll = false;

  @override
  void dispose() {
    _variantScrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToSelectedVariant(DynamicSchemeVariant variant) {
    if (!_variantScrollCtrl.hasClients) return;
    final index = DynamicSchemeVariant.values.indexOf(variant);
    const itemW = 96.0;
    const gap = 10.0;
    final targetOffset = index * (itemW + gap);
    final viewport = _variantScrollCtrl.position.viewportDimension;
    final maxScroll = _variantScrollCtrl.position.maxScrollExtent;
    // 尽量让选中项居中显示
    final centered = (targetOffset - (viewport - itemW) / 2).clamp(0.0, maxScroll);
    _variantScrollCtrl.animateTo(
      centered,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDynamic = themeState.useDynamicColor;
    final currentColor = themeState.seedColor;
    final variant = themeState.schemeVariant;
    final customColors = themeState.customColors;
    final dynamicPrimary = themeState.dynamicPrimary;

    final effectiveSeed = isDynamic
        ? (dynamicPrimary ?? cs.primary)
        : currentColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 配色风格横向滚动 ──
        Text(
          context.l10n.appearance_schemeVariant,
          style: theme.textTheme.titleSmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 76,
          child: ShaderMask(
            shaderCallback: (Rect rect) {
              return const LinearGradient(
                colors: [Colors.black, Colors.black, Colors.transparent],
                stops: [0.0, 0.88, 1.0],
              ).createShader(rect);
            },
            blendMode: BlendMode.dstIn,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 首次构建后自动滚动到选中项
                if (!_didInitialScroll) {
                  _didInitialScroll = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollToSelectedVariant(variant);
                  });
                }
                return ListView.separated(
                  controller: _variantScrollCtrl,
                  scrollDirection: Axis.horizontal,
                  itemCount: DynamicSchemeVariant.values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  // 右侧额外留白让渐隐效果下最后一项完整可见
                  padding: const EdgeInsets.only(right: 48),
                  itemBuilder: (context, index) {
                    final v = DynamicSchemeVariant.values[index];
                    return _VariantChip(
                      variant: v,
                      seedColor: effectiveSeed,
                      isSelected: v == variant,
                      label: _variantLabel(context, v),
                      onTap: () {
                        ref.read(themeProvider.notifier).setSchemeVariant(v);
                        _scrollToSelectedVariant(v);
                      },
                    );
                  },
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 24),

        // ── 颜色网格 ──
        LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth;
            final columns = (maxWidth / 88).floor().clamp(3, 6);
            const spacing = 14.0;
            final itemWidth =
                (maxWidth - (columns - 1) * spacing) / columns;

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                // 动态色
                _ColorSwatchCard(
                  size: itemWidth,
                  isSelected: isDynamic,
                  isDynamic: true,
                  dynamicPrimary: dynamicPrimary,
                  variant: variant,
                  onTap: () {
                    setState(() => _removableColor = null);
                    ref.read(themeProvider.notifier).setUseDynamicColor(true);
                  },
                ),
                // 预设色
                for (final color in ThemeNotifier.presetColors)
                  _ColorSwatchCard(
                    size: itemWidth,
                    seedColor: color,
                    isSelected: !isDynamic &&
                        color.toARGB32() == currentColor.toARGB32(),
                    variant: variant,
                    onTap: () {
                      setState(() => _removableColor = null);
                      ref.read(themeProvider.notifier).setSeedColor(color);
                    },
                  ),
                // 自定义色
                for (final color in customColors)
                  SizedBox(
                    width: itemWidth,
                    height: itemWidth,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        _ColorSwatchCard(
                          size: itemWidth,
                          seedColor: color,
                          isSelected: !isDynamic &&
                              color.toARGB32() == currentColor.toARGB32(),
                          variant: variant,
                          onTap: () {
                            setState(() => _removableColor = null);
                            ref
                                .read(themeProvider.notifier)
                                .setSeedColor(color);
                          },
                          onLongPress: () =>
                              setState(() => _removableColor = color),
                        ),
                        if (_removableColor?.toARGB32() == color.toARGB32())
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: IconButton.filledTonal(
                              onPressed: () {
                                ref
                                    .read(themeProvider.notifier)
                                    .removeCustomColor(color);
                                setState(() => _removableColor = null);
                              },
                              iconSize: 28,
                              icon: Icon(Icons.delete, color: cs.primary),
                            ),
                          ),
                      ],
                    ),
                  ),
                // 添加按钮
                if (_removableColor == null)
                  SizedBox(
                    width: itemWidth,
                    height: itemWidth,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: IconButton.filledTonal(
                        onPressed: () => _showColorPicker(context),
                        iconSize: 28,
                        icon: Icon(Icons.add, color: cs.primary),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  // ── 自定义取色弹框 ──

  void _showColorPicker(BuildContext context) {
    double hue = 0;
    double saturation = 0.8;
    double value = 0.9;
    final hexController = TextEditingController(text: 'E57373');

    void syncHex() {
      final color =
          HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
      hexController.text = color
          .toARGB32()
          .toRadixString(16)
          .substring(2)
          .toUpperCase();
    }

    syncHex();

    showAppBottomSheet<Color>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final color =
                HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
            final variant = ref.read(themeProvider).schemeVariant;
            final scheme = ColorScheme.fromSeed(
              seedColor: color,
              dynamicSchemeVariant: variant,
              brightness: Theme.of(context).brightness,
            );

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 配色预览 + HEX
                    Row(
                      children: [
                        // 迷你色卡（与网格色卡完全一致的比例和样式）
                        Container(
                          width: 60,
                          height: 60,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: scheme.primary,
                              width: 2,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                flex: 7,
                                child: ColoredBox(color: scheme.primary),
                              ),
                              Expanded(
                                flex: 3,
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _miniDot(scheme.primary),
                                      const SizedBox(width: 5),
                                      _miniDot(scheme.secondary),
                                      const SizedBox(width: 5),
                                      _miniDot(scheme.tertiary),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // HEX 输入
                              Row(
                                children: [
                                  Text(
                                    '#',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w500,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: TextField(
                                      controller: hexController,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w500,
                                            fontFamily: 'monospace',
                                          ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      onSubmitted: (hex) {
                                        final parsed = int.tryParse(
                                            'FF$hex', radix: 16);
                                        if (parsed != null) {
                                          final c = Color(parsed);
                                          final hsv = HSVColor.fromColor(c);
                                          setSheetState(() {
                                            hue = hsv.hue;
                                            saturation = hsv.saturation;
                                            value = hsv.value;
                                          });
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'H:${hue.round()}\u00B0  '
                                'S:${(saturation * 100).round()}%  '
                                'B:${(value * 100).round()}%',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 色相条
                    _HueBar(
                      hue: hue,
                      onChanged: (h) {
                        setSheetState(() => hue = h);
                        syncHex();
                      },
                    ),
                    const SizedBox(height: 16),

                    // 饱和度
                    _GradientSlider(
                      label: 'S',
                      value: saturation,
                      thumbColor: HSVColor.fromAHSV(1, hue, saturation, 1)
                          .toColor(),
                      gradientColors: [
                        HSVColor.fromAHSV(1, hue, 0, value).toColor(),
                        HSVColor.fromAHSV(1, hue, 1, value).toColor(),
                      ],
                      onChanged: (s) {
                        setSheetState(() => saturation = s);
                        syncHex();
                      },
                    ),
                    const SizedBox(height: 12),

                    // 明度
                    _GradientSlider(
                      label: 'B',
                      value: value,
                      thumbColor: HSVColor.fromAHSV(1, hue, saturation, value)
                          .toColor(),
                      gradientColors: [
                        HSVColor.fromAHSV(1, hue, saturation, 0).toColor(),
                        HSVColor.fromAHSV(1, hue, saturation, 1).toColor(),
                      ],
                      onChanged: (v) {
                        setSheetState(() => value = v);
                        syncHex();
                      },
                    ),
                    const SizedBox(height: 24),

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(sheetContext, color),
                        child: Text(context.l10n.common_confirm),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((color) {
      if (color != null) {
        ref.read(themeProvider.notifier).addCustomColor(color);
        ref.read(themeProvider.notifier).setSeedColor(color);
      }
      // 延迟释放 controller，等待退场动画结束
      // （.then 在 didPop 时触发，此时退场动画仍在进行，
      //  主题重建会导致弹窗中的 TextField 重建并访问 controller）
      Future.delayed(const Duration(milliseconds: 350), () {
        hexController.dispose();
      });
    });
  }

  static Widget _miniDot(Color color) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  String _variantLabel(BuildContext context, DynamicSchemeVariant v) {
    final l10n = context.l10n;
    return switch (v) {
      DynamicSchemeVariant.tonalSpot => l10n.schemeVariant_tonalSpot,
      DynamicSchemeVariant.fidelity => l10n.schemeVariant_fidelity,
      DynamicSchemeVariant.monochrome => l10n.schemeVariant_monochrome,
      DynamicSchemeVariant.neutral => l10n.schemeVariant_neutral,
      DynamicSchemeVariant.vibrant => l10n.schemeVariant_vibrant,
      DynamicSchemeVariant.expressive => l10n.schemeVariant_expressive,
      DynamicSchemeVariant.content => l10n.schemeVariant_content,
      DynamicSchemeVariant.rainbow => l10n.schemeVariant_rainbow,
      DynamicSchemeVariant.fruitSalad => l10n.schemeVariant_fruitSalad,
    };
  }
}

// ══════════════════════════════════════════════════════════════════
// 配色风格横向滚动卡片
// ══════════════════════════════════════════════════════════════════

class _VariantChip extends StatelessWidget {
  final DynamicSchemeVariant variant;
  final Color seedColor;
  final bool isSelected;
  final String label;
  final VoidCallback onTap;

  const _VariantChip({
    required this.variant,
    required this.seedColor,
    required this.isSelected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      dynamicSchemeVariant: variant,
      brightness: Theme.of(context).brightness,
    );

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 96,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? scheme.primary : cs.outlineVariant.withValues(alpha: 0.3),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // primary 色块 — 填满剩余空间
            Expanded(child: ColoredBox(color: scheme.primary)),
            // 配色圆点
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _dot(scheme.primary, 5),
                  const SizedBox(width: 3),
                  _dot(scheme.secondary, 5),
                  const SizedBox(width: 3),
                  _dot(scheme.tertiary, 5),
                ],
              ),
            ),
            // 标签
            Padding(
              padding: const EdgeInsets.only(bottom: 5, left: 4, right: 4),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: isSelected ? scheme.primary : cs.onSurfaceVariant,
                      fontWeight:
                          isSelected ? FontWeight.w500 : FontWeight.normal,
                    ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _dot(Color color, double d) {
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 色卡（选色网格中的单张色卡，上方 primary 填充，下方 3 配色圆点）
// ══════════════════════════════════════════════════════════════════

class _ColorSwatchCard extends StatelessWidget {
  final double size;
  final Color? seedColor;
  final bool isSelected;
  final bool isDynamic;
  final Color? dynamicPrimary;
  final DynamicSchemeVariant variant;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ColorSwatchCard({
    required this.size,
    this.seedColor,
    required this.isSelected,
    this.isDynamic = false,
    this.dynamicPrimary,
    required this.variant,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveSeed = isDynamic
        ? (dynamicPrimary ?? Theme.of(context).colorScheme.primary)
        : seedColor!;
    final tileScheme = ColorScheme.fromSeed(
      seedColor: effectiveSeed,
      dynamicSchemeVariant: variant,
      brightness: Theme.of(context).brightness,
    );

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: PlatformUtils.isDesktop ? onLongPress : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: tileScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? tileScheme.primary : tileScheme.outlineVariant.withValues(alpha: 0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
          child: Column(
          children: [
            // 上方 ~70%: primary 色填充
            Expanded(
              flex: 7,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: tileScheme.primary),
                  if (isSelected)
                    Container(
                      color: Colors.black.withValues(alpha: 0.12),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.check_circle_rounded,
                        color: tileScheme.onPrimary,
                        size: 26,
                      ),
                    ),
                  // 动态色标识（右上角）
                  if (isDynamic)
                    Positioned(
                      top: 5,
                      right: 5,
                      child: Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: tileScheme.onPrimary.withValues(alpha: 0.85),
                      ),
                    ),
                ],
              ),
            ),
            // 下方 ~30%: 配色圆点（所有色卡样式统一）
            Expanded(
              flex: 3,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _colorDot(tileScheme.primary),
                    const SizedBox(width: 5),
                    _colorDot(tileScheme.secondary),
                    const SizedBox(width: 5),
                    _colorDot(tileScheme.tertiary),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _colorDot(Color color) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 色相条（彩虹渐变 + 滑块）
// ══════════════════════════════════════════════════════════════════

class _HueBar extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HueBar({required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ),
      ),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 36,
          trackShape: const _TransparentTrackShape(),
          thumbShape: _HueThumbShape(
            color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
          ),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
        ),
        child: Slider(
          value: hue,
          min: 0,
          max: 360,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _HueThumbShape extends SliderComponentShape {
  final Color color;
  const _HueThumbShape({required this.color});

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size(28, 28);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    // 外圈白色描边
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(center, 14, Paint()..color = Colors.white);
    // 内圈填充色
    canvas.drawCircle(center, 11, Paint()..color = color);
  }
}

// ══════════════════════════════════════════════════════════════════
// 渐变滑块（饱和度 / 明度）
// ══════════════════════════════════════════════════════════════════

class _GradientSlider extends StatelessWidget {
  final String label;
  final double value;
  final Color thumbColor;
  final List<Color> gradientColors;
  final ValueChanged<double> onChanged;

  const _GradientSlider({
    required this.label,
    required this.value,
    required this.thumbColor,
    required this.gradientColors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(colors: gradientColors),
            ),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 28,
                trackShape: const _TransparentTrackShape(),
                thumbShape: _HueThumbShape(color: thumbColor),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 18),
              ),
              child: Slider(
                value: value,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(value * 100).round()}%',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.primary,
            ),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

/// 透明轨道，让渐变背景可见
class _TransparentTrackShape extends RoundedRectSliderTrackShape {
  const _TransparentTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    // 不绘制，让背景渐变可见
  }
}
