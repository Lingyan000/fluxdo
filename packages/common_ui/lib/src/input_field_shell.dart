import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'ui_shapes.dart';

/// 超椭圆轮廓的输入框边框，用于与卡片、弹层、菜单等全局超椭圆形状对齐。
///
/// 保持 `isOutline == true`，支持浮动标签缺口裁切，并在 [InputDecoration]
/// 填充时自动沿超椭圆轮廓裁切底色。
class RoundedSuperellipseInputBorder extends InputBorder {
  const RoundedSuperellipseInputBorder({
    super.borderSide = const BorderSide(),
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.gapPadding = 4.0,
  }) : assert(gapPadding >= 0.0);

  final BorderRadius borderRadius;
  final double gapPadding;

  @override
  bool get isOutline => true;

  RoundedSuperellipseBorder get _shape => RoundedSuperellipseBorder(
    borderRadius: borderRadius,
    side: borderSide,
  );

  @override
  RoundedSuperellipseInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) => RoundedSuperellipseInputBorder(
    borderSide: borderSide ?? this.borderSide,
    borderRadius: borderRadius ?? this.borderRadius,
    gapPadding: gapPadding ?? this.gapPadding,
  );

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.width);

  @override
  RoundedSuperellipseInputBorder scale(double t) =>
      RoundedSuperellipseInputBorder(
        borderSide: borderSide.scale(t),
        borderRadius: borderRadius * t,
        gapPadding: gapPadding * t,
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is RoundedSuperellipseInputBorder) {
      return RoundedSuperellipseInputBorder(
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        gapPadding: a.gapPadding + (gapPadding - a.gapPadding) * t,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is RoundedSuperellipseInputBorder) {
      return RoundedSuperellipseInputBorder(
        borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
        borderRadius: BorderRadius.lerp(borderRadius, b.borderRadius, t)!,
        gapPadding: gapPadding + (b.gapPadding - gapPadding) * t,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _shape.getInnerPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _shape.getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (borderSide.style == BorderStyle.none || borderSide.width <= 0) return;

    final double extent =
        gapStart == null || gapExtent <= 0 || gapPercentage <= 0
        ? 0.0
        : (gapExtent + gapPadding * 2) * gapPercentage.clamp(0.0, 1.0);
    if (extent <= 0.0) {
      _shape.paint(canvas, rect, textDirection: textDirection);
      return;
    }

    final double start = switch (textDirection ?? TextDirection.ltr) {
      TextDirection.ltr => gapStart! - gapPadding,
      TextDirection.rtl => gapStart! - gapExtent - gapPadding,
    };
    final double clampedLeft = math.max(rect.left, start);
    final double clampedRight = math.min(rect.right, start + extent);
    if (clampedRight <= clampedLeft) {
      _shape.paint(canvas, rect, textDirection: textDirection);
      return;
    }

    final double strokeAllowance = borderSide.width + 2.0;
    final Rect gapRect = Rect.fromLTRB(
      clampedLeft,
      rect.top - strokeAllowance,
      clampedRight,
      rect.top + strokeAllowance + 2.0,
    );
    final Path clipPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect.inflate(strokeAllowance)),
      Path()..addRect(gapRect),
    );
    canvas.save();
    canvas.clipPath(clipPath);
    _shape.paint(canvas, rect, textDirection: textDirection);
    canvas.restore();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoundedSuperellipseInputBorder &&
          other.borderSide == borderSide &&
          other.borderRadius == borderRadius &&
          other.gapPadding == gapPadding;

  @override
  int get hashCode => Object.hash(borderSide, borderRadius, gapPadding);
}

/// 无边框输入框（标题、正文、自带容器的搜索栏等）。
///
/// 只写 `border: InputBorder.none` 挡不住主题：主题配置的
/// enabledBorder / focusedBorder 优先于输入框自己的 border，描边、下划线
/// 风格的主题下仍会画出框；填充主题下也会带出默认底色。这里把各状态边框
/// 与默认填充一并清掉（显式传入 `filled: true` 时保留调用方选择）。
extension InputDecorationWithoutBorder on InputDecoration {
  InputDecoration withoutBorder() => copyWith(
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    filled: filled ?? false,
  );
}

/// 自带底色与圆角的输入框外壳（搜索胶囊、面板里的搜索栏等）。
///
/// 描边沿外壳轮廓绘制，下划线只在外壳底部绘制；颜色和粗细跟随输入框主题。
/// 里面的输入框不再绘制边框，主题未配置边框时外壳也不画线。
class InputFieldShell extends StatefulWidget {
  const InputFieldShell({
    super.key,
    required this.child,
    this.color,
    this.radius = 12,
    this.padding = EdgeInsets.zero,
    this.height,
    this.hasError = false,
    this.surfaceBuilder,
  });

  /// 包含输入框的内容
  final Widget child;

  /// 底色，缺省为 surfaceContainerHighest 的半透明
  final Color? color;

  /// 圆角设计值，按主题形状换算
  final double radius;

  final EdgeInsetsGeometry padding;
  final double? height;

  /// 是否显示出错状态的边框
  final bool hasError;

  final Widget Function(InputBorder? border, Widget child)? surfaceBuilder;

  static ShapeBorder borderShape(
    RoundedSuperellipseBorder outline,
    InputBorder? border,
  ) {
    if (border is UnderlineInputBorder) {
      return _UnderlineShellBorder(outline, border);
    }
    return outline.copyWith(side: border?.borderSide ?? BorderSide.none);
  }

  @override
  State<InputFieldShell> createState() => _InputFieldShellState();
}

class _InputFieldShellState extends State<InputFieldShell> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final inputTheme = InputDecorationTheme.of(context);
    final states = <WidgetState>{
      if (_focused) WidgetState.focused,
      if (_hovered) WidgetState.hovered,
      if (widget.hasError) WidgetState.error,
    };
    final border = _resolveBorder(inputTheme, states);
    // 边框由外壳绘制，里面的输入框不再套主题边框
    final child = InputDecorationTheme(
      data: inputTheme.copyWith(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        filled: false,
      ),
      child: widget.child,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: _buildSurface(context, border, child),
      ),
    );
  }

  Widget _buildSurface(
    BuildContext context,
    InputBorder? border,
    Widget child,
  ) {
    final surfaceBuilder = widget.surfaceBuilder;
    if (surfaceBuilder != null) {
      return SizedBox(
        height: widget.height,
        child: surfaceBuilder(
          border,
          Padding(padding: widget.padding, child: child),
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(widget.radius),
    );
    return Container(
      height: widget.height,
      padding: widget.padding,
      decoration: ShapeDecoration(
        color:
            widget.color ??
            colors.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: shape,
      ),
      foregroundDecoration: ShapeDecoration(
        shape: InputFieldShell.borderShape(shape, border),
      ),
      child: child,
    );
  }

  /// 按输入框主题的规则取当前状态的边框
  static InputBorder? _resolveBorder(
    InputDecorationThemeData theme,
    Set<WidgetState> states,
  ) {
    final focused = states.contains(WidgetState.focused);
    final error = states.contains(WidgetState.error);
    final InputBorder? border = switch ((error, focused)) {
      (true, true) => theme.focusedErrorBorder ?? theme.errorBorder,
      (true, false) => theme.errorBorder,
      (false, true) => theme.focusedBorder,
      (false, false) => theme.enabledBorder,
    };
    return border ??
        WidgetStateProperty.resolveAs<InputBorder?>(theme.border, states);
  }
}

class _UnderlineShellBorder extends ShapeBorder {
  const _UnderlineShellBorder(this.outline, this.underline);

  final RoundedSuperellipseBorder outline;
  final UnderlineInputBorder underline;

  @override
  EdgeInsetsGeometry get dimensions => underline.dimensions;

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      outline.getOuterPath(rect, textDirection: textDirection);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path.combine(
    PathOperation.intersect,
    getOuterPath(rect, textDirection: textDirection),
    underline.getInnerPath(rect, textDirection: textDirection),
  );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (underline.borderSide.style == BorderStyle.none) return;
    canvas.save();
    canvas.clipPath(getOuterPath(rect, textDirection: textDirection));
    underline.paint(canvas, rect, textDirection: textDirection);
    canvas.restore();
  }

  @override
  _UnderlineShellBorder scale(double factor) => _UnderlineShellBorder(
    outline.copyWith(borderRadius: outline.borderRadius * factor),
    underline.copyWith(
      borderSide: underline.borderSide.scale(factor),
      borderRadius: underline.borderRadius * factor,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is _UnderlineShellBorder &&
      other.outline == outline &&
      other.underline == underline;

  @override
  int get hashCode => Object.hash(outline, underline);
}
