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
    this.fallback,
  });

  final ImageProvider image;
  final Animation<double> animation;

  /// 源圆角(t=0 端,插值到 0);[circular] 为 true 时忽略
  final double radius;

  /// 源为圆形裁切(头像):t=0 端圆角 = 短边一半,随飞行插值到 0
  final bool circular;

  /// 纹理未就绪时的退化显示(通常传 Hero child,= 无插值的旧行为;
  /// 飞行纹理走缓存几乎必然同步命中,此为极端情况兜底,防空白飞行)
  final Widget? fallback;

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
  }) : super(repaint: animation);

  final ui.Image image;
  final Animation<double> animation;
  final double radius;
  final bool circular;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t = animation.value.clamp(0.0, 1.0);
    final double imgW = image.width.toDouble();
    final double imgH = image.height.toDouble();

    // cover 源矩形:按目标宽高比从全图中心裁出可见窗口
    final double coverScale = math.max(size.width / imgW, size.height / imgH);
    final Rect coverSrc = Rect.fromCenter(
      center: Offset(imgW / 2, imgH / 2),
      width: size.width / coverScale,
      height: size.height / coverScale,
    );
    // contain 源矩形 = 全图;飞行进度插值:t=0 cover 窗口 → t=1 全图
    final Rect containSrc = Rect.fromLTWH(0, 0, imgW, imgH);
    final Rect src = Rect.lerp(coverSrc, containSrc, t)!;

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
      animation != oldDelegate.animation;
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

  /// 源为 cover 裁切展示(网格瓦片)时传入:飞行体换成
  /// [CoverContainFlightImage] 裁切插值(需与 [flightImage] 同传)
  final bool coverFlight;

  /// 飞行体绘制用的图片 provider(通常=缩略图,已解码命中缓存)
  final ImageProvider? flightImage;

  /// 源瓦片圆角(飞行中插值到 0)
  final double flightRadius;

  const HeroImage({
    super.key,
    required this.heroTag,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapUp,
    this.coverFlight = false,
    this.flightImage,
    this.flightRadius = 0,
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

        return Opacity(
          opacity: shouldHide ? 0.0 : 1.0,
          child: Hero(
            tag: heroTag,
            // Android 预测返回是 user gesture 转场,须显式开启才有飞行
            transitionOnUserGestures: true,
            // 飞行动画：pop 飞行结束时设置 isPopping;网格瓦片来源
            // (coverFlight)换裁切插值飞行体,否则返回纯图片
            flightShuttleBuilder: (flightContext, animation, direction, fromContext, toContext) {
              if (direction == HeroFlightDirection.pop) {
                void listener(AnimationStatus status) {
                  if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
                    animation.removeStatusListener(listener);
                    HeroVisibilityController.instance.startPopping();
                  }
                }
                animation.addStatusListener(listener);
              }
              if (widget.coverFlight && widget.flightImage != null) {
                return CoverContainFlightImage(
                  image: widget.flightImage!,
                  animation: animation,
                  radius: widget.flightRadius,
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
          ),
        );
      },
    );
  }
}
