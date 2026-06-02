import 'package:flutter/material.dart';

class MobileTopicWorkspaceAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const MobileTopicWorkspaceAppBar({
    super.key,
    required this.title,
    required this.onBack,
    required this.onClose,
    this.actions = const <Widget>[],
    this.backButtonKey,
    this.closeButtonKey,
    this.backgroundColor,
    this.elevation,
    this.scrolledUnderElevation,
    this.shadowColor,
    this.surfaceTintColor,
  });

  final Widget title;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final List<Widget> actions;
  final Key? backButtonKey;
  final Key? closeButtonKey;
  final Color? backgroundColor;
  final double? elevation;
  final double? scrolledUnderElevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      leadingWidth: 0,
      backgroundColor: backgroundColor,
      elevation: elevation,
      scrolledUnderElevation: scrolledUnderElevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      title: Row(
        children: [
          IconButton(
            key: backButtonKey,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          IconButton(
            key: closeButtonKey,
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
          const SizedBox(width: 4),
          Expanded(child: title),
        ],
      ),
      actions: actions,
    );
  }
}

/// 手机端工作区"已打开 N 个"数字方框按钮。
///
/// 视觉：26×26 圆角 8 方框，弱化 outlineVariant border 配 surfaceContainerHigh
/// 背景；数字变化时通过 [AnimatedSwitcher] 做 fade + scale 过渡。
class MobileWorkspaceCountButton extends StatelessWidget {
  const MobileWorkspaceCountButton({
    super.key,
    required this.count,
    required this.tooltip,
    required this.onPressed,
    this.badgeKey,
  });

  final int count;
  final String tooltip;
  final VoidCallback? onPressed;
  final Key? badgeKey;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final disabled = count == 0;
    final textTheme = Theme.of(context).textTheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: disabled ? null : onPressed,
      visualDensity: VisualDensity.compact,
      icon: DecoratedBox(
        key: badgeKey,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.6),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SizedBox(
          width: 26,
          height: 26,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: animation, child: child),
                );
              },
              child: Text(
                count.toString(),
                key: ValueKey<int>(count),
                maxLines: 1,
                style: textTheme.labelMedium?.copyWith(
                  color: disabled
                      ? colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                      : colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
