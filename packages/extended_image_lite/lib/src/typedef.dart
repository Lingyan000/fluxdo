import 'dart:ui' as ui show Image;
import 'package:flutter/material.dart';

import 'gesture/utils.dart';
import 'gesture/slide_page.dart';

///
///  extended_image_typedef.dart
///  create by zmtzawqlp on 2019/4/3
///  modified for extended_image_lite
///

/// [rect] is render size
/// if return true, it will not paint original image,
typedef BeforePaintImage =
    bool Function(Canvas canvas, Rect rect, ui.Image image, Paint paint);

/// Call after paint image
typedef AfterPaintImage =
    void Function(Canvas canvas, Rect rect, ui.Image image, Paint paint);

/// Animation call back for inertia drag
typedef GestureOffsetAnimationCallBack = void Function(Offset offset);

/// Animation call back for scale
typedef GestureScaleAnimationCallBack = void Function(double scale);

/// Build page background when slide page
typedef SlidePageBackgroundHandler =
    Color Function(Offset offset, Size pageSize);

/// customize offset of page when slide page
typedef SlideOffsetHandler =
    Offset? Function(Offset offset, {ExtendedImageSlidePageState state});

/// if return true ,pop page
/// else reset page state
typedef SlideEndHandler =
    bool? Function(
      Offset offset, {
      required ExtendedImageSlidePageState state,
      required ScaleEndDetails details,
    });

/// Customize scale of page when slide page
typedef SlideScaleHandler =
    double? Function(Offset offset, {ExtendedImageSlidePageState state});

/// Call on sliding page
typedef OnSlidingPage = void Function(ExtendedImageSlidePageState state);

/// Whether we can scroll page
typedef CanScrollPage = bool Function(GestureDetails? gestureDetails);

/// Return initial destination rect
typedef InitDestinationRect = void Function(Rect initialDestinationRect);

/// Build Gesture Image
typedef BuildGestureImage = Widget Function(GestureDetails gestureDetails);

/// Build Hero only for sliding page
/// the transform of sliding page must be working on Hero
/// so that Hero animation wouldn't be strange when pop page
typedef HeroBuilderForSlidingPage = Widget Function(Widget widget);

/// Whether should scale image
typedef CanScaleImage = bool Function(GestureDetails? details);

/// Call when GestureDetails is changed
typedef GestureDetailsIsChanged = void Function(GestureDetails? details);
