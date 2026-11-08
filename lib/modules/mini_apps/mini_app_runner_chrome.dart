import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:common_ui/common_ui.dart';

import '../../l10n/s.dart';
import '../../utils/adaptive_menu.dart';
import 'mini_app.dart';
import 'mini_app_icon.dart';
import 'mini_app_identity.dart';
import 'mini_app_menu_content.dart';

export 'mini_app_floating_controls.dart';

class MiniAppRunnerToolbar extends StatelessWidget
    implements PreferredSizeWidget {
  const MiniAppRunnerToolbar({
    super.key,
    required this.app,
    required this.onBack,
    required this.onInfo,
    required this.onMenu,
    required this.onFullscreen,
    this.onRotate,
    this.landscape = false,
    this.compact = false,
    this.onMinimize,
    this.onOpenPage,
    this.primary = true,
    this.minimizeBusy = false,
    this.independentWindow = false,
    this.backgroundColor,
  });
  final MiniApp app;
  final VoidCallback onBack, onInfo, onFullscreen;
  final ValueChanged<BuildContext> onMenu;
  final VoidCallback? onRotate;
  final VoidCallback? onMinimize;
  final VoidCallback? onOpenPage;
  final bool primary;
  final bool minimizeBusy;
  final bool independentWindow;
  final bool landscape, compact;
  final Color? backgroundColor;
  @override
  Size get preferredSize => Size.fromHeight(compact ? 48 : 56);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final background = backgroundColor ?? theme.colorScheme.surface;
    final foreground = AdaptiveSurfaceColors.foreground(background);
    final group = Color.alphaBlend(
      foreground.withValues(alpha: .07),
      background,
    );
    return AppBar(
      backgroundColor: background,
      foregroundColor: foreground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: AdaptiveSurfaceColors.overlay(background, background),
      primary: primary,
      toolbarHeight: preferredSize.height,
      leadingWidth: 48,
      leading: Center(
        child: IconButton(
          onPressed: onBack,
          key: const ValueKey('mini-app-close'),
          tooltip: l.common_close,
          icon: const Icon(Symbols.close_rounded),
        ),
      ),
      titleSpacing: 0,
      title: Tooltip(
        message: l.miniApp_info,
        child: InkWell(
          onTap: onInfo,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                MiniAppIcon(app, size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Material(
            color: group,
            shape: StadiumBorder(
              side: BorderSide(color: foreground.withValues(alpha: .12)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onRotate != null && onOpenPage == null)
                  IconButton(
                    key: const ValueKey('mini-app-rotate'),
                    tooltip: landscape
                        ? l.miniApp_portrait
                        : l.miniApp_landscape,
                    onPressed: onRotate,
                    icon: const Icon(Symbols.screen_rotation_rounded, size: 22),
                  ),
                if (onOpenPage != null)
                  IconButton(
                    key: const ValueKey('mini-app-open-page'),
                    tooltip: l.miniApp_openPage,
                    onPressed: minimizeBusy ? null : onOpenPage,
                    icon: const Icon(Symbols.open_in_full_rounded, size: 22),
                  )
                else
                  IconButton(
                    key: const ValueKey('mini-app-fullscreen'),
                    tooltip: l.miniApp_fullscreen,
                    onPressed: onFullscreen,
                    icon: const Icon(Symbols.fullscreen_rounded, size: 24),
                  ),
                SizedBox(
                  height: 18,
                  child: VerticalDivider(
                    width: 1,
                    color: foreground.withValues(alpha: .16),
                  ),
                ),
                Builder(
                  builder: (buttonContext) => IconButton(
                    key: const ValueKey('mini-app-menu-button'),
                    tooltip: l.miniApp_more,
                    onPressed: () => onMenu(buttonContext),
                    icon: const Icon(Symbols.more_horiz_rounded, size: 24),
                  ),
                ),
                if (onMinimize != null)
                  IconButton(
                    key: const ValueKey('mini-app-minimize'),
                    tooltip: l.miniApp_collapsePanel,
                    onPressed: minimizeBusy ? null : onMinimize,
                    icon: const Icon(Symbols.keyboard_arrow_down_rounded),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

enum MiniAppMenuAction {
  minimize,
  separateWindow,
  info,
  share,
  favorite,
  rating,
  tip,
  report,
  embed,
  fullscreen,
  sound,
  systemOrientation,
}

Future<MiniAppMenuAction?> showMiniAppMenu(
  BuildContext context,
  MiniAppDetails details, {
  required bool loggedIn,
  required BuildContext anchorContext,
  bool fullscreen = false,
  bool soundAvailable = false,
  bool muted = true,
  bool canRotate = false,
  bool canDetach = false,
  bool canMinimize = false,
  bool blur = true,
  ValueChanged<double>? onBlurSigmaChanged,
  ValueListenable<bool>? blurReady,
  bool filterBackdrop = true,
}) {
  final l = context.l10n;
  final entries = <(MiniAppMenuAction, IconData, String)>[
    (MiniAppMenuAction.info, Symbols.info_rounded, l.miniApp_info),
    if (canMinimize)
      (
        MiniAppMenuAction.minimize,
        Symbols.keyboard_arrow_down_rounded,
        l.miniApp_collapsePanel,
      ),
    if (canDetach)
      (
        MiniAppMenuAction.separateWindow,
        Symbols.open_in_new_rounded,
        l.miniApp_separateWindow,
      ),
    (
      MiniAppMenuAction.fullscreen,
      fullscreen ? Symbols.fullscreen_exit_rounded : Symbols.fullscreen_rounded,
      fullscreen ? l.miniApp_exitFullscreen : l.miniApp_fullscreen,
    ),
    if (canRotate)
      (
        MiniAppMenuAction.systemOrientation,
        Symbols.screen_rotation_rounded,
        l.miniApp_systemOrientation,
      ),
    if (soundAvailable)
      (
        MiniAppMenuAction.sound,
        muted ? Symbols.volume_up_rounded : Symbols.volume_off_rounded,
        muted ? l.miniApp_unmute : l.miniApp_mute,
      ),
    (MiniAppMenuAction.share, Symbols.share_rounded, l.miniApp_share),
    if (loggedIn)
      (
        MiniAppMenuAction.favorite,
        Symbols.bookmark_rounded,
        details.app.favorited ? l.miniApp_unfavorite : l.miniApp_favorite,
      ),
    if (loggedIn && details.feedback['can_rate'] == true)
      (MiniAppMenuAction.rating, Symbols.star_rounded, l.miniApp_rate),
    if (loggedIn && details.feedback['can_tip'] == true)
      (MiniAppMenuAction.tip, Symbols.redeem_rounded, l.miniApp_tip),
    (MiniAppMenuAction.embed, Symbols.code_rounded, l.miniApp_shareEmbed),
    if (loggedIn && details.feedback['can_report'] == true)
      (MiniAppMenuAction.report, Symbols.flag_rounded, l.miniApp_report),
  ];
  return showAdaptiveMenu<MiniAppMenuAction>(
    context: context,
    blur: blur,
    onBlurSigmaChanged: onBlurSigmaChanged,
    blurReady: blurReady,
    filterBackdrop: filterBackdrop,
    anchorContext: anchorContext,
    title: details.app.name,
    mobileTitleWidget: MiniAppIdentity(app: details.app),
    mobileContentBuilder: (sheetContext) {
      final quick = <AdaptiveMenuItem<MiniAppMenuAction>>[];
      final community = <AdaptiveMenuItem<MiniAppMenuAction>>[];
      final utilities = <AdaptiveMenuItem<MiniAppMenuAction>>[];
      for (final (action, icon, label) in entries) {
        final item = AdaptiveMenuItem(
          value: action,
          icon: icon,
          label: label,
          destructive: action == MiniAppMenuAction.report,
          subtitle: action == MiniAppMenuAction.rating
              ? (details.app.ratingCount > 0
                    ? l.miniApp_score(
                        details.app.rating.toStringAsFixed(1),
                        details.app.ratingCount,
                      )
                    : l.miniApp_noRating)
              : action == MiniAppMenuAction.tip
              ? l.miniApp_tipEncouragement
              : null,
        );
        if ({
          MiniAppMenuAction.info,
          MiniAppMenuAction.share,
          MiniAppMenuAction.favorite,
          MiniAppMenuAction.sound,
        }.contains(action)) {
          quick.add(item);
        } else if ({
          MiniAppMenuAction.rating,
          MiniAppMenuAction.tip,
        }.contains(action)) {
          community.add(item);
        } else {
          utilities.add(item);
        }
      }
      return MiniAppMenuContent(
        quick: quick,
        community: community,
        utilities: utilities,
      );
    },
    items: [
      for (final (action, icon, label) in entries)
        AdaptiveMenuItem(value: action, icon: icon, label: label),
    ],
  );
}
