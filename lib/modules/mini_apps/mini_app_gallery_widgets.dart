import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../utils/platform_utils.dart';
import 'mini_app.dart';
import 'mini_app_icon.dart';
import 'mini_app_card_surface.dart';

/// 点击启动应用；手机长按、桌面右键或独立信息按钮打开原生详情。
class MiniAppDiscoveryCard extends StatelessWidget {
  const MiniAppDiscoveryCard({
    super.key,
    required this.app,
    required this.onOpen,
    required this.onInfo,
    this.opening = false,
  });
  final MiniApp app;
  final VoidCallback onOpen, onInfo;
  final bool opening;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final description = app.description.trim().replaceAll(RegExp(r'\s+'), ' ');
    return SegmentedCardItem(
      index: 0,
      count: 1,
      outerRadius: 26,
      child: MiniAppCardSurface(
        app: app,
        child: Stack(
          children: [
            Positioned.fill(
              child: InkWell(
                key: ValueKey('mini-app-launch-${app.id}'),
                onTap: opening ? null : onOpen,
                onSecondaryTap: opening ? null : onInfo,
                onLongPress: opening || PlatformUtils.isDesktop ? null : onInfo,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 62,
                        child: Align(
                          alignment: AlignmentDirectional.topStart,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              MiniAppIcon(app, size: 56),
                              if (opening) const LoadingSpinner(size: 28),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        app.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (app.ratingCount > 0) ...[
                            Icon(
                              Symbols.star_rounded,
                              size: 14,
                              fill: 1,
                              color: context.emphasis.selected,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              app.rating.toStringAsFixed(1),
                              style: theme.textTheme.labelSmall,
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              app.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (app.favorited) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Symbols.bookmark_rounded,
                              size: 14,
                              fill: 1,
                              color: context.emphasis.selected,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.directional(
              top: 4,
              end: 4,
              textDirection: Directionality.of(context),
              child: IconButton(
                tooltip: context.l10n.miniApp_info,
                onPressed: onInfo,
                icon: Icon(
                  Symbols.info_rounded,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MiniAppDiscoveryRow extends StatelessWidget {
  const MiniAppDiscoveryRow({
    super.key,
    required this.app,
    required this.onOpen,
    required this.onInfo,
    this.opening = false,
  });
  final MiniApp app;
  final VoidCallback onOpen, onInfo;
  final bool opening;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    final description = app.description.trim().replaceAll(RegExp(r'\s+'), ' ');
    return MiniAppCardSurface(
      app: app,
      watermark: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('mini-app-launch-${app.id}'),
              onTap: opening ? null : onOpen,
              onSecondaryTap: opening ? null : onInfo,
              onLongPress: opening || PlatformUtils.isDesktop ? null : onInfo,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 0, 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        MiniAppIcon(app, size: 52),
                        if (opening) const LoadingSpinner(size: 28),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  app.name,
                                  style: theme.textTheme.titleSmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (app.favorited)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Icon(
                                    Symbols.bookmark_rounded,
                                    size: 16,
                                    color: context.emphasis.selected,
                                  ),
                                ),
                            ],
                          ),
                          if (description.isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: secondary,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            [
                              if (app.ratingCount > 0)
                                '${app.rating.toStringAsFixed(1)} ★',
                              if (app.author.isNotEmpty) app.author,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: context.l10n.miniApp_info,
            onPressed: onInfo,
            icon: const Icon(Symbols.info_rounded, size: 22),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class MiniAppDirectoryEmpty extends StatelessWidget {
  const MiniAppDirectoryEmpty({
    super.key,
    required this.favorites,
    required this.onDiscover,
  });
  final bool favorites;
  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              favorites ? Symbols.bookmark_rounded : Symbols.search_off_rounded,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              favorites ? l.miniApp_noFavorites : l.miniApp_empty,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              favorites ? l.miniApp_favoritesHint : l.miniApp_emptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onDiscover, child: Text(l.miniApp_discover)),
          ],
        ),
      ),
    );
  }
}
