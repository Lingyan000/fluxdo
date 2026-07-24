import 'dart:ui' as ui show Image;

import 'package:flutter/material.dart' hide Image;
import 'package:flutter/rendering.dart';

import '../gesture/gesture_controller.dart';
import '../gesture/utils.dart';
import 'painting.dart';

/// 手势图层 —— 直接监听 [ImageGestureController] 的绘制叶子。
///
/// 与 ExtendedRawImage 的关键差异:
/// - 手势/滑动每帧不再走 widget 级 setState 重建,RenderObject 在
///   attach 期间监听 controller,每次通知仅 markNeedsPaint;
/// - ui.Image 的 clone 只发生在图片换代时(widget rebuild),手势帧
///   零 clone 零重建。
///
/// [opacity] 用于缩略图→原图的 crossfade(动画驱动,监听后 repaint)。
class RawGestureImage extends LeafRenderObjectWidget {
  const RawGestureImage({
    super.key,
    required this.controller,
    this.image,
    this.scale = 1.0,
    this.opacity,
    this.fit,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
  });

  final ImageGestureController controller;

  /// The image to display.
  final ui.Image? image;

  /// Specifies the image's scale.
  final double scale;

  /// crossfade 透明度(与 gesture 无关,层栈淡入用)
  final Animation<double>? opacity;

  /// How to inscribe the image into the space allocated during layout.
  final BoxFit? fit;

  /// How to align the image within its bounds.
  final Alignment alignment;

  /// Used to set the filterQuality of the image.
  final FilterQuality filterQuality;

  @override
  RenderRawGestureImage createRenderObject(BuildContext context) {
    assert(
      image?.debugGetOpenHandleStackTraces()?.isNotEmpty ?? true,
      'Creator of a RawGestureImage disposed of the image when the '
      'RawGestureImage still needed it.',
    );
    return RenderRawGestureImage(
      controller: controller,
      image: image?.clone(),
      scale: scale,
      opacity: opacity,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderRawGestureImage renderObject,
  ) {
    assert(
      image?.debugGetOpenHandleStackTraces()?.isNotEmpty ?? true,
      'Creator of a RawGestureImage disposed of the image when the '
      'RawGestureImage still needed it.',
    );
    renderObject
      ..controller = controller
      ..image = image?.clone()
      ..scale = scale
      ..opacity = opacity
      ..fit = fit
      ..alignment = alignment
      ..filterQuality = filterQuality;
  }

  @override
  void didUnmountRenderObject(RenderRawGestureImage renderObject) {
    renderObject.image = null;
  }
}

class RenderRawGestureImage extends RenderBox {
  RenderRawGestureImage({
    required ImageGestureController controller,
    ui.Image? image,
    double scale = 1.0,
    Animation<double>? opacity,
    BoxFit? fit,
    Alignment alignment = Alignment.center,
    FilterQuality filterQuality = FilterQuality.medium,
  }) : _controller = controller,
       _image = image,
       _scale = scale,
       _opacity = opacity,
       _fit = fit,
       _alignment = alignment,
       _filterQuality = filterQuality;

  ImageGestureController _controller;
  ImageGestureController get controller => _controller;
  set controller(ImageGestureController value) {
    if (identical(value, _controller)) {
      return;
    }
    if (attached) {
      _controller.removeListener(markNeedsPaint);
    }
    _controller = value;
    if (attached) {
      _controller.addListener(markNeedsPaint);
    }
    markNeedsPaint();
  }

  ui.Image? get image => _image;
  ui.Image? _image;
  set image(ui.Image? value) {
    if (value == _image) {
      return;
    }
    // 同代 clone 直接丢弃,避免无谓换持
    if (value != null && _image != null && value.isCloneOf(_image!)) {
      value.dispose();
      return;
    }
    _image?.dispose();
    _image = value;
    markNeedsPaint();
  }

  double get scale => _scale;
  double _scale;
  set scale(double value) {
    if (value == _scale) {
      return;
    }
    _scale = value;
    markNeedsPaint();
  }

  Animation<double>? get opacity => _opacity;
  Animation<double>? _opacity;
  set opacity(Animation<double>? value) {
    if (value == _opacity) {
      return;
    }
    if (attached) {
      _opacity?.removeListener(markNeedsPaint);
    }
    _opacity = value;
    if (attached) {
      value?.addListener(markNeedsPaint);
    }
    markNeedsPaint();
  }

  BoxFit? get fit => _fit;
  BoxFit? _fit;
  set fit(BoxFit? value) {
    if (value == _fit) {
      return;
    }
    _fit = value;
    markNeedsPaint();
  }

  Alignment get alignment => _alignment;
  Alignment _alignment;
  set alignment(Alignment value) {
    if (value == _alignment) {
      return;
    }
    _alignment = value;
    markNeedsPaint();
  }

  FilterQuality get filterQuality => _filterQuality;
  FilterQuality _filterQuality;
  set filterQuality(FilterQuality value) {
    if (value == _filterQuality) {
      return;
    }
    _filterQuality = value;
    markNeedsPaint();
  }

  @override
  void attach(covariant PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(markNeedsPaint);
    _opacity?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsPaint);
    _opacity?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final ui.Image? image = _image;
    if (image == null) {
      return;
    }
    final double opacityValue = _opacity?.value ?? 1.0;
    if (opacityValue <= 0.0) {
      return;
    }
    final GestureDetails? gestureDetails = _controller.details;
    Rect rect = offset & size;
    if (gestureDetails != null && gestureDetails.slidePageOffset != null) {
      rect = rect.shift(-gestureDetails.slidePageOffset!);
    }
    paintExtendedImage(
      canvas: context.canvas,
      rect: rect,
      image: image,
      scale: _scale,
      opacity: opacityValue,
      fit: _fit,
      alignment: _alignment,
      flipHorizontally: false,
      filterQuality: _filterQuality,
      gestureDetails: gestureDetails,
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
