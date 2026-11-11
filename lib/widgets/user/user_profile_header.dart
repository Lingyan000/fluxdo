import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../models/user.dart';
import '../../utils/number_utils.dart';
import '../../utils/time_utils.dart';
import '../common/emoji_text.dart';
import '../common/relative_time_text.dart';
import '../content/collapsed_html_content.dart';
import 'user_profile_cover.dart';

/// 资料内容沿同一滚动轴上移，封面连续收起并成为模糊顶栏。
class UserProfileHeader extends StatelessWidget {
  const UserProfileHeader({
    super.key,
    required this.user,
    required this.avatar,
    required this.trailing,
    required this.onBackground,
  });

  final User user;
  final Widget avatar;
  final Widget trailing;
  final VoidCallback onBackground;

  _ProfileHeaderLayout _layout(
    BuildContext context,
    double width,
    double topInset,
  ) {
    final style = Theme.of(context).textTheme.titleLarge!
        .copyWith(fontWeight: FontWeight.w700);
    final painter = TextPainter(
      text: TextSpan(text: user.name ?? user.username, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout(maxWidth: width - 32);
    final titleHeight = painter.height;
    painter.dispose();
    final coverHeight = math.max(
      topInset + kToolbarHeight + 32,
      (width / 3).clamp(112.0, 224.0),
    );
    return _ProfileHeaderLayout(
      coverHeight: coverHeight,
      titleTop: coverHeight + 80,
      titleHeight: titleHeight,
      titleStyle: style,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildHeader(context, _layout(context, constraints.maxWidth, 0)),
  );

  Widget _buildHeader(
    BuildContext context,
    _ProfileHeaderLayout layout, {
    double shrinkOffset = 0,
    double topInset = 0,
    Widget Function(double titleOpacity)? toolbarBuilder,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final toolbarHeight = toolbarBuilder == null
        ? 0.0
        : topInset + kToolbarHeight;
    final height = math.max(toolbarHeight, layout.height - shrinkOffset);
    final coverHeight = math.max(
      toolbarHeight,
      layout.coverHeight - shrinkOffset,
    );
    final blurProgress = (shrinkOffset / 80).clamp(0.0, 1.0);
    final titleOpacity =
        ((toolbarHeight - layout.titleTop + shrinkOffset) / layout.titleHeight)
            .clamp(0.0, 1.0);

    return ClipRect(
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            const Positioned.fill(child: PageBackdrop()),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: coverHeight,
              child: ClipRect(
                child: IgnorePointer(
                  ignoring: shrinkOffset > 0,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: 12 * blurProgress,
                          sigmaY: 12 * blurProgress,
                        ),
                        enabled: blurProgress > 0,
                        child: UserProfileCover(
                          imageUrl: user.backgroundUrl,
                          onTap: onBackground,
                        ),
                      ),
                      IgnorePointer(
                        child: ColoredBox(
                          color: scheme.surface.withValues(
                            alpha: 0.28 * blurProgress,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              top: toolbarHeight,
              child: ClipRect(
                child: Stack(
                  children: [
                    Positioned(
                      left: 16,
                      top:
                          layout.coverHeight -
                          16 -
                          shrinkOffset -
                          toolbarHeight,
                      width: 80,
                      height: 80,
                      child: KeyedSubtree(
                        key: const ValueKey('profile-avatar'),
                        child: avatar,
                      ),
                    ),
                    Positioned(
                      right: 16,
                      top:
                          layout.coverHeight + 8 - shrinkOffset - toolbarHeight,
                      child: trailing,
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      top: layout.titleTop - shrinkOffset - toolbarHeight,
                      child: Text(
                        user.name?.trim().isNotEmpty == true
                            ? user.name!
                            : user.username,
                        key: const ValueKey('profile-display-name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: layout.titleStyle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (toolbarBuilder != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: toolbarHeight,
                child: IconButtonTheme(
                  data: IconButtonThemeData(
                    style:
                        (Theme.of(context).iconButtonTheme.style ??
                                const ButtonStyle())
                            .copyWith(
                              foregroundColor: WidgetStatePropertyAll(
                                scheme.onSurface,
                              ),
                              backgroundColor: WidgetStatePropertyAll(
                                scheme.surface.withValues(alpha: 0.72),
                              ),
                            ),
                  ),
                  child: toolbarBuilder(titleOpacity),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class UserProfileHeaderDelegate extends SliverPersistentHeaderDelegate {
  UserProfileHeaderDelegate({
    required BuildContext context,
    required double width,
    required this.header,
    required this.toolbarBuilder,
    required this.topInset,
  }) : _layout = header._layout(context, width, topInset);

  final UserProfileHeader header;
  final Widget Function(double titleOpacity) toolbarBuilder;
  final double topInset;
  final _ProfileHeaderLayout _layout;

  @override
  double get minExtent => topInset + kToolbarHeight;
  @override
  double get maxExtent => _layout.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => header._buildHeader(
    context,
    _layout,
    shrinkOffset: shrinkOffset.clamp(0.0, maxExtent - minExtent),
    topInset: topInset,
    toolbarBuilder: toolbarBuilder,
  );

  @override
  bool shouldRebuild(UserProfileHeaderDelegate oldDelegate) => true;
}

class _ProfileHeaderLayout {
  const _ProfileHeaderLayout({
    required this.coverHeight,
    required this.titleTop,
    required this.titleHeight,
    required this.titleStyle,
  });
  final double coverHeight;
  final double titleTop;
  final double titleHeight;
  final TextStyle titleStyle;
  double get height => titleTop + titleHeight + 2;
}

/// 身份、关注数据和简介按阅读顺序排列，长内容保持自然高度。
class UserProfileDetails extends StatelessWidget {
  const UserProfileDetails({
    super.key,
    required this.user,
    required this.onAbout,
    required this.onFollowing,
    required this.onFollowers,
    this.statusIcon,
    this.restriction,
  });

  final User user;
  final VoidCallback onAbout;
  final VoidCallback onFollowing;
  final VoidCallback onFollowers;
  final Widget? statusIcon;
  final Widget? restriction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final title = user.title?.trim();
    final description = user.status?.description?.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SelectableText('@${user.username}', style: muted),
          ),
          if (!user.profileHidden)
            EmojiText(
              [
                if (title != null && title.isNotEmpty) title,
                user.trustLevelString,
              ].join(' · '),
              style: muted,
            ),
          if (description != null && description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (statusIcon != null) ...[
                    statusIcon!,
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: EmojiText(description)),
                ],
              ),
            ),
          if (restriction != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: restriction!,
            ),
          if (user.bio?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: onAbout,
                borderRadius: context.shapes.borderRadius(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: CollapsedHtmlContent(
                    html: user.bio!,
                    maxLines: 3,
                    textStyle: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                if (user.location?.isNotEmpty == true)
                  _metadata(
                    context,
                    Symbols.location_on_rounded,
                    Text(user.location!, style: muted),
                  ),
                if (user.createdAt != null)
                  _metadata(
                    context,
                    Symbols.calendar_month_rounded,
                    Text(
                      '${context.l10n.userProfile_joinDate} ${TimeUtils.formatFullDate(user.createdAt)}',
                      style: muted,
                    ),
                  ),
                if (user.lastSeenAt != null)
                  _metadata(
                    context,
                    Symbols.schedule_rounded,
                    RelativeTimeText(dateTime: user.lastSeenAt!, style: muted),
                  ),
              ],
            ),
          ),
          if (user.totalFollowing != null || user.totalFollowers != null)
            Wrap(
              spacing: 20,
              children: [
                if (user.totalFollowing != null)
                  _followCount(
                    context,
                    user.totalFollowing!,
                    context.l10n.userProfile_following,
                    onFollowing,
                  ),
                if (user.totalFollowers != null)
                  _followCount(
                    context,
                    user.totalFollowers!,
                    context.l10n.userProfile_followers,
                    onFollowers,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _metadata(BuildContext context, IconData icon, Widget child) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExcludeSemantics(
        child: Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(width: 4),
      Flexible(child: child),
    ],
  );

  Widget _followCount(
    BuildContext context,
    int count,
    String label,
    VoidCallback onTap,
  ) {
    final theme = Theme.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        foregroundColor: theme.colorScheme.onSurface,
        minimumSize: const Size(48, 48),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: NumberUtils.formatCount(count),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: ' $label',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        style: theme.textTheme.bodyMedium,
      ),
    );
  }
}
