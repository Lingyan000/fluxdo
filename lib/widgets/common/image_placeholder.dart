import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';

/// 图片区域的加载与不可用状态，小尺寸下仅保留图标。
class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({super.key, this.loading = false, this.onRetry});

  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = loading
        ? context.l10n.common_loading
        : context.l10n.common_imageUnavailable;
    final retry = loading ? null : onRetry;
    final content = Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
      child: InkWell(
        onTap: retry,
        excludeFromSemantics: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final showLabel =
                constraints.hasBoundedWidth &&
                constraints.hasBoundedHeight &&
                constraints.maxWidth >= 200 * scale &&
                constraints.maxHeight >= 144 * scale;
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Icon(
                        loading
                            ? Symbols.image_rounded
                            : Symbols.broken_image_rounded,
                        size: showLabel ? 32 : 24,
                        color: colors.outline,
                      ),
                    ),
                  ),
                  if (showLabel) ...[
                    const SizedBox(height: 12),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (retry != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Symbols.refresh_rounded,
                            size: 14,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            context.l10n.common_retry,
                            style: theme.textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
    return Semantics(
      label: label,
      hint: retry == null ? null : context.l10n.common_retry,
      button: retry != null,
      onTap: retry,
      excludeSemantics: true,
      child: Tooltip(
        message: retry == null ? label : context.l10n.common_retry,
        excludeFromSemantics: true,
        child: content,
      ),
    );
  }
}
