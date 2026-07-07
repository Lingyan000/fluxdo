import 'package:flutter/material.dart';
import '../typedef.dart';
import '../utils.dart';
import 'slide_page.dart';
import 'utils.dart';

///
///  create by zmtzawqlp on 2019/6/14
///

/// for loading/failed widget
class ExtendedImageSlidePageHandler extends StatefulWidget {
  const ExtendedImageSlidePageHandler({super.key, 
    this.child,
    this.extendedImageSlidePageState,
    this.heroBuilderForSlidingPage,
  });
  final Widget? child;
  final ExtendedImageSlidePageState? extendedImageSlidePageState;

  ///build Hero only for sliding page
  final HeroBuilderForSlidingPage? heroBuilderForSlidingPage;
  @override
  ExtendedImageSlidePageHandlerState createState() =>
      ExtendedImageSlidePageHandlerState();
}

class ExtendedImageSlidePageHandlerState
    extends State<ExtendedImageSlidePageHandler> {
  late Offset _startingOffset;
  ExtendedImageSlidePageState? _extendedImageSlidePageState;
  @override
  void didChangeDependencies() {
    _extendedImageSlidePageState =
        widget.extendedImageSlidePageState ??
        context.findAncestorStateOfType<ExtendedImageSlidePageState>();
    // 滑动进行中因树重建而新建时接管滑动驱动(同 gesture 层的重绑逻辑)
    _extendedImageSlidePageState?.rebindSlideTarget(handlerState: this);
    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(covariant ExtendedImageSlidePageHandler oldWidget) {
    _extendedImageSlidePageState =
        widget.extendedImageSlidePageState ??
        context.findAncestorStateOfType<ExtendedImageSlidePageState>();
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    Widget result = GestureDetector(
      onScaleStart: _handleScaleStart,
      onScaleUpdate: _handleScaleUpdate,
      onScaleEnd: _handleScaleEnd,
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
    if (_extendedImageSlidePageState != null) {
      result = widget.heroBuilderForSlidingPage?.call(result) ?? result;
    }
    if (_extendedImageSlidePageState != null &&
        _extendedImageSlidePageState!.widget.slideType == SlideType.onlyImage) {
      result = Transform.translate(
        offset: _extendedImageSlidePageState!.offset,
        child: Transform.scale(
          scale: _extendedImageSlidePageState!.scale,
          child: result,
        ),
      );
    }
    return result;
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _startingOffset = details.focalPoint;
  }

  Offset? _updateSlidePagePreOffset;
  void _handleScaleUpdate(ScaleUpdateDetails details) {
    ///whether gesture page
    if (_extendedImageSlidePageState != null && details.scale == 1.0) {
      final double delta = (details.focalPoint - _startingOffset).distance;

      if (delta.greaterThan(minGesturePageDelta)) {
        _updateSlidePagePreOffset ??= details.focalPoint;
        _extendedImageSlidePageState!.slide(
          details.focalPoint - _updateSlidePagePreOffset!,
          extendedImageSlidePageHandlerState: this,
        );
        _updateSlidePagePreOffset = details.focalPoint;
      }
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _updateSlidePagePreOffset = null;
    if (_extendedImageSlidePageState != null &&
        _extendedImageSlidePageState!.isSliding) {
      _extendedImageSlidePageState!.endSlide(details);
      return;
    }
    // 兜底：isSliding 已为 false 但页面仍处于偏移状态（竞态导致），强制回弹
    _extendedImageSlidePageState?.resetIfNeeded();
  }

  @override
  void dispose() {
    // 如果正在驱动滑动关闭时被销毁（如图片加载完成导致 widget 树重建），
    // 需要通知 SlidePageState 结束滑动，避免页面卡在中间位置
    if (_extendedImageSlidePageState != null &&
        _extendedImageSlidePageState!.isSliding) {
      final slidePageState = _extendedImageSlidePageState!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (slidePageState.mounted && slidePageState.isSliding) {
          slidePageState.endSlide(ScaleEndDetails());
        }
      });
    }
    super.dispose();
  }

  void slide() {
    if (mounted) {
      setState(() {});
    }
  }
}
