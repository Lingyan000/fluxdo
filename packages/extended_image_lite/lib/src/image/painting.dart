import 'dart:ui' as ui show Image;
import 'package:material_ui/material_ui.dart';
import '../typedef.dart';
import '../utils.dart';
import '../gesture/utils.dart';

/// Paints an image into the given rectangle on the canvas.
/// Simplified version without editor support.
void paintExtendedImage({
  required Canvas canvas,
  required Rect rect,
  required ui.Image image,
  String? debugImageLabel,
  double scale = 1.0,
  double opacity = 1.0,
  ColorFilter? colorFilter,
  BoxFit? fit,
  Alignment alignment = Alignment.center,
  Rect? centerSlice,
  ImageRepeat repeat = ImageRepeat.noRepeat,
  bool flipHorizontally = false,
  bool invertColors = false,
  FilterQuality filterQuality = FilterQuality.low,
  Rect? customSourceRect,
  BeforePaintImage? beforePaintImage,
  AfterPaintImage? afterPaintImage,
  GestureDetails? gestureDetails,
  bool isAntiAlias = false,
  EdgeInsets layoutInsets = EdgeInsets.zero,
}) {
  assert(
    image.debugGetOpenHandleStackTraces()?.isNotEmpty ?? true,
    'Cannot paint an image that is disposed.\n'
    'The caller of paintImage is expected to wait to dispose the image until '
    'after painting has completed.',
  );
  if (rect.isEmpty) {
    return;
  }

  final Rect paintRect = rect;
  rect = layoutInsets.deflateRect(rect);

  Size outputSize = rect.size;
  Size inputSize = Size(image.width.toDouble(), image.height.toDouble());

  final Offset topLeft = rect.topLeft;

  Offset? sliceBorder;
  if (centerSlice != null) {
    sliceBorder = Offset(
      centerSlice.left + inputSize.width - centerSlice.right,
      centerSlice.top + inputSize.height - centerSlice.bottom,
    );
    outputSize = outputSize - sliceBorder as Size;
    inputSize = inputSize - sliceBorder as Size;
  }
  fit ??= centerSlice == null ? BoxFit.scaleDown : BoxFit.fill;
  assert(centerSlice == null || (fit != BoxFit.none && fit != BoxFit.cover));
  final FittedSizes fittedSizes = applyBoxFit(
    fit,
    inputSize / scale,
    outputSize,
  );
  final Size sourceSize = fittedSizes.source * scale;
  Size destinationSize = fittedSizes.destination;
  if (centerSlice != null) {
    outputSize += sliceBorder!;
    destinationSize += sliceBorder;
    assert(
      sourceSize == inputSize,
      'centerSlice was used with a BoxFit that does not guarantee that the image is fully visible.',
    );
  }
  if (repeat != ImageRepeat.noRepeat && destinationSize == outputSize) {
    repeat = ImageRepeat.noRepeat;
  }
  final Paint paint = Paint()..isAntiAlias = isAntiAlias;
  if (colorFilter != null) {
    paint.colorFilter = colorFilter;
  }
  paint.color = Color.fromRGBO(0, 0, 0, opacity);
  paint.filterQuality = filterQuality;
  paint.invertColors = invertColors;
  final double halfWidthDelta =
      (outputSize.width - destinationSize.width) / 2.0;
  final double halfHeightDelta =
      (outputSize.height - destinationSize.height) / 2.0;
  final double dx =
      halfWidthDelta +
      (flipHorizontally ? -alignment.x : alignment.x) * halfWidthDelta;
  final double dy = halfHeightDelta + alignment.y * halfHeightDelta;
  final Offset destinationPosition = topLeft.translate(dx, dy);
  Rect destinationRect = destinationPosition & destinationSize;

  bool needClip = false;

  if (gestureDetails != null) {
    destinationRect = gestureDetails.calculateFinalDestinationRect(
      rect,
      destinationRect,
    );

    // outside and need clip
    needClip = !rect.containsRect(destinationRect);

    if (gestureDetails.slidePageOffset != null) {
      destinationRect = destinationRect.shift(gestureDetails.slidePageOffset!);
      rect = rect.shift(gestureDetails.slidePageOffset!);
    }

    if (needClip) {
      canvas.save();
      canvas.clipRect(paintRect);
    }
  }

  if (beforePaintImage != null) {
    final bool handle = beforePaintImage(canvas, destinationRect, image, paint);
    if (handle) {
      return;
    }
  }

  final bool needSave = repeat != ImageRepeat.noRepeat || flipHorizontally;
  if (needSave) {
    canvas.save();
  }
  if (repeat != ImageRepeat.noRepeat && centerSlice != null) {
    canvas.clipRect(paintRect);
  }
  if (flipHorizontally) {
    final double dx = -(rect.left + rect.width / 2.0);
    canvas.translate(-dx, 0.0);
    canvas.scale(-1.0, 1.0);
    canvas.translate(dx, 0.0);
  }

  if (centerSlice == null) {
    final Rect sourceRect =
        customSourceRect ??
        alignment.inscribe(sourceSize, Offset.zero & inputSize);
    if (repeat == ImageRepeat.noRepeat) {
      canvas.drawImageRect(image, sourceRect, destinationRect, paint);
    } else {
      for (final Rect tileRect in _generateImageTileRects(
        rect,
        destinationRect,
        repeat,
      )) {
        canvas.drawImageRect(image, sourceRect, tileRect, paint);
      }
    }
  } else {
    canvas.scale(1 / scale);
    if (repeat == ImageRepeat.noRepeat) {
      canvas.drawImageNine(
        image,
        _scaleRect(centerSlice, scale),
        _scaleRect(destinationRect, scale),
        paint,
      );
    } else {
      for (final Rect tileRect in _generateImageTileRects(
        rect,
        destinationRect,
        repeat,
      )) {
        canvas.drawImageNine(
          image,
          _scaleRect(centerSlice, scale),
          _scaleRect(tileRect, scale),
          paint,
        );
      }
    }
  }

  if (needSave) {
    canvas.restore();
  }

  if (needClip) {
    canvas.restore();
  }

  if (afterPaintImage != null) {
    afterPaintImage(canvas, destinationRect, image, paint);
  }
}

List<Rect> _generateImageTileRects(
  Rect outputRect,
  Rect fundamentalRect,
  ImageRepeat repeat,
) {
  int startX = 0;
  int startY = 0;
  int stopX = 0;
  int stopY = 0;
  final double strideX = fundamentalRect.width;
  final double strideY = fundamentalRect.height;

  if (repeat == ImageRepeat.repeat || repeat == ImageRepeat.repeatX) {
    startX = ((outputRect.left - fundamentalRect.left) / strideX).floor();
    stopX = ((outputRect.right - fundamentalRect.right) / strideX).ceil();
  }

  if (repeat == ImageRepeat.repeat || repeat == ImageRepeat.repeatY) {
    startY = ((outputRect.top - fundamentalRect.top) / strideY).floor();
    stopY = ((outputRect.bottom - fundamentalRect.bottom) / strideY).ceil();
  }

  return <Rect>[
    for (int i = startX; i <= stopX; ++i)
      for (int j = startY; j <= stopY; ++j)
        fundamentalRect.shift(Offset(i * strideX, j * strideY)),
  ];
}

Rect _scaleRect(Rect rect, double scale) => Rect.fromLTRB(
  rect.left * scale,
  rect.top * scale,
  rect.right * scale,
  rect.bottom * scale,
);

/// Helper to get destination rect
Rect getDestinationRect({
  required Size inputSize,
  required Rect rect,
  BoxFit? fit,
  bool flipHorizontally = false,
  double scale = 1.0,
  Rect? centerSlice,
  Alignment alignment = Alignment.center,
}) {
  Size outputSize = rect.size;
  final Offset topLeft = rect.topLeft;

  Offset? sliceBorder;
  if (centerSlice != null) {
    sliceBorder = Offset(
      centerSlice.left + inputSize.width - centerSlice.right,
      centerSlice.top + inputSize.height - centerSlice.bottom,
    );
    outputSize = outputSize - sliceBorder as Size;
    inputSize = inputSize - sliceBorder as Size;
  }
  fit ??= centerSlice == null ? BoxFit.scaleDown : BoxFit.fill;

  final FittedSizes fittedSizes = applyBoxFit(
    fit,
    inputSize / scale,
    outputSize,
  );
  Size destinationSize = fittedSizes.destination;
  if (centerSlice != null) {
    outputSize += sliceBorder!;
    destinationSize += sliceBorder;
  }

  final double halfWidthDelta =
      (outputSize.width - destinationSize.width) / 2.0;
  final double halfHeightDelta =
      (outputSize.height - destinationSize.height) / 2.0;
  final double dx =
      halfWidthDelta +
      (flipHorizontally ? -alignment.x : alignment.x) * halfWidthDelta;
  final double dy = halfHeightDelta + alignment.y * halfHeightDelta;
  final Offset destinationPosition = topLeft.translate(dx, dy);

  return destinationPosition & destinationSize;
}
