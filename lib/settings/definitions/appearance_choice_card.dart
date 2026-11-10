part of 'appearance_defs.dart';

/// 带预览的外观选择项：模式、主题、圆角和应用图标共用容器与反馈。
/// 密集预览保持尺寸稳定，按压使用底色反馈，选中后再触发轻震动。
class _AppearanceChoiceCard extends StatefulWidget {
  const _AppearanceChoiceCard({
    required this.label,
    required this.preview,
    required this.selected,
    required this.onTap,
    this.onMore,
    this.labelIcon,
  });

  final String label;
  final Widget preview;
  final bool selected;
  final FutureOr<void> Function()? onTap;
  final VoidCallback? onMore;
  final IconData? labelIcon;

  @override
  State<_AppearanceChoiceCard> createState() => _AppearanceChoiceCardState();
}

class _AppearanceChoiceCardState extends State<_AppearanceChoiceCard> {
  bool _awaitingSelection = false;
  int _request = 0;

  @override
  void didUpdateWidget(_AppearanceChoiceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_awaitingSelection && !oldWidget.selected && widget.selected) {
      _awaitingSelection = false;
      HapticFeedback.selectionClick();
    }
  }

  Future<void> _select() async {
    final request = ++_request;
    _awaitingSelection = !widget.selected;
    try {
      await widget.onTap?.call();
    } finally {
      // 等本次操作的状态绘制完成；未被接受或失败的切换不留待触发。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && request == _request) _awaitingSelection = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final selected = widget.selected;
    final onTap = widget.onTap == null ? null : _select;
    final onMore = widget.onMore;
    final labelIcon = widget.labelIcon;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final radius = context.shapes.borderRadius(16);
    final foreground = selected ? cs.primary : cs.onSurfaceVariant;
    final title = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: theme.textTheme.labelMedium?.copyWith(
        color: foreground,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      child: _AppearancePressSurface(
        shape: RoundedSuperellipseBorder(borderRadius: radius),
        onTap: onTap,
        onLongPress: onMore,
        onSecondaryTap: onMore,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(8),
          decoration: ShapeDecoration(
            color: selected
                ? Color.alphaBlend(
                    cs.primary.withValues(alpha: 0.07),
                    cs.surfaceContainerLow,
                  )
                : cs.surfaceContainerLow,
            shape: RoundedSuperellipseBorder(
              borderRadius: radius,
              side: BorderSide(
                color: selected
                    ? cs.primary
                    : cs.outlineVariant.withValues(alpha: 0.45),
                width: selected ? 2 : 1,
              ),
            ),
          ),
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                widget.preview,
                const SizedBox(height: 8),
                if (labelIcon != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(labelIcon, size: 14, color: foreground),
                      const SizedBox(width: 4),
                      Flexible(child: title),
                    ],
                  )
                else
                  title,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
