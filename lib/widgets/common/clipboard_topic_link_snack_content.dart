import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

class ClipboardTopicLinkSnackContent extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const ClipboardTopicLinkSnackContent({
    super.key,
    required this.message,
    required this.actionLabel,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderRadius = context.shapes.borderRadius(8);
    final backgroundColor = Color.alphaBlend(
      colorScheme.primary.withValues(alpha: isDark ? 0.14 : 0.06),
      colorScheme.surfaceContainerHigh,
    );

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          color: backgroundColor,
          elevation: 8,
          shadowColor: colorScheme.shadow.withValues(
            alpha: isDark ? 0.38 : 0.18,
          ),
          surfaceTintColor: colorScheme.surfaceTint,
          shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: borderRadius,
                side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(
                    alpha: isDark ? 0.32 : 0.6,
                  ),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: ShapeDecoration(
                      color: colorScheme.primaryContainer.withValues(
                        alpha: isDark ? 0.62 : 0.78,
                      ),
                      shape: RoundedSuperellipseBorder(
                        borderRadius: context.shapes.borderRadius(8),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Symbols.link_rounded,
                      size: 19,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: onOpen,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(56, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(actionLabel),
                  ),
                  IconButton(
                    onPressed: onDismiss,
                    tooltip: MaterialLocalizations.of(context)
                        .closeButtonTooltip,
                    icon: const Icon(Symbols.close_rounded),
                    iconSize: 20,
                    style: IconButton.styleFrom(
                      foregroundColor: colorScheme.onSurfaceVariant,
                      minimumSize: const Size(48, 48),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
