import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 柔光玻璃材质配方。
///
/// 参数不对用户暴露:光学参数之间强耦合(折射带宽与圆角、色散与折射量、
/// 噪声与模糊),单独拉某一项很容易调出"塑料"或"油画"效果。按场景选
/// 配方,不要就地改数值。
///
/// 参考:https://github.com/AritxOnly/Hyper-PiliPlus
@immutable
class GlassRecipe {
  const GlassRecipe({
    required this.blurSigmaPx,
    required this.tintAlpha,
    required this.tintLightGray,
    required this.tintDarkGray,
    required this.saturation,
    required this.brightness,
    required this.contrast,
    required this.refractionHeight,
    required this.refractionAmount,
    required this.depthEffect,
    required this.chromaticAberration,
    required this.highlightAlpha,
    required this.darkHighlightMultiplier,
    required this.noise,
    required this.postBlurSigma,
    required this.fallbackEdgeWidth,
    required this.fallbackLightAlpha,
    required this.fallbackDarkAlpha,
  });

  /// 主模糊 sigma。单位是**物理像素**,用时需除以 dpr —— 写成逻辑像素
  /// 会在 dpr=3 的机器上模糊过量 3 倍。
  final double blurSigmaPx;

  /// 色罩不透明度(叠在模糊结果之上的灰阶色)
  final double tintAlpha;

  /// 色罩灰阶(浅色/深色)。刻意用**固定灰阶**而非主题色:玻璃是中性
  /// 介质,用 surfaceContainer 会被主题色染成彩色塑料板。
  final double tintLightGray;
  final double tintDarkGray;

  /// 饱和度/亮度/对比度。玻璃不只是模糊,还会轻微提升饱和度 ——
  /// 缺了这步背景透过来会发灰。
  final double saturation;
  final double brightness;
  final double contrast;

  /// 折射带宽度(逻辑像素):自边缘向内多少参与弯曲
  final double refractionHeight;

  /// 折射强度(逻辑像素):边缘最大采样偏移
  final double refractionAmount;

  /// 厚度感 0-1
  final double depthEffect;

  /// 色散(逻辑像素)
  final double chromaticAberration;

  /// 边缘高光 alpha(浅色模式基准值)
  final double highlightAlpha;

  /// 深色模式高光衰减系数 —— 深色下白边必须收得很狠,
  /// 否则胶囊像是"描了一圈荧光笔"
  final double darkHighlightMultiplier;

  /// 磨砂噪点强度。量级在 0.1 左右,远高于常见的 0.01 级去带噪 ——
  /// 它是磨砂质感本身的来源,不是修饰。调小会直接失去"柔"的观感。
  final double noise;

  /// 折射后的收口柔化(逻辑像素):抹平折射引入的高频锯齿
  final double postBlurSigma;

  /// 降级描边宽度与明暗两档 alpha(无 shader 时替代光学边缘光)
  final double fallbackEdgeWidth;
  final double fallbackLightAlpha;
  final double fallbackDarkAlpha;

  /// 当前亮度下的色罩灰阶
  double tintGrayFor(bool isDark) => isDark ? tintDarkGray : tintLightGray;

  /// 悬浮导航胶囊。
  ///
  /// 模糊刻意压得很轻(sigma 9.2 物理像素):底栏下方内容应当仍能辨认
  /// 形状,玻璃感主要来自磨砂噪点与边缘折射,而不是把背景糊成一片。
  /// 重模糊反而会让人失去"页面在动"的感知。
  static const navigation = GlassRecipe(
    blurSigmaPx: 9.2,
    tintAlpha: 0.675,
    tintLightGray: 0.99,
    tintDarkGray: 0.12,
    saturation: 1.1025,
    brightness: 0.0,
    contrast: 1.0,
    refractionHeight: 18,
    refractionAmount: 18,
    depthEffect: 0.60,
    chromaticAberration: 1.0,
    highlightAlpha: 0.95,
    darkHighlightMultiplier: 0.20,
    noise: 0.095,
    postBlurSigma: 0.5,
    fallbackEdgeWidth: 0.5,
    fallbackLightAlpha: 0.46,
    fallbackDarkAlpha: 0.08,
  );

  /// 临时浮层(BottomSheet):重模糊,底下内容只留色块形状。
  /// 搭配 36dp 圆角使用。
  static const sheet = GlassRecipe(
    blurSigmaPx: 64,
    tintAlpha: 0.66,
    tintLightGray: 0.99,
    tintDarkGray: 0.12,
    saturation: 1.0,
    brightness: 0.0,
    contrast: 1.0,
    refractionHeight: 22,
    refractionAmount: 14,
    depthEffect: 0.45,
    chromaticAberration: 0.8,
    highlightAlpha: 0.72,
    darkHighlightMultiplier: 0.22,
    noise: 0.095,
    postBlurSigma: 1.0,
    fallbackEdgeWidth: 0.5,
    fallbackLightAlpha: 0.46,
    fallbackDarkAlpha: 0.08,
  );

  /// 对话框:比 Sheet 略收敛,折射量更小(直角比胶囊更容易看出畸变)。
  /// 搭配 40dp 圆角使用。
  static const dialog = GlassRecipe(
    blurSigmaPx: 48,
    tintAlpha: 0.62,
    tintLightGray: 0.99,
    tintDarkGray: 0.12,
    saturation: 1.0,
    brightness: 0.0,
    contrast: 1.0,
    refractionHeight: 16,
    refractionAmount: 10,
    depthEffect: 0.38,
    chromaticAberration: 0.6,
    highlightAlpha: 0.68,
    darkHighlightMultiplier: 0.22,
    noise: 0.095,
    postBlurSigma: 0.75,
    fallbackEdgeWidth: 0.5,
    fallbackLightAlpha: 0.46,
    fallbackDarkAlpha: 0.08,
  );
}

/// 柔光玻璃表面。
///
/// 主路径(Impeller):`ImageFilter.compose` 三段链 ——
/// outer 高斯模糊 → inner 折射 shader,再叠色罩。折射 shader 提供
/// 边缘透镜弯曲、方向性高光与色散,这三样是"玻璃"区别于"半透明
/// 灰板"的关键。
///
/// 降级路径(桌面 Skia / shader 未就绪 / 显式关闭):纯
/// `BackdropFilter` + 色罩,即项目原有观感,不会红屏也不会突变。
///
/// ⚠️ 本组件自身不裁切、不画描边、不投影 —— 这些由调用方按场景决定
/// (胶囊底栏的描边要画在裁切之内,Sheet 则只有顶部圆角)。本组件
/// 只负责"玻璃材质"本身,填满父级给的尺寸。
class GlassSurface extends StatefulWidget {
  const GlassSurface({
    super.key,
    required this.recipe,
    required this.shape,
    this.tintColor,
    this.enabled = true,
    this.child,
  });

  /// 当前环境是否会走 shader 光学路径(即玻璃自带方向性边缘光)。
  ///
  /// 调用方据此决定要不要另外再画一层描边 —— shader 已经在玻璃
  /// 内部画了迎光/背光渐变的边,外面再叠一圈会变成双边。
  static bool get opticalEdgeAvailable =>
      ui.ImageFilter.isShaderFilterSupported;

  /// 场景配方,见 [GlassRecipe.navigation] / [GlassRecipe.sheet] /
  /// [GlassRecipe.dialog]
  final GlassRecipe recipe;

  /// 玻璃形状。shader 需要圆角半径,故只接受 [RoundedRectangleBorder]
  /// 与 [StadiumBorder];其他形状自动走降级路径。
  final ShapeBorder shape;

  /// 色罩颜色覆盖。默认为 null,用配方里的**固定灰阶**
  /// ([GlassRecipe.tintGrayFor]) —— 不要随手传主题色,会把中性
  /// 玻璃染成彩色塑料板。
  final Color? tintColor;

  /// 关闭时直接走实色(无模糊无折射),供"省电/低端机/用户关闭"使用
  final bool enabled;

  final Widget? child;

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface> {
  // 进程内只加载一次,所有玻璃实例共享
  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram>? _loading;
  static bool _loggedPath = false;

  ui.FragmentProgram? _program;

  @override
  void initState() {
    super.initState();
    // ImageFilter.shader 仅 Impeller;Skia(桌面)直接留在降级路径
    if (!ui.ImageFilter.isShaderFilterSupported) {
      _logPathOnce('Impeller 不可用,走 BackdropFilter 降级');
      return;
    }
    final cached = _cachedProgram;
    if (cached != null) {
      _program = cached;
      return;
    }
    (_loading ??= ui.FragmentProgram.fromAsset(
      'packages/common_ui/shaders/glass_surface.frag',
    )).then(
      (program) {
        _cachedProgram = program;
        _logPathOnce('折射玻璃 shader 已激活');
        if (mounted) setState(() => _program = program);
      },
      // 资产缺失(如改过 .frag 忘了冷启动重建)→ 留在降级路径,不红屏
      onError: (Object e, StackTrace s) {
        _logPathOnce('shader 加载失败,走降级(改过 .frag 需冷启动重建): $e');
      },
    );
  }

  static void _logPathOnce(String msg) {
    if (_loggedPath) return;
    _loggedPath = true;
    debugPrint('[GlassSurface] $msg');
  }

  /// 从 shape 取圆角半径(逻辑像素)。胶囊返回 null 表示"用半高"。
  double? _cornerRadiusOf(ShapeBorder shape) {
    if (shape is StadiumBorder) return null;
    if (shape is RoundedRectangleBorder) {
      final radius = shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;
      return radius;
    }
    return null;
  }

  bool _shapeSupported(ShapeBorder shape) =>
      shape is StadiumBorder || shape is RoundedRectangleBorder;

  /// 给形状叠描边。ShapeBorder 没有通用 copyWith,需按具体类型分支;
  /// 未知形状原样返回(宁可没描边,不能抄错形状)。
  ShapeBorder _shapeWithSide(ShapeBorder shape, BorderSide side) {
    if (shape is StadiumBorder) return shape.copyWith(side: side);
    if (shape is RoundedRectangleBorder) return shape.copyWith(side: side);
    return shape;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final recipe = widget.recipe;
    // 默认用配方的固定灰阶,而非主题 surfaceContainer
    final gray = recipe.tintGrayFor(isDark);
    final tint =
        widget.tintColor ??
        Color.from(alpha: 1, red: gray, green: gray, blue: gray);

    // 关闭:实色,连 BackdropFilter 都不建(省一次离屏合成)
    if (!widget.enabled) {
      return DecoratedBox(
        decoration: ShapeDecoration(shape: widget.shape, color: tint),
        child: widget.child,
      );
    }

    final program = _program;
    final useShader = program != null && _shapeSupported(widget.shape);

    if (!useShader) {
      return _buildFallback(tint, recipe, isDark);
    }

    // shader 需要玻璃在输入纹理中的原点与尺寸。BackdropFilter 的输入
    // 纹理基准无文档约定,故用 LayoutBuilder 拿到自身尺寸,并假定
    // 外层已按玻璃边界裁切(ClipPath/ClipRRect),使原点为零。
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.isEmpty) {
          return _buildFallback(tint, recipe, isDark);
        }
        return _buildShaderGlass(
          context: context,
          program: program,
          size: size,
          tint: tint,
          recipe: recipe,
          isDark: isDark,
        );
      },
    );
  }

  Widget _buildShaderGlass({
    required BuildContext context,
    required ui.FragmentProgram program,
    required Size size,
    required Color tint,
    required GlassRecipe recipe,
    required bool isDark,
  }) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final radiusLogical = _cornerRadiusOf(widget.shape) ?? size.height / 2;

    // 深色模式下白色边缘光必须大幅衰减,否则像描了荧光边
    final highlightAlpha =
        recipe.highlightAlpha * (isDark ? recipe.darkHighlightMultiplier : 1.0);
    // 高光颜色:浅色模式偏白(玻璃迎光面),深色模式同样用白但已被
    // darkHighlightMultiplier 压到很淡 —— 用黑边会让深色玻璃显脏
    const highlightGray = 1.0;

    // uniform 布局(顺序即索引):
    // 0-1 u_size(引擎填) / 2-3 u_origin / 4-5 u_rect / 6 u_radius
    // 7 u_refract_h / 8 u_refract_amt / 9 u_depth / 10 u_chroma
    // 11 u_hl_alpha / 12 u_hl_gray / 13 u_noise
    // 14 u_saturation / 15 u_brightness / 16 u_contrast
    // 每 build 新建实例,避免渲染途中改 uniform
    final shader = program.fragmentShader()
      ..setFloat(2, 0)
      ..setFloat(3, 0)
      ..setFloat(4, size.width * dpr)
      ..setFloat(5, size.height * dpr)
      ..setFloat(6, radiusLogical * dpr)
      ..setFloat(7, recipe.refractionHeight * dpr)
      ..setFloat(8, recipe.refractionAmount * dpr)
      ..setFloat(9, recipe.depthEffect)
      ..setFloat(10, recipe.chromaticAberration * dpr)
      ..setFloat(11, highlightAlpha)
      ..setFloat(12, highlightGray)
      ..setFloat(13, recipe.noise)
      ..setFloat(14, recipe.saturation)
      ..setFloat(15, recipe.brightness)
      ..setFloat(16, recipe.contrast);

    // 效果链顺序至关重要(同 progressive_top_blur 的踩坑记录):
    // shader 必须在 inner —— 它的 fragCoord 基准必须是原始 backdrop;
    // 放到 outer 会拿到中间纹理,坐标错位导致折射带跑到画面外。
    // ⚠️ sigma 是物理像素,而 ImageFilter.blur 收逻辑像素 —— 需除 dpr。
    // 不除的话 dpr=3 的机器上会模糊过量 3 倍。
    final blurLogical = recipe.blurSigmaPx / dpr;
    ui.ImageFilter filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.blur(
        sigmaX: blurLogical,
        sigmaY: blurLogical,
        // clamp:边缘模糊核越界时复制边缘像素。默认 decal 会混入透明,
        // 深色下玻璃四周会出现一圈"没模糊的暗线"
        tileMode: ui.TileMode.clamp,
      ),
      inner: ui.ImageFilter.shader(shader),
    );

    // 折射后的极轻柔化:抹平透镜采样在陡峭区引入的高频锯齿
    if (recipe.postBlurSigma > 0) {
      filter = ui.ImageFilter.compose(
        outer: ui.ImageFilter.blur(
          sigmaX: recipe.postBlurSigma,
          sigmaY: recipe.postBlurSigma,
          tileMode: ui.TileMode.clamp,
        ),
        inner: filter,
      );
    }

    return BackdropFilter(
      filter: filter,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: widget.shape,
          color: tint.withValues(alpha: recipe.tintAlpha),
        ),
        child: widget.child,
      ),
    );
  }

  /// 降级:均匀模糊 + 色罩 + 实描边。
  ///
  /// 没有 shader 时用一条描边替代光学边缘光,勾出胶囊轮廓。
  Widget _buildFallback(Color tint, GlassRecipe recipe, bool isDark) {
    final dpr = ui.PlatformDispatcher.instance.views.isNotEmpty
        ? ui.PlatformDispatcher.instance.views.first.devicePixelRatio
        : 1.0;
    final blurLogical = recipe.blurSigmaPx / dpr;
    final edgeAlpha = isDark
        ? recipe.fallbackDarkAlpha
        : recipe.fallbackLightAlpha;
    // 描边颜色跟高光灰阶走(白),上浓下淡 —— 模拟迎光面
    final edgeColor = const Color(0xFFFFFFFF).withValues(alpha: edgeAlpha);
    return BackdropFilter(
      filter: ui.ImageFilter.blur(
        sigmaX: blurLogical,
        sigmaY: blurLogical,
        tileMode: ui.TileMode.clamp,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: _shapeWithSide(
            widget.shape,
            BorderSide(width: recipe.fallbackEdgeWidth, color: edgeColor),
          ),
          // 降级没有折射与边缘光可撑玻璃感,色罩略加厚补偿
          color: tint.withValues(
            alpha: (recipe.tintAlpha + 0.08).clamp(0.0, 1.0),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
