import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 顶栏渐变模糊(progressive blur):模糊与遮罩从顶部向下渐次消散到
/// 完全透明,内容从其下滚过时自然"溶解",没有均匀毛玻璃的硬下边。
///
/// 主路径(Impeller,即 Android/iOS):单 pass 变力模糊 fragment
/// shader —— sigma 与色罩 alpha 都随 y 连续变化(smoothstep,C1
/// 连续),数学上不存在阶梯与折线转折,丝滑消散
/// (shaders/progressive_top_blur.frag,vogel 盘 36 tap)。
/// ⚠️ .frag 构建期编译打包,新增/修改后必须冷启动重建,热重载不生效
/// (资产缺失时会静默走降级路径 —— 看日志分辨走了哪条路)。
///
/// 降级路径(桌面 Skia / shader 加载完成前的首帧):多层阶梯
/// BackdropFilter + 同曲线密集采样的渐变色罩。
///
/// 用法:AppBar 设为纯透明(只承载返回/标题/按钮),本组件以
/// IgnorePointer 画在 body Stack 顶部,高度 = 状态栏 + AppBar +
/// 消散尾巴(尾巴伸出 AppBar 下缘,是"渐变到透明"的发生区)。
class ProgressiveTopBlur extends StatefulWidget {
  const ProgressiveTopBlur({super.key, required this.height});

  /// 总高(通常 = MediaQuery.padding.top + kToolbarHeight + [tail])
  final double height;

  /// 消散尾巴:伸出 AppBar 下缘的渐变归零区。
  /// 初始态内容应从 [heightFor] 之下开始(否则未滚动就被尾巴盖住),
  /// 滚动上移时才进入消散区被渐次溶解。
  static const double tail = 28;

  /// 页面接线用:渐变层总高 = 状态栏 + AppBar + 尾巴。
  /// 滚动内容的顶部避让也应基于此值(再加自身间距)。
  static double heightFor(BuildContext context) =>
      MediaQuery.paddingOf(context).top + kToolbarHeight + tail;

  /// 顶部最大模糊(逻辑像素,传 shader 前换算物理)
  static const double _maxSigma = 10.0;

  /// 模糊消散曲线指数:sigma = max * pow(1 - y/h, curve)
  static const double _curve = 1.5;

  /// 色罩顶部最大 alpha:磨砂玻璃感 —— 罩要淡,模糊后的内容透出
  /// 色彩形状(澎湃/iOS 材质参照);顶栏文字可读性主要靠强模糊把
  /// 背景打散,不靠罩实。别回调到 0.9 一档:等于实心刷漆,底下
  /// 什么都看不见
  static const double _tintMaxAlpha = 0.50;

  /// 色罩平台拐点:t(1=顶)≥ 此值的区域保持满 alpha,
  /// 其下 smoothstep 平滑滑到 0(两端导数为零,无折痕)
  static const double _tintKnee = 0.75;

  /// 色罩曲线(与 shader 内 TINT_KNEE 逻辑一致,降级路径共用)
  static double tintAlphaAt(double t) {
    final u = (t / _tintKnee).clamp(0.0, 1.0);
    return _tintMaxAlpha * u * u * (3 - 2 * u); // smoothstep(0, knee, t)
  }

  @override
  State<ProgressiveTopBlur> createState() => _ProgressiveTopBlurState();
}

class _ProgressiveTopBlurState extends State<ProgressiveTopBlur> {
  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram>? _loading;
  static bool _loggedPath = false;

  ui.FragmentProgram? _program;

  /// 降级阶梯:(占总高比例, sigma),自下而上层高递减、模糊递增。
  /// σ 几何级数(比率 ~1.29),相邻层边界的等效模糊跳变 <1.5,
  /// 配合平滑色罩肉眼基本不可辨;BackdropGroup 单 pass 采样,
  /// 桌面 GPU 层数不敏感
  static const List<(double, double)> _fallbackLayers = [
    (1.00, 1.0),
    (0.93, 1.3),
    (0.86, 1.7),
    (0.79, 2.2),
    (0.72, 2.9),
    (0.65, 3.7),
    (0.58, 4.8),
    (0.51, 6.2),
    (0.44, 8.0),
    (0.37, 10.4),
    (0.30, 12.0),
  ];

  @override
  void initState() {
    super.initState();
    // ImageFilter.shader 仅 Impeller;Skia(桌面)直接留在降级路径
    if (!ui.ImageFilter.isShaderFilterSupported) {
      _logPathOnce('Impeller 不可用,走阶梯降级');
      return;
    }
    final cached = _cachedProgram;
    if (cached != null) {
      _program = cached;
      return;
    }
    (_loading ??= ui.FragmentProgram.fromAsset(
      'shaders/progressive_top_blur.frag',
    )).then(
      (program) {
        _cachedProgram = program;
        _logPathOnce('shader 变力模糊已激活');
        if (mounted) setState(() => _program = program);
      },
      // 资产缺失(如忘了冷启动重建)→ 停留在降级路径,不红屏
      onError: (Object e, StackTrace s) {
        _logPathOnce('shader 加载失败,走阶梯降级(改过 .frag 需冷启动重建): $e');
      },
    );
  }

  static void _logPathOnce(String msg) {
    if (_loggedPath) return;
    _loggedPath = true;
    debugPrint('[ProgressiveTopBlur] $msg');
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final program = _program;
    return IgnorePointer(
      child: SizedBox(
        height: widget.height,
        child: program != null
            ? _buildShaderBlur(context, program, surface)
            : _buildSteppedFallback(surface),
      ),
    );
  }

  /// 主路径:单 pass 变力模糊(vogel 盘 48 tap + 每像素随机旋转,
  /// 重影伪影噪声化为干净雾面);色罩同 shader 内(连续曲线,零阶梯
  /// 零折痕)。⚠️ 不要改 compose 两 pass:第二 pass 输入纹理的坐标
  /// 基准与原 backdrop 不一致,t 会错位(实测顶透/中糊/底硬切)
  Widget _buildShaderBlur(
    BuildContext context,
    ui.FragmentProgram program,
    Color surface,
  ) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // uniform 布局:0-1 = u_size(引擎自动填,是输入纹理尺寸,可能
    // 为全屏 —— 纵向归一必须用显式的区域高度),2 = u_region_h,
    // 3 = u_max_sigma,4 = u_curve,5-8 = u_tint(rgb + 顶部最大
    // alpha);每 build 新建 shader 实例,避免渲染中改 uniform
    final shader = program.fragmentShader()
      ..setFloat(2, widget.height * dpr)
      ..setFloat(3, ProgressiveTopBlur._maxSigma * dpr)
      ..setFloat(4, ProgressiveTopBlur._curve)
      ..setFloat(5, surface.r)
      ..setFloat(6, surface.g)
      ..setFloat(7, surface.b)
      ..setFloat(8, ProgressiveTopBlur._tintMaxAlpha);
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.compose(
          // 轻均匀 blur 收口:IGN 每像素随机旋转把重影打散成高频
          // 噪粒(单帧无 TAA 可平均,静态看是"颗粒/素描感"),
          // σ1.2 恰好抹平噪粒成真雾,对内容只是极轻软化。
          // blur 必须在 outer(无坐标语义,不踩中间纹理基准坑),
          // shader 必须在 inner(输入=原 backdrop,fragCoord 基准
          // 正确)—— 顺序反过来就是"顶透中糊底硬切"事故。
          // TileMode.clamp:顶边模糊核越界默认混透明(decal),
          // 暗色下屏幕最顶会有一条"没模糊的线"
          outer: ui.ImageFilter.blur(
            sigmaX: 1.2,
            sigmaY: 1.2,
            tileMode: ui.TileMode.clamp,
          ),
          inner: ui.ImageFilter.shader(shader),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// 降级路径:多层阶梯模糊(BackdropGroup 合并采样)+ 与 shader
  /// 同曲线的色罩(12 点密集采样,近似平滑,兼盖层阶)
  Widget _buildSteppedFallback(Color surface) {
    const sampleCount = 12;
    final stops = List.generate(
      sampleCount,
      (i) => i / (sampleCount - 1),
    );
    final colors = [
      for (final s in stops)
        surface.withValues(alpha: ProgressiveTopBlur.tintAlphaAt(1.0 - s)),
    ];
    return BackdropGroup(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final (fraction, sigma) in _fallbackLayers)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: widget.height * fraction,
              child: ClipRect(
                child: BackdropFilter.grouped(
                  filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
                stops: stops,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
