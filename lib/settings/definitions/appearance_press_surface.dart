part of 'appearance_defs.dart';

/// 独立的反馈层覆盖在预览上方，避免 ink 泄漏到整个设置分组，
/// 或被图片、CustomPaint 和选中态底色遮住。
class _AppearancePressSurface extends StatelessWidget {
  const _AppearancePressSurface({
    required this.shape,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.onSecondaryTap,
  });

  final ShapeBorder shape;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: shape,
              onTap: onTap,
              onLongPress: onLongPress,
              onSecondaryTap: onSecondaryTap,
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed) ||
                    states.contains(WidgetState.focused)) {
                  return color.withValues(alpha: 0.10);
                }
                if (states.contains(WidgetState.hovered)) {
                  return color.withValues(alpha: 0.06);
                }
                return Colors.transparent;
              }),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }
}
