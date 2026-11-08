import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../utils/platform_utils.dart';
import 'mini_app.dart';
import 'mini_app_icon.dart';
import 'mini_app_card_surface.dart';

class MiniAppGalleryHeader extends StatelessWidget {
  const MiniAppGalleryHeader({
    super.key,
    required this.onClose,
    required this.isLayer,
    this.onRefresh,
    this.refreshing = false,
  });
  final VoidCallback? onClose, onRefresh;
  final bool refreshing;
  final bool isLayer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _GalleryMark(),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        l.miniApp_title,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.8,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  l.miniApp_subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (onRefresh != null)
            IconButton.filledTonal(
              tooltip: l.common_refresh,
              onPressed: refreshing ? null : onRefresh,
              icon: refreshing
                  ? const LoadingSpinner(size: 20)
                  : const Icon(Symbols.refresh_rounded),
            ),
          if (onClose != null)
            IconButton.filledTonal(
              tooltip: l.miniApp_backToCommunity,
              onPressed: onClose,
              icon: Icon(
                isLayer
                    ? Symbols.keyboard_arrow_up_rounded
                    : Symbols.arrow_back_rounded,
              ),
            ),
        ],
      ),
    );
  }
}

/// Four small shapes repeat the geometry and colors of the application shelf.
class _GalleryMark extends StatelessWidget {
  const _GalleryMark();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 28,
        child: Wrap(
          spacing: 3,
          runSpacing: 3,
          children: [
            for (var i = 0; i < 4; i++)
              Transform.rotate(
                angle: i == 1 ? .22 : 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: [
                      colors.primary,
                      colors.tertiary,
                      colors.secondaryContainer,
                      colors.primaryContainer,
                    ][i],
                    borderRadius: BorderRadius.circular(i == 2 ? 6 : 4),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The last opened app gets a wider launch tile; the rest form a horizontal shelf.
class MiniAppRecentSection extends StatelessWidget {
  const MiniAppRecentSection({
    super.key,
    required this.apps,
    required this.onOpen,
    required this.onInfo,
    this.openingId,
  });
  final List<MiniApp> apps;
  final ValueChanged<MiniApp> onOpen, onInfo;
  final String? openingId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(
              children: [
                Text(
                  context.l10n.miniApp_recent,
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Icon(
                  Symbols.history_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          SizedBox(
            height: 92 + scale.scale(48),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: apps.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final app = apps[index];
                final featured = index == 0;
                return SizedBox(
                  width: featured
                      ? 208 * scale.scale(1).clamp(1.0, 1.35)
                      : 104 * scale.scale(1).clamp(1.0, 1.4),
                  child: SegmentedCardItem(
                    index: 0,
                    count: 1,
                    outerRadius: 28,
                    child: MiniAppCardSurface(
                      app: app,
                      prominent: featured,
                      watermark: featured,
                      child: InkWell(
                        key: ValueKey('mini-app-recent-${app.id}'),
                        onTap: openingId != null ? null : () => onOpen(app),
                        onSecondaryTap: openingId != null
                            ? null
                            : () => onInfo(app),
                        onLongPress:
                            openingId != null || PlatformUtils.isDesktop
                            ? null
                            : () => onInfo(app),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: featured
                                ? CrossAxisAlignment.start
                                : CrossAxisAlignment.center,
                            children: [
                              Row(
                                mainAxisAlignment: featured
                                    ? MainAxisAlignment.spaceBetween
                                    : MainAxisAlignment.center,
                                children: [
                                  Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      MiniAppIcon(
                                        app,
                                        size: featured ? 44 : 40,
                                      ),
                                      if (openingId == app.id)
                                        const LoadingSpinner(size: 28),
                                    ],
                                  ),
                                  if (featured)
                                    Icon(
                                      Symbols.arrow_outward_rounded,
                                      size: 24,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                ],
                              ),
                              const Spacer(),
                              if (featured) ...[
                                Text(
                                  context.l10n.miniApp_lastOpened,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: .75),
                                  ),
                                ),
                                const SizedBox(height: 3),
                              ],
                              Text(
                                app.name,
                                maxLines: featured ? 1 : 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: featured
                                    ? TextAlign.start
                                    : TextAlign.center,
                                style: featured
                                    ? theme.textTheme.titleMedium?.copyWith(
                                        color: theme.colorScheme.onSurface,
                                      )
                                    : theme.textTheme.labelMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
