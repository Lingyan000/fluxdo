import 'package:material_ui/material_ui.dart';

import 'ui_shapes.dart';

/// 无边框输入框（标题、正文、自带容器的搜索栏等）。
///
/// 只写 `border: InputBorder.none` 挡不住主题：主题配置的
/// enabledBorder / focusedBorder 优先于输入框自己的 border，描边、下划线
/// 风格的主题下仍会画出框。这里把各状态的边框一并清掉。
extension InputDecorationWithoutBorder on InputDecoration {
  InputDecoration withoutBorder() => copyWith(
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
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
