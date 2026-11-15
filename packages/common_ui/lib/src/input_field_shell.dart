import 'package:flutter/material.dart';

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
/// 主题给输入框配置的边框（含聚焦高亮、出错色）画在外壳的轮廓上，与
/// 底色、圆角对齐；里面的输入框不再画自己的边框，避免出现缩在内容区、
/// 与外壳错位的第二个框。主题没有配置输入框边框时外壳不画线。
class InputFieldShell extends StatefulWidget {
  const InputFieldShell({
    super.key,
    required this.child,
    this.color,
    this.radius = 12,
    this.padding = EdgeInsets.zero,
    this.height,
    this.hasError = false,
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

  @override
  State<InputFieldShell> createState() => _InputFieldShellState();
}

class _InputFieldShellState extends State<InputFieldShell> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inputTheme = InputDecorationTheme.of(context);
    final states = <WidgetState>{
      if (_focused) WidgetState.focused,
      if (_hovered) WidgetState.hovered,
      if (widget.hasError) WidgetState.error,
    };
    final side = _resolveSide(inputTheme, states);
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(widget.radius),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Container(
          height: widget.height,
          padding: widget.padding,
          decoration: ShapeDecoration(
            color:
                widget.color ??
                theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
            shape: shape,
          ),
          foregroundDecoration: side == BorderSide.none
              ? null
              : ShapeDecoration(shape: shape.copyWith(side: side)),
          // 边框由外壳绘制，里面的输入框不再套主题边框
          child: InputDecorationTheme(
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
          ),
        ),
      ),
    );
  }

  /// 按输入框主题的规则取当前状态的边框线
  static BorderSide _resolveSide(
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
    final resolved =
        border ??
        WidgetStateProperty.resolveAs<InputBorder?>(theme.border, states);
    if (resolved == null) return BorderSide.none;
    // 外壳本身就是容器：描边风格的线常驻；下划线风格平时靠底色区分，
    // 只在聚焦、出错时画出高亮框
    if (!resolved.isOutline && !focused && !error) return BorderSide.none;
    return resolved.borderSide;
  }
}
