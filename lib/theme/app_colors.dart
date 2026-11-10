import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderPalette;
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

import 'color_contrast.dart';

/// 主题语义色：ColorScheme 之外、随主题变化的颜色。
///
/// - 具名色相（[red]、[blue]……）：替代代码里直接写的 `Colors.red` 等，
///   保留 Material 色板的深浅档（`shade300`）写法；
/// - 代码块：底色与语法高亮表。
///
/// 生成式主题（Material / 简约）用 [AppColors.material]：色相就是
/// Flutter 的 `Colors.*` 原色板、高亮沿用 GitHub 配色，与引入本类之前
/// 逐像素一致。固定配色主题用 [AppColors.fromHues] 从主题色相表生成。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.hues,
    required this.accents,
    required this.codeBackground,
    required this.syntax,
    this.render = const FluxdoRenderPalette(),
  });

  /// 具名色相的完整色板。
  final Map<AppHue, MaterialColor> hues;

  /// 具名色相的强调色板（对应 `Colors.redAccent` 等）。
  final Map<AppHue, MaterialAccentColor> accents;

  /// 代码块底色。
  final Color codeBackground;

  /// 语法高亮表（scope → 样式，结构与 re_highlight 内置主题一致）。
  final Map<String, TextStyle> syntax;

  /// 注入渲染引擎的语义色（callout、点击数徽标）。
  final FluxdoRenderPalette render;

  MaterialColor get red => hues[AppHue.red]!;
  MaterialColor get pink => hues[AppHue.pink]!;
  MaterialColor get purple => hues[AppHue.purple]!;
  MaterialColor get deepPurple => hues[AppHue.deepPurple]!;
  MaterialColor get indigo => hues[AppHue.indigo]!;
  MaterialColor get blue => hues[AppHue.blue]!;
  MaterialColor get lightBlue => hues[AppHue.lightBlue]!;
  MaterialColor get cyan => hues[AppHue.cyan]!;
  MaterialColor get teal => hues[AppHue.teal]!;
  MaterialColor get green => hues[AppHue.green]!;
  MaterialColor get lightGreen => hues[AppHue.lightGreen]!;
  MaterialColor get lime => hues[AppHue.lime]!;
  MaterialColor get yellow => hues[AppHue.yellow]!;
  MaterialColor get amber => hues[AppHue.amber]!;
  MaterialColor get orange => hues[AppHue.orange]!;
  MaterialColor get deepOrange => hues[AppHue.deepOrange]!;
  MaterialColor get brown => hues[AppHue.brown]!;
  MaterialColor get grey => hues[AppHue.grey]!;
  MaterialColor get blueGrey => hues[AppHue.blueGrey]!;

  MaterialAccentColor get redAccent => accents[AppHue.red]!;
  MaterialAccentColor get orangeAccent => accents[AppHue.orange]!;
  MaterialAccentColor get greenAccent => accents[AppHue.green]!;
  MaterialAccentColor get lightGreenAccent => accents[AppHue.lightGreen]!;

  /// Material 默认语义色（生成式主题）。
  factory AppColors.material(Brightness brightness) =>
      brightness == Brightness.light ? _materialLight : _materialDark;

  static final AppColors _materialLight = AppColors(
    hues: _materialHues,
    accents: _materialAccents,
    codeBackground: const Color(0xfff6f8fa),
    syntax: githubTheme,
  );

  static final AppColors _materialDark = AppColors(
    hues: _materialHues,
    accents: _materialAccents,
    codeBackground: const Color(0xff282a36),
    syntax: githubDarkTheme,
  );

  static const Map<AppHue, MaterialColor> _materialHues = {
    AppHue.red: Colors.red,
    AppHue.pink: Colors.pink,
    AppHue.purple: Colors.purple,
    AppHue.deepPurple: Colors.deepPurple,
    AppHue.indigo: Colors.indigo,
    AppHue.blue: Colors.blue,
    AppHue.lightBlue: Colors.lightBlue,
    AppHue.cyan: Colors.cyan,
    AppHue.teal: Colors.teal,
    AppHue.green: Colors.green,
    AppHue.lightGreen: Colors.lightGreen,
    AppHue.lime: Colors.lime,
    AppHue.yellow: Colors.yellow,
    AppHue.amber: Colors.amber,
    AppHue.orange: Colors.orange,
    AppHue.deepOrange: Colors.deepOrange,
    AppHue.brown: Colors.brown,
    AppHue.grey: Colors.grey,
    AppHue.blueGrey: Colors.blueGrey,
  };

  static const Map<AppHue, MaterialAccentColor> _materialAccents = {
    AppHue.red: Colors.redAccent,
    AppHue.orange: Colors.orangeAccent,
    AppHue.green: Colors.greenAccent,
    AppHue.lightGreen: Colors.lightGreenAccent,
  };

  /// 由固定配色主题的色相表生成。
  ///
  /// [base] 是主题提供的七个基础色相（红橙黄绿青蓝紫），其余具名色相
  /// 由相邻基础色相混合得到；灰阶来自主题的前景/背景，不带额外色相。
  /// 每个色相按 Material 色板的明暗档位展开：shade500 是主题原色，
  /// 往浅档与白混合、往深档与黑混合，调用方的 `shade300` 等写法照旧可用。
  factory AppColors.fromHues({
    required Map<AppHue, Color> base,
    required Brightness brightness,
    required Color surface,
    required Color onSurface,
    required Color onSurfaceVariant,
    required Color codeBackground,
  }) {
    // 色相常被直接当图标/文字色画在背景上，至少保证非文本对比度
    Color fit(Color c) => ColorContrast.ensure(c, surface, ColorContrast.graphic);
    Color pick(AppHue hue) => fit(base[hue]!);
    Color mix(AppHue a, AppHue b, double t) => Color.lerp(pick(a), pick(b), t)!;
    final grey = Color.lerp(onSurfaceVariant, surface, 0.25)!;
    final resolved = <AppHue, Color>{
      for (final hue in AppHue.basics) hue: pick(hue),
      AppHue.pink: base[AppHue.pink] != null
          ? pick(AppHue.pink)
          : mix(AppHue.red, AppHue.purple, 0.5),
      AppHue.deepPurple: mix(AppHue.purple, AppHue.blue, 0.2),
      AppHue.indigo: mix(AppHue.blue, AppHue.purple, 0.45),
      AppHue.lightBlue: mix(AppHue.cyan, AppHue.blue, 0.5),
      AppHue.teal: base[AppHue.teal] != null
          ? pick(AppHue.teal)
          : mix(AppHue.green, AppHue.cyan, 0.5),
      AppHue.lightGreen: mix(AppHue.green, AppHue.yellow, 0.3),
      AppHue.lime: mix(AppHue.yellow, AppHue.green, 0.35),
      AppHue.amber: mix(AppHue.yellow, AppHue.orange, 0.4),
      AppHue.deepOrange: mix(AppHue.orange, AppHue.red, 0.5),
      AppHue.brown: Color.lerp(pick(AppHue.orange), grey, 0.55)!,
      AppHue.grey: grey,
      AppHue.blueGrey: Color.lerp(grey, pick(AppHue.blue), 0.2)!,
    };
    final hues = {
      for (final e in resolved.entries) e.key: _swatch(e.value),
    };
    return AppColors(
      hues: hues,
      accents: {
        for (final hue in const [
          AppHue.red,
          AppHue.orange,
          AppHue.green,
          AppHue.lightGreen,
        ])
          hue: _accentSwatch(hues[hue]!),
      },
      codeBackground: codeBackground,
      render: FluxdoRenderPalette(
        blue: resolved[AppHue.blue]!,
        cyan: resolved[AppHue.cyan]!,
        teal: resolved[AppHue.teal]!,
        green: resolved[AppHue.green]!,
        orange: resolved[AppHue.orange]!,
        red: resolved[AppHue.red]!,
        purple: resolved[AppHue.purple]!,
        grey: grey,
        clickCountBackground: Color.alphaBlend(
          onSurfaceVariant.withValues(alpha: 0.14),
          surface,
        ),
        clickCountForeground: onSurfaceVariant,
      ),
      syntax: _syntaxFrom(
        resolved,
        fg: onSurface,
        muted: onSurfaceVariant,
        background: codeBackground,
      ),
    );
  }

  /// 以 [base] 为 shade500 展开 Material 档位。
  static MaterialColor _swatch(Color base) {
    Color over(Color tint, double t) =>
        Color.alphaBlend(tint.withValues(alpha: t), base);
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);
    return MaterialColor(base.toARGB32(), {
      50: over(white, 0.90),
      100: over(white, 0.78),
      200: over(white, 0.60),
      300: over(white, 0.40),
      400: over(white, 0.20),
      500: base,
      600: over(black, 0.10),
      700: over(black, 0.22),
      800: over(black, 0.34),
      900: over(black, 0.48),
    });
  }

  static MaterialAccentColor _accentSwatch(MaterialColor swatch) =>
      MaterialAccentColor(swatch.shade300.toARGB32(), {
        100: swatch.shade100,
        200: swatch.shade300,
        400: swatch.shade500,
        700: swatch.shade700,
      });

  /// 按 GitHub 主题的 scope 分组生成高亮表，颜色换成主题色相。
  /// 所有前景色对代码块底色补足正文对比度。
  static Map<String, TextStyle> _syntaxFrom(
    Map<AppHue, Color> hues, {
    required Color fg,
    required Color muted,
    required Color background,
  }) {
    TextStyle c(Color color, {FontWeight? weight, FontStyle? style}) =>
        TextStyle(
          color: ColorContrast.ensure(color, background, ColorContrast.text),
          fontWeight: weight,
          fontStyle: style,
        );
    final keyword = c(hues[AppHue.purple]!);
    final type = c(hues[AppHue.yellow]!);
    final function = c(hues[AppHue.blue]!);
    final attr = c(hues[AppHue.cyan]!);
    final number = c(hues[AppHue.orange]!);
    final string = c(hues[AppHue.green]!);
    final tag = c(hues[AppHue.red]!);
    final comment = c(muted, style: FontStyle.italic);
    final plain = c(fg);
    return {
      'root': plain,
      'doctag': keyword,
      'keyword': keyword,
      'meta-keyword': keyword,
      'template-tag': keyword,
      'template-variable': keyword,
      'variable.language_': keyword,
      'type': type,
      'built_in': type,
      'title.class_': type,
      'title.class_.inherited__': type,
      'title': function,
      'title.function_': function,
      'section': c(hues[AppHue.blue]!, weight: FontWeight.bold),
      'attr': attr,
      'attribute': attr,
      'meta': attr,
      'operator': attr,
      'selector-attr': attr,
      'selector-class': attr,
      'selector-id': attr,
      'selector-pseudo': attr,
      'literal': number,
      'number': number,
      'symbol': number,
      'bullet': number,
      'regexp': string,
      'string': string,
      'meta-string': string,
      'name': tag,
      'selector-tag': tag,
      'comment': comment,
      'code': comment,
      'formula': comment,
      'quote': comment,
      'variable': plain,
      'subst': plain,
      'emphasis': c(fg, style: FontStyle.italic),
      'strong': c(fg, weight: FontWeight.bold),
      'addition': string.copyWith(
        backgroundColor: hues[AppHue.green]!.withValues(alpha: 0.15),
      ),
      'deletion': tag.copyWith(
        backgroundColor: hues[AppHue.red]!.withValues(alpha: 0.15),
      ),
    };
  }

  @override
  AppColors copyWith({
    Map<AppHue, MaterialColor>? hues,
    Map<AppHue, MaterialAccentColor>? accents,
    Color? codeBackground,
    Map<String, TextStyle>? syntax,
    FluxdoRenderPalette? render,
  }) => AppColors(
    hues: hues ?? this.hues,
    accents: accents ?? this.accents,
    codeBackground: codeBackground ?? this.codeBackground,
    syntax: syntax ?? this.syntax,
    render: render ?? this.render,
  );

  /// 主题切换时整体换档：色板与高亮表是离散的查找表，逐档插值没有
  /// 意义（也会让高亮缓存失效一整段动画），只对代码块底色做插值。
  @override
  AppColors lerp(covariant AppColors? other, double t) {
    if (other == null) return this;
    final base = t < 0.5 ? this : other;
    return base.copyWith(
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t),
      render: render.lerp(other.render, t),
    );
  }
}

/// 具名色相（与 Material `Colors.*` 同名）。
enum AppHue {
  red,
  pink,
  purple,
  deepPurple,
  indigo,
  blue,
  lightBlue,
  cyan,
  teal,
  green,
  lightGreen,
  lime,
  yellow,
  amber,
  orange,
  deepOrange,
  brown,
  grey,
  blueGrey;

  /// 固定配色主题必须提供的基础色相（红橙黄绿青蓝紫）。
  static const List<AppHue> basics = [red, orange, yellow, green, cyan, blue, purple];

  /// 主题可额外提供、缺省时由基础色相混合的色相。
  static const List<AppHue> optionals = [pink, teal];
}

extension AppColorsTheme on ThemeData {
  /// 本主题的语义色；未注入时（测试、独立窗口）回退 Material 默认值。
  AppColors get appColors =>
      extension<AppColors>() ?? AppColors.material(brightness);
}

extension AppColorsContext on BuildContext {
  /// 当前主题的语义色，见 [AppColorsTheme.appColors]。
  AppColors get appColors => Theme.of(this).appColors;
}
