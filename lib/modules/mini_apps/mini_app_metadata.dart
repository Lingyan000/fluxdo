import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../pages/user_profile_page.dart';
import '../../utils/avatar_url.dart';
import '../../utils/url_helper.dart';
import '../../widgets/common/smart_avatar.dart';
import 'mini_app.dart';
import 'mini_app_window_session.dart';

/// 广场、帖子卡片与详情共用开发者身份，独立窗口的跳转交回社区窗口。
class MiniAppDeveloper extends StatelessWidget {
  const MiniAppDeveloper({super.key, required this.app, this.showRole = false});

  final MiniApp app;
  final bool showRole;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = app.author.isEmpty ? app.authorUsername : app.author;
    if (name.isEmpty) return const SizedBox.shrink();
    final size = showRole ? 40.0 : 24.0;
    return InkWell(
      onTap: app.authorUsername.isEmpty
          ? null
          : () => MiniAppWindowSession.current != null
                ? MiniAppWindowSession.current!.community(
                    '/u/${Uri.encodeComponent(app.authorUsername)}',
                  )
                : Navigator.of(context).push(
                    InteractionPageRoute(
                      builder: (_) =>
                          UserProfilePage(username: app.authorUsername),
                    ),
                  ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SmartAvatar(
              imageUrl: UrlHelper.resolveUrlWithCdn(
                AvatarUrl.resolve(
                  app.authorAvatarTemplate,
                  size: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
                ),
              ),
              radius: size / 2,
              fallbackText: name,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: showRole
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.labelMedium,
                  ),
                  if (showRole)
                    Text(
                      context.l10n.miniApp_developer,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (showRole && app.authorUsername.isNotEmpty)
              const Icon(Symbols.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

/// 统计直接使用目录返回的数据，缺失的近期统计保留为未知。
class MiniAppStatistics extends StatelessWidget {
  const MiniAppStatistics({super.key, required this.app, this.compact = false});

  final MiniApp app;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final style = compact
        ? theme.textTheme.labelSmall
        : theme.textTheme.bodyMedium;
    return DefaultTextStyle(
      style: style!.copyWith(color: theme.colorScheme.onSurfaceVariant),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Symbols.star_rounded,
                size: compact ? 14 : 18,
                fill: 1,
                color: context.emphasis.selected,
              ),
              const SizedBox(width: 4),
              Expanded(child: Text(miniAppRating(context, app))),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(l.miniApp_usage(app.usageCount)),
              if (app.recentUsageCount case final int count)
                Text(l.miniApp_recentUsage(count)),
              if (app.canTip)
                Text(
                  l.miniApp_tipAvailable,
                  style: style.copyWith(color: theme.colorScheme.primary),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String miniAppRating(BuildContext context, MiniApp app) => app.ratingCount == 0
    ? context.l10n.miniApp_noRating
    : context.l10n.miniApp_score(
        app.rating.toStringAsFixed(1),
        app.ratingCount,
      );
