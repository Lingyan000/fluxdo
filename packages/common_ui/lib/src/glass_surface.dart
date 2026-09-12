import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'glass_edge_painter.dart';
import 'glass_optical_border.dart';
import 'glass_settings.dart';

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

  /// 磨砂噪点强度。导航使用轻微去带噪，不以粗颗粒代替背景柔化。
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
  /// 背景细节柔化成色块，色罩保留透色；轮廓光独立绘制，不依赖
  /// 粗噪点或过大的折射量制造质感。
  static const navigation = GlassRecipe(
    blurSigmaPx: 14,
    tintAlpha: 0.32,
    tintLightGray: 0.99,
    tintDarkGray: 0.12,
    saturation: 1.1025,
    brightness: 0.0,
    contrast: 1.0,
    refractionHeight: 12,
    refractionAmount: 8,
    depthEffect: 0.60,
    chromaticAberration: 0.45,
    highlightAlpha: 0.95,
    darkHighlightMultiplier: 0.20,
    noise: 0.012,
    postBlurSigma: 0.4,
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
/// Impeller 下先用主模糊建立局部背景层，再在该层上折射并轻柔化。
/// 两层 BackdropFilter 不能合并为一条 compose：后者仍会让 shader
/// 直接读取父渲染层纹理，胶囊的局部坐标会与输入纹理错位。
///
/// 本组件不做形状裁切或投影，由调用方限制可见范围。独立使用时默认提供
/// 细描边；外壳可通过 fallbackBorderRadius 委托本实例绘制降级边缘光。
class GlassSurface extends StatefulWidget {
  const GlassSurface({
    super.key,
    required this.recipe,
    required this.shape,
    this.tintColor,
    this.enabled = true,
    this.drawFallbackBorder = true,
    this.fallbackBorderRadius,
    this.child,
  });

  /// 后端是否支持光学材质；描边切换仍须依据本实例实际渲染路径。
  static bool get opticalEdgeAvailable =>
      ui.ImageFilter.isShaderFilterSupported;

  /// 场景配方,见 [GlassRecipe.navigation] / [GlassRecipe.sheet] /
  /// [GlassRecipe.dialog]
  final GlassRecipe recipe;

  /// 玻璃形状。shader 支持四角相同的圆形圆角 [RoundedRectangleBorder]
  /// 与 [StadiumBorder]；非对称或椭圆圆角等形状使用降级路径。
  final ShapeBorder shape;

  /// 色罩颜色覆盖。默认为 null,用配方里的**固定灰阶**
  /// ([GlassRecipe.tintGrayFor]) —— 不要随手传主题色,会把中性
  /// 玻璃染成彩色塑料板。
  final Color? tintColor;

  /// 关闭时直接走实色(无模糊无折射),供"省电/低端机/用户关闭"使用
  final bool enabled;

  /// 外壳自绘边缘光时关闭，避免均匀描边与方向性描边叠加。
  final bool drawFallbackBorder;

  /// 外壳的方向性降级描边半径。由本实例按实际路径绘制，避免加载中或
  /// shader 加载失败时，外壳误判 GPU 能力而漏掉描边。
  final double? fallbackBorderRadius;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureProgram();
  }

  @override
  void didUpdateWidget(GlassSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _ensureProgram();
  }

  bool _loadRequested = false;

  void _ensureProgram() {
    final settings = GlassSettingsScope.of(context);
    if (!settings.allowsOptics(
          shaderSupported: GlassSurface.opticalEdgeAvailable,
          highContrast: MediaQuery.maybeOf(context)?.highContrast ?? false,
          locallyEnabled: widget.enabled,
        ) ||
        _program != null ||
        _loadRequested) {
      return;
    }
    _loadRequested = true;
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
      final radius = shape.borderRadius
          .resolve(Directionality.of(context))
          .topLeft
          .x;
      return radius;
    }
    return null;
  }

  bool _shapeSupported(ShapeBorder shape) {
    if (shape is StadiumBorder) return true;
    if (shape is! RoundedRectangleBorder) return false;
    final radii = shape.borderRadius.resolve(Directionality.of(context));
    final radius = radii.topLeft;
    return radius.x == radius.y &&
        radii.topRight == radius &&
        radii.bottomLeft == radius &&
        radii.bottomRight == radius;
  }

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

    final settings = GlassSettingsScope.of(context);
    final highContrast = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final enabled = settings.allowsBlur(
      highContrast: highContrast,
      locallyEnabled: widget.enabled,
    );
    final program = _program;
    final useShader =
        program != null &&
        settings.allowsOptics(
          shaderSupported: GlassSurface.opticalEdgeAvailable,
          highContrast: highContrast,
          locallyEnabled: widget.enabled,
        ) &&
        _shapeSupported(widget.shape);

    // 前景始终留在同一个槽位；异步加载或切换模糊时只替换背景，不能
    // 重新挂载编辑器、焦点和导航动画。由前景布局尺寸约束背景，而不是
    // 用父级的松约束上限猜玻璃高度。
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: !enabled
              ? DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: widget.shape,
                    color: tint.withValues(alpha: 1),
                  ),
                )
              : useShader
              ? _shaderBackground(context, program, tint, recipe, isDark)
              : _buildFallback(context, tint, recipe, isDark),
        ),
        widget.child ?? const SizedBox.shrink(),
        if (useShader)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) => CustomPaint(
                  painter: GlassOpticalBorder(
                    radius:
                        _cornerRadiusOf(widget.shape) ??
                        constraints.maxHeight / 2,
                    isDark: isDark,
                    strength: recipe.highlightAlpha,
                  ),
                ),
              ),
            ),
          ),
        if (!useShader && widget.fallbackBorderRadius != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: GlassEdgePainter(
                  radius: widget.fallbackBorderRadius!,
                  isDark: isDark,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _shaderBackground(
    BuildContext context,
    ui.FragmentProgram program,
    Color tint,
    GlassRecipe recipe,
    bool isDark,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.isEmpty) {
          return const SizedBox.shrink();
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
    // 窄高光由色罩上方的光学轮廓统一负责；shader 不重复加白边。
    const highlightAlpha = 0.0;
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

    // 主模糊放在独立的外层 BackdropFilter，不放进同一条 compose。
    // 它先把背景画进受 ClipRect 约束的局部 pass，内层折射读取的才是
    // 原点为胶囊左上角的纹理，而不是父层/整屏纹理。
    final blurLogical = recipe.blurSigmaPx / dpr;
    ui.ImageFilter filter = ui.ImageFilter.shader(shader);

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

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blurLogical,
          sigmaY: blurLogical,
          tileMode: ui.TileMode.clamp,
        ),
        // 最外层仍与页面背景按圆角抗锯齿覆盖率合成，不能直接替换。
        // src 会在直边与圆弧交界处暴露覆盖率接缝，形成四角缺口/细线。
        blendMode: BlendMode.srcOver,
        child: BackdropFilter(
          filter: filter,
          // 局部 pass 已有主模糊结果，替换它，避免透明像素重复混合。
          blendMode: BlendMode.src,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: widget.shape,
              color: tint.withValues(alpha: recipe.tintAlpha),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// 降级:均匀模糊 + 色罩 + 实描边。
  ///
  /// 没有 shader 时用一条描边替代光学边缘光,勾出胶囊轮廓。
  Widget _buildFallback(
    BuildContext context,
    Color tint,
    GlassRecipe recipe,
    bool isDark,
  ) {
    // 必须取当前组件所在视图的 DPR，不能拿进程的第一个视图。
    final dpr = MediaQuery.devicePixelRatioOf(context);
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
          shape:
              widget.drawFallbackBorder && widget.fallbackBorderRadius == null
              ? _shapeWithSide(
                  widget.shape,
                  BorderSide(width: recipe.fallbackEdgeWidth, color: edgeColor),
                )
              : widget.shape,
          // 降级没有折射与边缘光可撑玻璃感,色罩略加厚补偿
          color: tint.withValues(
            alpha: (recipe.tintAlpha + 0.08).clamp(0.0, 1.0),
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}
