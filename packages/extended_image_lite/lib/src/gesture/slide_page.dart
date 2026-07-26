import 'package:flutter/material.dart';

import '../typedef.dart';
import 'gesture_controller.dart';
import 'utils.dart';

enum SlideAxis { both, horizontal, vertical }

enum SlideType { wholePage, onlyImage }

class ExtendedImageSlidePage extends StatefulWidget {
  const ExtendedImageSlidePage({
    this.child,
    this.slidePageBackgroundHandler,
    this.slideScaleHandler,
    this.slideOffsetHandler,
    this.slideEndHandler,
    this.slideAxis = SlideAxis.both,
    this.resetPageDuration = const Duration(milliseconds: 500),
    this.slideType = SlideType.onlyImage,
    this.onSlidingPage,
    super.key,
  });

  ///The [child] contained by the ExtendedImageGesturePage.
  final Widget? child;

  ///builder background when slide page
  final SlidePageBackgroundHandler? slidePageBackgroundHandler;

  ///customize scale of page when slide page
  final SlideScaleHandler? slideScaleHandler;

  ///customize offset when slide page
  final SlideOffsetHandler? slideOffsetHandler;

  ///call back of slide end
  ///decide whether pop page
  final SlideEndHandler? slideEndHandler;

  ///axis of slide
  ///both,horizontal,vertical
  final SlideAxis slideAxis;

  ///reset page position when slide end(not pop page)
  final Duration resetPageDuration;

  /// slide whole page or only image
  final SlideType slideType;

  /// on sliding page
  final OnSlidingPage? onSlidingPage;
  @override
  ExtendedImageSlidePageState createState() => ExtendedImageSlidePageState();
}

class ExtendedImageSlidePageState extends State<ExtendedImageSlidePage>
    with SingleTickerProviderStateMixin {
  bool _isSliding = false;

  ///whether is sliding page
  bool get isSliding => _isSliding;

  /// 滑动会话 ID，每次新滑动开始时递增。
  /// 用于防止回弹动画完成时误将新会话的 _isSliding 重置。
  int _slideSessionId = 0;

  Size? _pageSize;
  Size get pageSize => _pageSize ?? context.size!;

  late AnimationController _backAnimationController;
  AnimationController get backAnimationController => _backAnimationController;
  Animation<Offset>? _backOffsetAnimation;
  Animation<Offset>? get backOffsetAnimation => _backOffsetAnimation;
  Animation<double>? _backScaleAnimation;
  Animation<double>? get backScaleAnimation => _backScaleAnimation;
  Offset _offset = Offset.zero;
  Offset get offset =>
      _backAnimationController.isAnimating
          ? _backOffsetAnimation!.value
          : _offset;
  double _scale = 1.0;
  double get scale =>
      _backAnimationController.isAnimating ? backScaleAnimation!.value : _scale;

  @override
  void initState() {
    super.initState();
    _backAnimationController = AnimationController(
      vsync: this,
      duration: widget.resetPageDuration,
    );
    _backAnimationController.addListener(_backAnimation);
  }

  @override
  void didUpdateWidget(ExtendedImageSlidePage oldWidget) {
    if (oldWidget.resetPageDuration != widget.resetPageDuration) {
      _backAnimationController.stop();
      _backAnimationController.removeListener(_backAnimation);
      _backAnimationController.dispose();
      _backAnimationController = AnimationController(
        vsync: this,
        duration: widget.resetPageDuration,
      );
      _backAnimationController.addListener(_backAnimation);
    }
    super.didUpdateWidget(oldWidget);
  }

  /// 滑动驱动目标:每 tick 写入 controller,绘制层监听 controller
  /// 重绘 —— 手势状态在 Widget 树之外,树切换不再中断滑动。
  ImageGestureController? _gestureController;

  /// 回弹动画启动时记录的会话 ID
  int _backAnimationSessionId = -1;

  void _backAnimation() {
    if (mounted) {
      setState(() {
        // 仅当回弹动画的会话 ID 与当前一致时才重置 _isSliding，
        // 避免新滑动会话被旧动画误重置。
        if (_backAnimationController.isCompleted &&
            _backAnimationSessionId == _slideSessionId) {
          _isSliding = false;
        }
      });
    }
    if (widget.slideType == SlideType.onlyImage) {
      _gestureController?.updateSlide(offset, scale);
    }
    widget.onSlidingPage?.call(this);
  }

  @override
  void dispose() {
    _backAnimationController.removeListener(_backAnimation);
    _backAnimationController.dispose();
    super.dispose();
  }

  void slide(Offset value, {ImageGestureController? controller}) {
    // 如果回弹动画正在播放，打断它并从当前动画位置开始新滑动
    if (_backAnimationController.isAnimating) {
      _offset = _backOffsetAnimation?.value ?? _offset;
      _scale = _backScaleAnimation?.value ?? _scale;
      _backAnimationController.stop();
    }
    if (controller != null) {
      _gestureController = controller;
    }

    if (widget.slideAxis == SlideAxis.horizontal) {
      _offset += Offset(value.dx, 0.0);
    } else if (widget.slideAxis == SlideAxis.vertical) {
      _offset += Offset(0.0, value.dy);
    } else {
      _offset += value;
    }
    _offset = widget.slideOffsetHandler?.call(_offset, state: this) ?? _offset;

    _scale =
        widget.slideScaleHandler?.call(_offset, state: this) ??
        defaultSlideScaleHandler(
          offset: _offset,
          pageSize: pageSize,
          pageGestureAxis: widget.slideAxis,
        );

    if (!_isSliding) {
      _slideSessionId++;
    }
    _isSliding = true;
    if (widget.slideType == SlideType.onlyImage) {
      _gestureController?.updateSlide(_offset, _scale);
    }

    if (mounted) {
      setState(() {});
    }
    widget.onSlidingPage?.call(this);
  }

  void endSlide(ScaleEndDetails details) {
    if (mounted && _isSliding) {
      final bool popPage =
          widget.slideEndHandler?.call(
            _offset,
            state: this,
            details: details,
          ) ??
          defaultSlideEndHandler(
            offset: _offset,
            pageSize: pageSize,
            pageGestureAxis: widget.slideAxis,
          );

      if (popPage) {
        setState(() {
          _isSliding = false;
        });
        // 黑底不做瞬时透明:保持松手时的透明度,随路由反向过场
        // (FadeTransition)渐隐 —— 与按钮/返回键关闭同一套视觉。
        Navigator.pop(context);
      } else {
        if (_offset != Offset.zero || _scale != 1.0) {
          _backOffsetAnimation = _backAnimationController.drive(
            Tween<Offset>(begin: _offset, end: Offset.zero),
          );
          _backScaleAnimation = _backAnimationController.drive(
            Tween<double>(begin: _scale, end: 1.0),
          );
          _offset = Offset.zero;
          _scale = 1.0;
          _backAnimationSessionId = _slideSessionId;
          _backAnimationController.reset();
          _backAnimationController.forward();
        } else {
          setState(() {
            _isSliding = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _pageSize = MediaQuery.of(context).size;
    final Color pageColor =
        widget.slidePageBackgroundHandler?.call(offset, pageSize) ??
        defaultSlidePageBackgroundHandler(
          offset: offset,
          pageSize: pageSize,
          color: Theme.of(context).scaffoldBackgroundColor,
          pageGestureAxis: widget.slideAxis,
        );

    Widget? result = widget.child;
    if (widget.slideType == SlideType.wholePage) {
      result = Transform.translate(
        offset: offset,
        child: Transform.scale(scale: scale, child: result),
      );
    }

    result = Container(color: pageColor, child: result);

    return result;
  }
}
