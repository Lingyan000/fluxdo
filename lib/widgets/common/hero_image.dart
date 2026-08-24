import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../utils/hero_visibility_controller.dart';

/// Hero 飞行体:cover↔contain 单层裁切插值(网格瓦片/圆形头像来源)。
///
/// 裁切窗口与飞行缩放绑同一 progress(参考成熟查看器的 clip 插值
/// 方案,非双层 crossfade —— 两层几何不同,混合必有鬼影/断层):
/// t=0(贴源)cover 裁切+圆角/圆形,t=1(查看器)contain 完整图,
/// 飞行中对源矩形连续插值,两端与真实内容像素级对齐。
///
/// [animation] 为路由原始动画:push 0→1、pop 1→0,值语义恒为
/// 「0=贴源,1=在查看器」,单套插值天然覆盖双向。
class CoverContainFlightImage extends StatefulWidget {
  const CoverContainFlightImage({
    super.key,
    required this.image,
    required this.animation,
    this.radius = 0,
    this.circular = false,
    this.coverSource = false,
    this.sourceAspect,
    this.fallback,
  });

  final ImageProvider image;
  final Animation<double> animation;

  /// 源圆角(t=0 端,插值到 0);[circular] 为 true 时忽略
  final double radius;

  /// 源为圆形裁切(头像):t=0 端圆角 = 短边一半,随飞行插值到 0
  final bool circular;

  /// 源端是否以 cover **裁切**展示(网格瓦片/聊天气泡/头像)。
  ///
  /// 决定贴源端(t=0)的 src 窗口:
  /// - true:按画布比例从全图中心裁出窗口 —— 与源端 `Image(fit: cover)` 的
  ///   可见区域同一算式,故两端像素级对齐(聊天气泡因 clamp 夹高只显示纵向
  ///   84% 时,这里算出的正是那 84%);
  /// - false(contain 展示,如轮播/正文单图):贴源端就是完整图。
  final bool coverSource;

  /// **源端缩略图盒子的固定宽高比**(width/height)。
  ///
  /// 贴源端(t=0)的 cover 裁窗必须按这个**固定**比例算,而不是飞行途中
  /// 逐帧变化的画布 `size`。否则:盒子比例在飞行中从源端连续变到查看器,
  /// 中途既不等于源端也不等于查看器,cover 裁窗就会把本不该裁的裁掉 ——
  /// 表现为「两端(盒子≈源端 / t 权重归零)都完整、唯独中间帧被裁」
  /// (真机实测:气泡盒子恰好等于图片比例、不裁切的聊天图,返回途中被裁)。
  ///
  /// null = 退化用当前画布比例(旧行为,读不到源端盒子时的兜底)。
  final double? sourceAspect;

  /// 纹理未就绪时的退化显示(通常传 Hero child,= 无插值的旧行为;
  /// 飞行纹理走缓存几乎必然同步命中,此为极端情况兜底,防空白飞行)
  final Widget? fallback;

  /// 仅供测试:最近一次绘制实际用的 src 窗口(全图像素坐标)。
  /// 让测试读**真实绘制结果**,而不是复刻 painter 的算式(复刻等于自洽装置,
  /// 产品逻辑改坏了照样过)。
  @visibleForTesting
  static Rect? debugLastSrc;

  @override
  State<CoverContainFlightImage> createState() =>
      _CoverContainFlightImageState();
}

class _CoverContainFlightImageState extends State<CoverContainFlightImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newStream = widget.image.resolve(
      createLocalImageConfiguration(context),
    );
    if (newStream.key != _stream?.key) {
      if (_listener != null) {
        _stream?.removeListener(_listener!);
      }
      _stream = newStream;
      _listener = ImageStreamListener((info, _) {
        _info?.dispose();
        _info = info;
        if (mounted) setState(() {});
      }, onError: (_, _) {});
      newStream.addListener(_listener!);
    }
  }

  @override
  void dispose() {
    if (_listener != null) {
      _stream?.removeListener(_listener!);
    }
    _info?.dispose();
    _info = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) {
      return widget.fallback ?? const SizedBox.expand();
    }
    return CustomPaint(
      painter: _CoverContainPainter(
        image: info.image,
        animation: widget.animation,
        radius: widget.radius,
        circular: widget.circular,
        coverSource: widget.coverSource || widget.circular,
        sourceAspect: widget.sourceAspect,
        // 飞行期这个值恒定(退场前一次性发布),故 build 时取一次即可;
        // 作显式参数传入而非在 painter 里读全局单例 —— 后者是隐式依赖,
        // 也让 shouldRepaint 无法参与判断。
        zoomFraction: HeroVisibilityController.instance.exitVisibleFraction,
      ),
      size: Size.infinite,
    );
  }
}

class _CoverContainPainter extends CustomPainter {
  _CoverContainPainter({
    required this.image,
    required this.animation,
    required this.radius,
    required this.circular,
    required this.coverSource,
    this.sourceAspect,
    this.zoomFraction,
  }) : super(repaint: animation);

  final ui.Image image;
  final Animation<double> animation;
  final double radius;
  final bool circular;

  /// 源端是否 cover 裁切展示(见 [CoverContainFlightImage.coverSource])
  final bool coverSource;

  /// 源端缩略图盒子的固定宽高比(见 [CoverContainFlightImage.sourceAspect])
  final double? sourceAspect;

  /// 放大态下「此刻看得见的那部分图」,全图归一化坐标;null = 未裁切。
  /// 见 [HeroVisibilityController.exitVisibleFraction]。
  final Rect? zoomFraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t = animation.value.clamp(0.0, 1.0);
    final double imgW = image.width.toDouble();
    final double imgH = image.height.toDouble();

    // src 的两端窗口。t 语义恒为「0=贴源,1=在查看器」。
    //
    // **两端各按自己的依据算,互不影响**:
    // - 贴源端(t=0)由**源端展示方式**决定:cover 裁切展示(网格瓦片/聊天
    //   气泡/头像)时是「按画布比例中心裁出的窗口」。这个窗口与源端
    //   `Image(fit: cover)` 的可见区域是同一个算式,故两端像素级对齐 ——
    //   聊天气泡因 clamp 夹高而纵向只显示 84% 时,这里算出的也正是那 84%。
    // - 查看器端(t=1)由**放大态**决定:未放大是完整图;放大后是
    //   exitVisibleFraction(用户此刻看得见的那块)。
    //
    // 于是 pop(t 从 1 → 0)= 取景框从「查看器里看到的」连续变成「气泡里
    // 看到的」,两端都与真实所见一致,没有突变。
    //
    // 曾经写错过:放大态时把贴源端也置成完整图,结果落地瞬间画面从「裁切
    // 一条」突变为「完整长图」—— 因为气泡本就是裁切展示的。
    final Rect? zoomFraction = this.zoomFraction;
    final Rect fullSrc = Rect.fromLTWH(0, 0, imgW, imgH);

    // 贴源端(t=0):cover 展示 ⇒ 按**源端盒子固定比例**裁窗口;
    // contain 展示 ⇒ 完整图。
    //
    // 关键:裁窗比例取 [sourceAspect](源端缩略图盒子的固定宽高比),不取
    // 飞行途中变化的画布 `size`。用 `size` 会让裁窗随盒子比例漂移 —— 两端
    // 因盒子≈源端 / t 权重归零而正好完整,中间帧却被裁,即真机所见「聊天图
    // 两头完整、中间裁切」。读不到源端比例时才退化用 `size`。
    final Rect atSource;
    if (coverSource) {
      final double boxAspect = sourceAspect ?? (size.width / size.height);
      final double imgAspect = imgW / imgH;
      final double winW, winH;
      if (boxAspect >= imgAspect) {
        // 盒子比图片扁:满宽、裁高
        winW = imgW;
        winH = imgW / boxAspect;
      } else {
        // 盒子比图片瘦:满高、裁宽
        winH = imgH;
        winW = imgH * boxAspect;
      }
      atSource = Rect.fromCenter(
        center: Offset(imgW / 2, imgH / 2),
        width: winW,
        height: winH,
      );
    } else {
      atSource = fullSrc;
    }
    // 查看器端(t=1):放大态是可见窗口,否则是完整图
    final Rect atViewer = zoomFraction == null
        ? fullSrc
        : Rect.fromLTRB(
            zoomFraction.left * imgW,
            zoomFraction.top * imgH,
            zoomFraction.right * imgW,
            zoomFraction.bottom * imgH,
          );

    final Rect src = Rect.lerp(atSource, atViewer, t)!;
    CoverContainFlightImage.debugLastSrc = src;
    // 目标矩形:保持 src 宽高比 contain 进画布(t=0 时 src 比例=画布
    // 比例,恰好铺满=瓦片;t=1 时即查看器的 contain 布局)
    final double dstScale = math.min(
      size.width / src.width,
      size.height / src.height,
    );
    final Rect dst = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: src.width * dstScale,
      height: src.height * dstScale,
    );

    // 圆形来源(头像):t=0 端圆角=短边一半(正圆),线性收到 0;
    // 常规来源用固定 radius 收到 0
    final double r0 = circular
        ? math.min(dst.width, dst.height) / 2
        : radius;
    final double r = r0 * (1 - t);
    if (r > 0) {
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(dst, Radius.circular(r)));
    }
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.medium,
    );
    if (r > 0) {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_CoverContainPainter oldDelegate) =>
      image != oldDelegate.image ||
      radius != oldDelegate.radius ||
      circular != oldDelegate.circular ||
      coverSource != oldDelegate.coverSource ||
      sourceAspect != oldDelegate.sourceAspect ||
      zoomFraction != oldDelegate.zoomFraction ||
      animation != oldDelegate.animation;
}

/// **源端展示方式的单一描述**:一次给出,同时产出 Hero 飞行体参数与
/// `openViewer` 的 `heroSource*` 参数 —— 两侧不可能不一致。
///
/// 为什么需要它:这套契约有五项(盒子几何 / 圆角插值 / 飞行起点 / 缩略图源 /
/// cover 告知),原先分散在**源端 widget** 与 **openViewer 调用**两处,还要求
/// 两边手工对齐。于是每加一个源端都要重想一遍,必然漏 —— 真机先后暴露过:
/// 轮播漏 createRectTween、聊天漏 heroSourceFit、用户头像源端圆角 12 而
/// openViewer 传 8(两处不同步)。
///
/// 用法:源端构建时用 [flightRadius]/[isCover] 配 [HeroImage],开查看器时把
/// [openViewerArgs] 展开传入。
@immutable
class ViewerSourceStyle {
  /// 源端以 `BoxFit.cover` 裁切展示(网格瓦片/聊天气泡/方形头像)
  const ViewerSourceStyle.cover({required double radius})
      : _fit = BoxFit.cover,
        _radius = radius,
        _circular = false;

  /// 源端以 `BoxFit.contain` 完整展示(轮播/正文单图)
  const ViewerSourceStyle.contain({double radius = 0})
      : _fit = BoxFit.contain,
        _radius = radius,
        _circular = false;

  /// 源端是圆形裁切(圆形头像):飞行中圆↔直角连续插值
  const ViewerSourceStyle.circular()
      : _fit = BoxFit.cover,
        _radius = 0,
        _circular = true;

  final BoxFit _fit;
  final double _radius;
  final bool _circular;

  /// 源端展示用的 fit —— 直接给 `Image(fit: ...)`,保证与飞行体口径一致
  BoxFit get fit => _fit;

  /// 源端圆角(圆形来源返回 0,圆角由 [isCircular] 表达)
  double get radius => _radius;

  bool get isCover => _fit == BoxFit.cover || _circular;
  bool get isCircular => _circular;

  /// 展开到 `openViewer` / `ImageViewerPage.open` 的 `heroSource*` 参数。
  ///
  /// contain 来源**不传 heroSourceFit**(留 null):传了会让查看器侧
  /// `coverSource` 为真、飞行体去做 cover→contain 的窗口插值,而 contain
  /// 来源两端本就都是完整图,那段插值是多余动画。
  ({BoxFit? fit, double radius, bool circular}) get openViewerArgs => (
        fit: isCover ? BoxFit.cover : null,
        radius: _radius,
        circular: _circular,
      );

  @override
  bool operator ==(Object other) =>
      other is ViewerSourceStyle &&
      other._fit == _fit &&
      other._radius == _radius &&
      other._circular == _circular;

  @override
  int get hashCode => Object.hash(_fit, _radius, _circular);

  @override
  String toString() => _circular
      ? 'ViewerSourceStyle.circular()'
      : 'ViewerSourceStyle.${isCover ? "cover" : "contain"}(radius: $_radius)';
}

/// 封装 Hero 动画及可见性控制的图片 Widget
///
/// 提供：
/// - Hero 飞行动画
/// - 源端自动隐藏/显示
/// - pop 飞行结束后无闪烁恢复
/// - placeholderBuilder 正确行为
///
/// 使用者只需包裹 HeroImage 即可获得完整的 Hero 体验。
/// 调用方（如 ImageViewerPage）在 initState/onPageChanged/dispose 时
/// 通知 HeroVisibilityController 即可。
class HeroImage extends StatefulWidget {
  /// Hero 动画的唯一标识
  final String heroTag;

  /// 实际显示的图片内容
  final Widget child;

  /// 点击回调
  final VoidCallback? onTap;

  /// 长按回调
  final VoidCallback? onLongPress;

  /// 右键回调（桌面端）
  final GestureTapUpCallback? onSecondaryTapUp;

  /// 源端展示方式(单一真相)。给了它就不必再传 [coverFlight]/[flightRadius]
  /// —— 两者由它派生,且与 `openViewer` 的参数同源,见 [ViewerSourceStyle]。
  final ViewerSourceStyle? style;

  /// 源为 cover 裁切展示(网格瓦片)时传入:飞行体换成
  /// [CoverContainFlightImage] 裁切插值(需与 [flightImage] 同传)。
  ///
  /// 新代码用 [style] —— 它同时约束 `openViewer` 侧参数,不会两处不一致。
  final bool coverFlight;

  /// 飞行体绘制用的图片 provider(通常=缩略图,已解码命中缓存)
  final ImageProvider? flightImage;

  /// 源瓦片圆角(飞行中插值到 0)。新代码用 [style]。
  final double flightRadius;

  /// 源为圆形裁切(头像):飞行中圆↔直角连续插值。新代码用 [style]。
  final bool flightCircular;

  /// 可选:把 Hero 盒子按此比例收到「画面本身」。
  ///
  /// contain 展示的源端(轮播/正文)若盒子大于画面,Hero 飞行几何取的是盒子,
  /// 尾帧就会铺满盒子而非贴合画面。给了它内部套 [AspectRatio] 保证盒子 ≡ 画面。
  final double? aspectRatio;

  /// 实际生效的 cover 判据(优先 [style])
  bool get effectiveCover => style?.isCover ?? coverFlight;

  /// 实际生效的圆角(优先 [style])
  double get effectiveRadius => style?.radius ?? flightRadius;

  /// 实际生效的圆形判据(优先 [style])
  bool get effectiveCircular => style?.isCircular ?? flightCircular;

  const HeroImage({
    super.key,
    required this.heroTag,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapUp,
    this.style,
    this.coverFlight = false,
    this.flightImage,
    this.flightRadius = 0,
    this.flightCircular = false,
    this.aspectRatio,
  });

  @override
  State<HeroImage> createState() => _HeroImageState();
}

class _HeroImageState extends State<HeroImage> {
  @override
  void initState() {
    super.initState();
    // 注册自身位置:查看器翻页时按 tag 反查并把本缩略图滚进可视区,
    // 保证 pop 时 Hero 有目的地(否则图片只能原地渐隐)
    HeroVisibilityController.instance.registerSource(widget.heroTag, context);
  }

  @override
  void didUpdateWidget(HeroImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.heroTag != widget.heroTag) {
      HeroVisibilityController.instance.unregisterSource(
        oldWidget.heroTag,
        context,
      );
      HeroVisibilityController.instance.registerSource(widget.heroTag, context);
    }
  }

  @override
  void dispose() {
    HeroVisibilityController.instance.unregisterSource(
      widget.heroTag,
      context,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String heroTag = widget.heroTag;
    final Widget child = widget.child;
    // Opacity 在 Hero 外层控制可见性
    // Hero 飞行在 Overlay 中，不受外层 Opacity 影响
    return ListenableBuilder(
      listenable: HeroVisibilityController.instance,
      builder: (context, _) {
        final controller = HeroVisibilityController.instance;
        final hiddenTag = controller.hiddenHeroTag;
        final isPopping = controller.isPopping;

        // pop 期间不隐藏任何图片（让 child 可见），其他时候根据 hiddenTag 判断
        final shouldHide = !isPopping && hiddenTag == heroTag;

        final Widget hero = Hero(
            tag: heroTag,
            // Android 预测返回是 user gesture 转场,须显式开启才有飞行
            transitionOnUserGestures: true,
            // 放大态返回的飞行起点(共享口径,见 viewerHeroRectTween)
            createRectTween: viewerHeroRectTween,
            // 网格瓦片来源(coverFlight)换裁切插值飞行体,否则返回纯图片。
            //
            // 这里**不再**挂 startPopping 的动画监听:push 飞行未跑完就被
            // pop 打断时,框架走 _HeroFlight.divert 且不重建 shuttle
            // (heroes.dart:`shuttle ??= manifest.shuttleBuilder(...)`),
            // 本 builder 全程只以 push 方向调用一次,pop 分支永不执行 ⇒
            // 源端 Opacity 锁死在 0 ⇒ 空洞黑闪。宣告退场已改由查看器在
            // 路由转 reverse / 手势置位时直接做,与 shuttle 无关。
            flightShuttleBuilder: (flightContext, animation, direction, fromContext, toContext) {
              // 自绘飞行体需要位图源;有它就用,以便 cover 窗口/圆角随飞行
              // 插值。判据走 effective* —— style 给了就以它为准。
              if (widget.flightImage != null &&
                  (widget.effectiveCover || widget.effectiveCircular)) {
                // 源端缩略图盒子的固定宽高比:push 时源在 from,pop 时源在 to。
                // 飞行起止两端的盒子布局在 flight 启动时已测好,此处读到的是
                // 稳定值。push 被 pop 打断(divert)不重建 shuttle,仍持 push
                // 时算得的 from=源端,与 pop 的 to 是同一缩略图,口径一致。
                final BuildContext srcContext =
                    direction == HeroFlightDirection.pop
                        ? toContext
                        : fromContext;
                double? sourceAspect;
                final ro = srcContext.findRenderObject();
                if (ro is RenderBox && ro.hasSize && ro.size.height > 0) {
                  sourceAspect = ro.size.width / ro.size.height;
                }
                return CoverContainFlightImage(
                  image: widget.flightImage!,
                  animation: animation,
                  radius: widget.effectiveRadius,
                  circular: widget.effectiveCircular,
                  // 贴源端窗口要与源端 Image(fit:cover) 的可见区域对齐,
                  // 否则落地瞬间「裁切一块」突变成完整图
                  coverSource: true,
                  sourceAspect: sourceAspect,
                  fallback: child,
                );
              }
              return child;
            },
            // 飞行期间源端占位 - 直接读取最新状态
            placeholderBuilder: (context, heroSize, _) {
              final ctrl = HeroVisibilityController.instance;
              final currentIsPopping = ctrl.isPopping;
              final currentHiddenTag = ctrl.hiddenHeroTag;

              // pop 飞行中 或 当前正在查看的图片：空占位
              if (currentIsPopping || currentHiddenTag == heroTag) {
                return SizedBox(width: heroSize.width, height: heroSize.height);
              }
              // 其他图片：显示图片
              return GestureDetector(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                onSecondaryTapUp: widget.onSecondaryTapUp,
                child: SizedBox(
                  width: heroSize.width,
                  height: heroSize.height,
                  child: child,
                ),
              );
            },
            child: GestureDetector(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              onSecondaryTapUp: widget.onSecondaryTapUp,
              child: child,
            ),
        );

        // aspectRatio 套在 Hero **外面**:它约束的是 Hero 的盒子,让盒子 ≡
        // 画面。contain 展示的源端(轮播/正文)若盒子大于画面,Hero 飞行几何
        // 取的是盒子,尾帧就会铺满盒子而非贴合画面。
        final double? ratio = widget.aspectRatio;
        return Opacity(
          opacity: shouldHide ? 0.0 : 1.0,
          child: ratio == null
              ? hero
              : Center(child: AspectRatio(aspectRatio: ratio, child: hero)),
        );
      },
    );
  }
}
