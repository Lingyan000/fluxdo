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
    return IconButton(
      tooltip: tooltip,
      onPressed: count == 0 ? null : onPressed,
      visualDensity: VisualDensity.compact,
      icon: DecoratedBox(
        key: badgeKey,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
          border: Border.all(color: colorScheme.outline),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SizedBox(
          width: 24,
          height: 24,
          child: Center(
            child: Text(
              count.toString(),
              maxLines: 1,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
