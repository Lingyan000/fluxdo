import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../utils/platform_utils.dart';
import 'mini_app.dart';
import 'mini_app_icon.dart';
import 'mini_app_card_surface.dart';
import 'mini_app_metadata.dart';

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
                Row(
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        MiniAppIcon(app, size: 44),
                        if (opening) const LoadingSpinner(size: 24),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (app.version.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              context.l10n.miniApp_version(app.version),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
                    Expanded(child: MiniAppDeveloper(app: app)),
                    if (app.favorited)
                      Icon(
                        Symbols.bookmark_rounded,
                        size: 14,
                        fill: 1,
                        color: context.emphasis.selected,
                      ),
                    IconButton(
                      tooltip: context.l10n.miniApp_info,
                      onPressed: onInfo,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Symbols.info_rounded, size: 18),
                    ),
                  ],
                ),
                const Divider(height: 12),
                MiniAppStatistics(app: app, compact: true),
              ],
            ),
          ),
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
      child: InkWell(
        key: ValueKey('mini-app-launch-${app.id}'),
        onTap: opening ? null : onOpen,
        onSecondaryTap: opening ? null : onInfo,
        onLongPress: opening || PlatformUtils.isDesktop ? null : onInfo,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                        Text(
                          app.name,
                          style: theme.textTheme.titleSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (app.version.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            context.l10n.miniApp_version(app.version),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: secondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: secondary),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: MiniAppDeveloper(app: app)),
                  if (app.favorited)
                    Icon(
                      Symbols.bookmark_rounded,
                      size: 16,
                      color: context.emphasis.selected,
                    ),
                  IconButton(
                    tooltip: context.l10n.miniApp_info,
                    onPressed: onInfo,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Symbols.info_rounded, size: 22),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              MiniAppStatistics(app: app, compact: true),
            ],
          ),
        ),
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
