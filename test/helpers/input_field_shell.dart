import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void expectInputShellStroke({
  required ShapeBorder stroke,
  required RoundedSuperellipseBorder outline,
  required Size size,
  required InputBorder? themeBorder,
}) {
  final side = themeBorder?.borderSide ?? BorderSide.none;
  if (themeBorder is! UnderlineInputBorder) {
    expect(stroke, outline.copyWith(side: side));
    return;
  }

  final bounds = Offset.zero & size;
  final outerPath = outline.getOuterPath(
    bounds,
    textDirection: TextDirection.ltr,
  );
  void paint(Canvas canvas) =>
      stroke.paint(canvas, bounds, textDirection: TextDirection.ltr);
  final offset = Offset(0, side.width / 2);
  expect(
    paint,
    paints
      ..clipPath(
        pathMatcher: coversSameAreaAs(outerPath, areaToCompare: bounds),
      )
      ..line(
        p1: bounds.bottomLeft - offset,
        p2: bounds.bottomRight - offset,
        color: side.color,
        strokeWidth: side.width,
      ),
  );
  final canvas = TestRecordingCanvas();
  paint(canvas);
  expect(canvas.invocations.map((call) => call.invocation.memberName), [
    #save,
    #clipPath,
    #drawLine,
    #restore,
  ]);
}
