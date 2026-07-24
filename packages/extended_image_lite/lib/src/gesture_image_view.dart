import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'gesture/gesture_controller.dart';
import 'gesture/gesture_surface.dart';
import 'image/raw_gesture_image.dart';

/// 失败态构建(AVIF/SVG 嗅探 fallback 由主工程注入)
typedef GestureImageFailedBuilder =
    Widget Function(BuildContext context, ImageGestureController controller);

/// 手势图片查看组件 —— 持久层栈 + 常驻手势层。
///
/// 替代旧的 `ExtendedImage(mode: gesture)` 用法。与旧架构的本质区别:
/// widget 树一次挂载后不再随 LoadState 切换 —— 缩略图层常驻,原图层
/// 首帧就绪后 150ms 淡入盖上,失败态叠加 fallback 层。两个图层消费
/// 同一 [ImageGestureController] 的 destination rect 数学,切换过程
/// 零位置跳动;进行中的手势(如下滑关闭)不会因加载完成而中断。
///
/// 层栈(自下而上):
/// 1. 缩略图层(placeholder,立即 resolve,常驻到原图淡入完成)
/// 2. 原图层(image,首帧就绪 → 150ms easeOut 淡入)
/// 3. 失败层(failedBuilder)或加载指示(loadingBuilder,无缩略图时)
class GestureImageView extends StatefulWidget {
  const GestureImageView({
    super.key,
    required this.image,
    required this.controller,
    this.placeholder,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.medium,
    this.enableSlideOutPage = false,
    this.inPageView = false,
    this.onDoubleTap,
    this.heroBuilder,
    this.failedBuilder,
    this.loadingBuilder,
    this.onImageLoaded,
  });

  /// 主图 provider
  final ImageProvider image;

  /// 缩略图 provider(占位层,通常命中帖内已解码缓存)
  final ImageProvider? placeholder;

  final ImageGestureController controller;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final bool enableSlideOutPage;
  final bool inPageView;
  final SurfaceDoubleTap? onDoubleTap;

  /// Hero 包装(原 heroBuilderForSlidingPage 语义:包在图层之外、
  /// slide Transform 之内,保证 pop 飞行几何正确)
  final Widget Function(Widget child)? heroBuilder;

  /// 主图解码失败时叠加的 fallback 层(缩略图层保持在底下)
  final GestureImageFailedBuilder? failedBuilder;

  /// 无缩略图且主图未就绪时的加载指示
  final WidgetBuilder? loadingBuilder;

  /// 主图首帧就绪回调(供 viewer 缓存尺寸做智能双击缩放)
  final void Function(ImageInfo info)? onImageLoaded;

  @override
  State<GestureImageView> createState() => _GestureImageViewState();
}

class _GestureImageViewState extends State<GestureImageView>
    with SingleTickerProviderStateMixin {
  ImageStream? _mainStream;
  ImageStreamListener? _mainListener;
  ImageInfo? _mainInfo;
  bool _mainFailed = false;
  bool _mainFirstFrameNotified = false;

  ImageStream? _placeholderStream;
  ImageStreamListener? _placeholderListener;
  ImageInfo? _placeholderInfo;

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  late final Animation<double> _fadeAnimation = _fadeController.drive(
    CurveTween(curve: Curves.easeOut),
  );

  /// 淡入完成后不再绘制缩略图层
  bool get _placeholderRetired =>
      _fadeController.isCompleted && _mainInfo != null;

  @override
  void initState() {
    super.initState();
    _fadeController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        // 淡入结束,收掉缩略图层(一次性 rebuild)
        setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveStreams();
  }

  @override
  void didUpdateWidget(GestureImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image ||
        widget.placeholder != oldWidget.placeholder) {
      if (widget.image != oldWidget.image) {
        // 主图换代:回到未就绪状态重新淡入
        _mainFailed = false;
        _mainFirstFrameNotified = false;
        _fadeController.value = 0.0;
        _replaceMainInfo(null);
      }
      _resolveStreams();
    }
  }

  void _resolveStreams() {
    final ImageConfiguration configuration = createLocalImageConfiguration(
      context,
    );

    final ImageStream newMainStream = widget.image.resolve(configuration);
    if (newMainStream.key != _mainStream?.key) {
      _detachMainStream();
      _mainStream = newMainStream;
      _mainListener = ImageStreamListener(
        _handleMainFrame,
        onError: _handleMainError,
      );
      newMainStream.addListener(_mainListener!);
    }

    final ImageProvider? placeholder = widget.placeholder;
    if (placeholder != null) {
      final ImageStream newPlaceholderStream = placeholder.resolve(
        configuration,
      );
      if (newPlaceholderStream.key != _placeholderStream?.key) {
        _detachPlaceholderStream();
        _placeholderStream = newPlaceholderStream;
        _placeholderListener = ImageStreamListener(
          _handlePlaceholderFrame,
          // 缩略图失败静默:主图路径不受影响
          onError: (Object exception, StackTrace? stackTrace) {},
        );
        newPlaceholderStream.addListener(_placeholderListener!);
      }
    } else {
      _detachPlaceholderStream();
      _replacePlaceholderInfo(null);
    }
  }

  void _handleMainFrame(ImageInfo info, bool synchronousCall) {
    _replaceMainInfo(info);
    _mainFailed = false;
    if (!_mainFirstFrameNotified) {
      _mainFirstFrameNotified = true;
      widget.onImageLoaded?.call(info);
      // 首帧就绪后下一帧再起淡入:让首帧完成光栅化/纹理上传,
      // 上传卡顿藏在缩略图仍然全量显示的时刻
      if (synchronousCall) {
        // 同步命中缓存(如返回复看):无需淡入,直接就绪
        _fadeController.value = 1.0;
      } else {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _fadeController.forward();
          }
        });
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleMainError(Object exception, StackTrace? stackTrace) {
    _mainFailed = true;
    if (mounted) {
      setState(() {});
    }
  }

  void _handlePlaceholderFrame(ImageInfo info, bool synchronousCall) {
    _replacePlaceholderInfo(info);
    if (mounted && !synchronousCall) {
      setState(() {});
    }
  }

  void _replaceMainInfo(ImageInfo? info) {
    if (identical(info, _mainInfo)) {
      return;
    }
    _mainInfo?.dispose();
    _mainInfo = info;
  }

  void _replacePlaceholderInfo(ImageInfo? info) {
    if (identical(info, _placeholderInfo)) {
      return;
    }
    _placeholderInfo?.dispose();
    _placeholderInfo = info;
  }

  void _detachMainStream() {
    if (_mainListener != null) {
      _mainStream?.removeListener(_mainListener!);
    }
    _mainStream = null;
    _mainListener = null;
  }

  void _detachPlaceholderStream() {
    if (_placeholderListener != null) {
      _placeholderStream?.removeListener(_placeholderListener!);
    }
    _placeholderStream = null;
    _placeholderListener = null;
  }

  @override
  void dispose() {
    _detachMainStream();
    _detachPlaceholderStream();
    _replaceMainInfo(null);
    _replacePlaceholderInfo(null);
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ImageGestureController controller = widget.controller;
    final bool showFailed = _mainFailed && widget.failedBuilder != null;
    final bool showLoading =
        !showFailed &&
        _mainInfo == null &&
        _placeholderInfo == null &&
        !_mainFailed &&
        widget.loadingBuilder != null;

    Widget layers = Stack(
      fit: StackFit.expand,
      children: [
        // 缩略图层:常驻到原图淡入完成(失败态也保底显示)
        if (_placeholderInfo != null && (!_placeholderRetired || showFailed))
          RawGestureImage(
            controller: controller,
            image: _placeholderInfo!.image,
            scale: _placeholderInfo!.scale,
            fit: widget.fit,
            filterQuality: widget.filterQuality,
          ),
        // 原图层:首帧就绪后淡入
        if (_mainInfo != null && !showFailed)
          RawGestureImage(
            controller: controller,
            image: _mainInfo!.image,
            scale: _mainInfo!.scale,
            opacity: _fadeAnimation,
            fit: widget.fit,
            filterQuality: widget.filterQuality,
          ),
        if (showFailed) widget.failedBuilder!(context, controller),
        if (showLoading) widget.loadingBuilder!(context),
      ],
    );

    // Hero 必须包在 slide Transform 之内(pop 飞行几何依赖,
    // 语义同旧 heroBuilderForSlidingPage)
    if (widget.heroBuilder != null) {
      layers = widget.heroBuilder!(layers);
    }

    // 下滑关闭位移:监听 controller,仅重建 Transform 包装
    // (child 身份稳定,层栈与 Hero 不重建)
    if (widget.enableSlideOutPage) {
      final Widget child = layers;
      layers = ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return Transform.translate(
            offset: controller.slideOffset,
            child: Transform.scale(scale: controller.slideScale, child: child),
          );
        },
      );
    }

    return GestureSurface(
      controller: controller,
      onDoubleTap: widget.onDoubleTap,
      enableSlideOutPage: widget.enableSlideOutPage,
      inPageView: widget.inPageView,
      child: layers,
    );
  }
}
