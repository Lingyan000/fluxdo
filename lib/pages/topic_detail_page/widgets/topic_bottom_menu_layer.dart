import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/topic/topic_notification_button.dart';
import 'topic_bottom_bar.dart';
import 'topic_filter_controls.dart';

/// 话题底栏宫格菜单会话状态。
///
/// 与快捷回复会话同源：[activeNotifier] 反映展开意图（用于锁住底栏、淡出
/// 悬浮按钮与拦截返回键），[presentedNotifier] 覆盖完整展开/收起动画周期
/// （用于隐藏底层按钮，避免半透明玻璃下露出重影）。
class TopicBottomMenuSession {
  final ValueNotifier<bool> activeNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> presentedNotifier = ValueNotifier<bool>(false);

  bool _disposed = false;

  bool get active => activeNotifier.value;
  bool get presented => presentedNotifier.value;

  void open() {
    if (_disposed || activeNotifier.value) return;
    activeNotifier.value = true;
  }

  void close() {
    if (_disposed || !activeNotifier.value) return;
    activeNotifier.value = false;
  }

  void toggle() => active ? close() : open();

  void setPresented(bool value) {
    if (_disposed || presentedNotifier.value == value) return;
    presentedNotifier.value = value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    activeNotifier.dispose();
    presentedNotifier.dispose();
  }
}

/// 底栏原地展开宫格面板的数据与操作集合。
@immutable
class TopicBottomMenuData {
  const TopicBottomMenuData({
    required this.filter,
    required this.showBookmark,
    required this.bookmarked,
    required this.isInReadLater,
    required this.isPrivateMessage,
    required this.isLoggedIn,
    required this.notificationLevel,
    required this.onBookmark,
    required this.onToggleReadLater,
    required this.onOpenFind,
    required this.onShareTopic,
    this.onShowMembers,
    required this.onOpenNotification,
    required this.onOpenInBrowser,
    required this.onOpenReadingSettings,
  });

  final TopicFilterControls filter;
  final bool showBookmark;
  final bool bookmarked;
  final bool isInReadLater;
  final bool isPrivateMessage;
  final bool isLoggedIn;
  final TopicNotificationLevel notificationLevel;
  final VoidCallback onBookmark;
  final VoidCallback onToggleReadLater;
  final VoidCallback onOpenFind;
  final VoidCallback onShareTopic;
  final VoidCallback? onShowMembers;
  final VoidCallback onOpenNotification;
  final VoidCallback onOpenInBrowser;
  final VoidCallback onOpenReadingSettings;
}

typedef _MenuSourceGeometry = ({
  double left,
  double width,
  double height,
  double bottomGap,
});

/// 话题底栏原地展开的宫格操作层。
///
/// 挂在话题页 Scaffold 外层的最上层 Stack 中：遮罩盖住整页，面板从底栏右侧
/// 操作组原地向上展开为双排宫格（上排阅读与筛选开关，下排常用操作），底行
/// 右侧保持书签原位不动，触发图标旋转变为关闭按钮。开关类瓷砖点击后保持面板
/// 打开以便连续操作，动作类瓷砖点击后自动收起并执行对应操作。
class TopicBottomMenuLayer extends StatefulWidget {
  const TopicBottomMenuLayer({
    super.key,
    required this.session,
    required this.sourceKey,
    required this.data,
  });

  final TopicBottomMenuSession session;

  /// 底栏右侧操作组的 key：面板从它的位置与尺寸原地展开
  final GlobalKey sourceKey;
  final TopicBottomMenuData data;

  @override
  State<TopicBottomMenuLayer> createState() => _TopicBottomMenuLayerState();
}

class _TopicBottomMenuLayerState extends State<TopicBottomMenuLayer>
    with SingleTickerProviderStateMixin {
  static const double _panelRadius = TopicBottomBarMetrics.floatingRadius;
  static const double _tileRadius = 14;
  static const double _tileHeight = 68;
  static const double _gridGap = 8;
  static const Curve _geometryCurve = Curves.easeInOutCubicEmphasized;
  static const Curve _contentCurve = Interval(0.25, 1.0, curve: Curves.easeOut);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 220),
  )..addStatusListener(_onStatus);

  _MenuSourceGeometry? _source;

  @override
  void initState() {
    super.initState();
    widget.session.activeNotifier.addListener(_onActiveChanged);
    if (widget.session.active) {
      widget.session.setPresented(true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.session.active) return;
        _captureSource();
        _animateOpen();
      });
    }
  }

  @override
  void didUpdateWidget(covariant TopicBottomMenuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.activeNotifier.removeListener(_onActiveChanged);
      widget.session.activeNotifier.addListener(_onActiveChanged);
      _onActiveChanged();
    }
  }

  @override
  void dispose() {
    widget.session.activeNotifier.removeListener(_onActiveChanged);
    _controller.dispose();
    super.dispose();
  }

  bool get _reduceMotion =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.reduceMotionOf(context);

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      widget.session.setPresented(false);
    }
  }

  void _onActiveChanged() {
    if (!mounted) return;
    if (widget.session.active) {
      _captureSource();
      widget.session.setPresented(true);
      _animateOpen();
    } else {
      _animateClose();
    }
  }

  void _animateOpen() {
    if (_reduceMotion) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  void _animateClose() {
    if (_reduceMotion) {
      _controller.value = 0;
      widget.session.setPresented(false);
    } else {
      _controller.reverse();
    }
  }

  void _captureSource() {
    final layer = context.findRenderObject() as RenderBox?;
    final anchor =
        widget.sourceKey.currentContext?.findRenderObject() as RenderBox?;
    if (layer == null || !layer.hasSize || anchor == null || !anchor.attached) {
      return;
    }
    final topLeft = layer.globalToLocal(anchor.localToGlobal(Offset.zero));
    _source = (
      left: topLeft.dx,
      width: anchor.size.width,
      height: anchor.size.height,
      bottomGap: layer.size.height - topLeft.dy - anchor.size.height,
    );
  }

  void _runAction(VoidCallback action) {
    widget.session.close();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final floating = TopicBottomBarMetrics.isFloating(context);

    final layer = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final raw = _controller.value;
        if (raw == 0 && !widget.session.active) {
          return const SizedBox.shrink();
        }
        final t = _geometryCurve.transform(raw);
        final contentOpacity = _contentCurve.transform(raw);
        final scrim = 0.32 * raw;

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.session.close,
                child: ColoredBox(
                  key: const ValueKey('bottom_menu_scrim'),
                  color: Colors.black.withValues(alpha: scrim),
                ),
              ),
            ),
            _buildMorphingPanel(
              context: context,
              theme: theme,
              t: t,
              contentOpacity: contentOpacity,
              floating: floating,
            ),
          ],
        );
      },
    );

    return ValueListenableBuilder<bool>(
      valueListenable: widget.session.activeNotifier,
      child: layer,
      builder: (context, active, child) => PopScope(
        canPop: !active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) widget.session.close();
        },
        child: child!,
      ),
    );
  }

  Widget _buildMorphingPanel({
    required BuildContext context,
    required ThemeData theme,
    required double t,
    required double contentOpacity,
    required bool floating,
  }) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final panelBottom = floating
        ? safeBottom + TopicBottomBarMetrics.floatingMargin
        : 0.0;
    final panelRadius = context.shapes.resolve(_panelRadius);
    final panelShape = RoundedSuperellipseBorder(
      borderRadius: floating
          ? context.shapes.borderRadius(_panelRadius)
          : BorderRadius.vertical(top: context.shapes.radius(_panelRadius)),
    );
    final settled = t >= 0.99;

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layerWidth = constraints.maxWidth;
          final panelWidth = floating
              ? (layerWidth - TopicBottomBarMetrics.floatingMargin * 2).clamp(
                  0.0,
                  Breakpoints.maxContentWidth,
                )
              : layerWidth;
          final panelLeft = (layerWidth - panelWidth) / 2;

          return Stack(
            children: [
              Positioned(
                left: panelLeft,
                width: panelWidth,
                bottom: panelBottom,
                child: ClipPath(
                  clipper: _BottomMenuMorphClipper(
                    source: _source,
                    panelLeft: panelLeft,
                    panelBottom: panelBottom,
                    t: t,
                    topRadius: panelRadius,
                    bottomRadius: floating ? panelRadius : 0,
                  ),
                  child: GlassSurface(
                    recipe: GlassRecipe.menu,
                    shape: panelShape,
                    drawOpticalBorder: settled,
                    drawFallbackBorder: settled,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Opacity(
                            opacity: contentOpacity,
                            child: Transform.scale(
                              scale: 0.96 + 0.04 * contentOpacity,
                              alignment: Alignment.bottomRight,
                              child: _buildTileGrid(context, theme),
                            ),
                          ),
                          _buildFooterRow(
                            context: context,
                            theme: theme,
                            t: t,
                            contentOpacity: contentOpacity,
                            floating: floating,
                            safeBottom: safeBottom,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTileGrid(BuildContext context, ThemeData theme) {
    final l10n = context.l10n;
    final data = widget.data;
    final filter = data.filter;
    final filterEnabled = !filter.isLoading;

    final filterTiles = <_MenuTileSpec>[
      if (filter.isOtherUserFilter &&
          filter.usernameFilter != null &&
          filter.usernameFilter!.isNotEmpty)
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_author'),
          icon: Symbols.person_search_rounded,
          label: l10n.topicDetail_userOnly(filter.usernameFilter!),
          checked: true,
          isToggle: true,
          enabled: filterEnabled,
          onTap: filter.onCancelFilter,
        )
      else
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_author'),
          icon: Symbols.person_rounded,
          label: l10n.topicDetail_authorOnly,
          checked: filter.isAuthorOnlyMode,
          isToggle: true,
          enabled: filterEnabled,
          onTap: filter.isAuthorOnlyMode
              ? filter.onCancelFilter
              : filter.onShowAuthorOnly,
        ),
      _MenuTileSpec(
        key: const ValueKey('bottom_menu_tile_top_level'),
        icon: Symbols.account_tree_rounded,
        label: l10n.topicDetail_topLevelOnly,
        checked: filter.isTopLevelMode,
        isToggle: true,
        enabled: filterEnabled,
        onTap: filter.isTopLevelMode
            ? filter.onCancelFilter
            : filter.onShowTopLevelReplies,
      ),
      _MenuTileSpec(
        key: const ValueKey('bottom_menu_tile_nested'),
        icon: Symbols.forum_rounded,
        label: l10n.nested_title,
        checked: filter.isNestedMode,
        isToggle: true,
        enabled: filterEnabled,
        onTap: filter.onShowNestedView,
      ),
      if (filter.isPostVoting)
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_activity'),
          icon: Symbols.history_rounded,
          label: l10n.topicDetail_sortByActivity,
          checked: filter.isActivityMode,
          isToggle: true,
          enabled: filterEnabled,
          onTap: filter.isActivityMode
              ? filter.onCancelFilter
              : filter.onShowByActivity,
        ),
      if (filter.hasSummary)
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_hot'),
          icon: Symbols.local_fire_department_rounded,
          label: l10n.topicDetail_hotOnly,
          checked: filter.isSummaryMode,
          isToggle: true,
          enabled: filterEnabled,
          onTap: filter.isSummaryMode
              ? filter.onCancelFilter
              : filter.onShowTopReplies,
        ),
    ];

    final subscribed =
        data.notificationLevel.value >= TopicNotificationLevel.tracking.value;
    final actionTiles = <_MenuTileSpec>[
      _MenuTileSpec(
        key: const ValueKey('bottom_menu_tile_read_later'),
        icon: Symbols.layers_rounded,
        label: data.isInReadLater
            ? l10n.topicDetail_removeFromReadLater
            : l10n.topicDetail_addToReadLater,
        checked: data.isInReadLater,
        isToggle: true,
        onTap: data.onToggleReadLater,
      ),
      _MenuTileSpec(
        key: const ValueKey('bottom_menu_tile_find'),
        icon: Symbols.search_rounded,
        label: l10n.topicDetail_searchTopic,
        onTap: () => _runAction(data.onOpenFind),
      ),
      if (data.isPrivateMessage && data.onShowMembers != null)
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_members'),
          icon: Symbols.group_rounded,
          label: l10n.pm_conversationMembers,
          onTap: () => _runAction(data.onShowMembers!),
        )
      else if (!data.isPrivateMessage)
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_share'),
          icon: Symbols.link_rounded,
          label: l10n.topicDetail_shareLink,
          onTap: () => _runAction(data.onShareTopic),
        ),
      if (data.isLoggedIn)
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_notification'),
          icon: TopicNotificationButton.getIcon(data.notificationLevel),
          label: l10n.topic_notificationSettings,
          detail: data.notificationLevel.label,
          checked: subscribed,
          onTap: () => _runAction(data.onOpenNotification),
        )
      else
        _MenuTileSpec(
          key: const ValueKey('bottom_menu_tile_browser'),
          icon: Symbols.language_rounded,
          label: l10n.topicDetail_openInBrowser,
          onTap: () => _runAction(data.onOpenInBrowser),
        ),
    ];

    final rows = <List<_MenuTileSpec>>[
      for (var i = 0; i < filterTiles.length; i += 4)
        filterTiles.sublist(i, math.min(i + 4, filterTiles.length)),
      actionTiles,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: _gridGap),
            _buildTileRow(context, theme, rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildTileRow(
    BuildContext context,
    ThemeData theme,
    List<_MenuTileSpec> tiles,
  ) {
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: _gridGap),
          Expanded(
            child: _BottomMenuTile(
              key: tiles[i].key,
              spec: tiles[i],
              radius: _tileRadius,
              height: _tileHeight,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFooterRow({
    required BuildContext context,
    required ThemeData theme,
    required double t,
    required double contentOpacity,
    required bool floating,
    required double safeBottom,
  }) {
    final l10n = context.l10n;
    final data = widget.data;
    final filter = data.filter;
    final (restIcon, _) = filter.active(context);

    return Padding(
      padding: EdgeInsets.only(bottom: floating ? 0 : safeBottom),
      child: SizedBox(
        height: TopicBottomBarMetrics.contentHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Opacity(
                  opacity: contentOpacity,
                  child: Row(
                    children: [
                      Flexible(
                        child: _FooterActionButton(
                          key: const ValueKey('bottom_menu_footer_reading'),
                          icon: Symbols.auto_stories_rounded,
                          label: l10n.settings_reading,
                          onTap: () => _runAction(data.onOpenReadingSettings),
                        ),
                      ),
                      if (filter.hasActiveFilter) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          child: _FooterActionButton(
                            key: const ValueKey(
                              'bottom_menu_footer_cancel_filter',
                            ),
                            icon: Symbols.filter_list_off_rounded,
                            label: l10n.common_cancel,
                            enabled: !filter.isLoading,
                            onTap: filter.onCancelFilter,
                          ),
                        ),
                      ] else if (data.isLoggedIn) ...[
                        const SizedBox(width: 2),
                        IconButton(
                          key: const ValueKey('bottom_menu_footer_browser'),
                          onPressed: () => _runAction(data.onOpenInBrowser),
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.topicDetail_openInBrowser,
                          icon: const Icon(Symbols.language_rounded, size: 20),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (data.showBookmark)
                IconButton(
                  key: const ValueKey('bottom_menu_footer_bookmark'),
                  onPressed: () {
                    if (data.bookmarked) {
                      _runAction(data.onBookmark);
                    } else {
                      data.onBookmark();
                    }
                  },
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Symbols.bookmark_rounded,
                    fill: data.bookmarked ? 1 : 0,
                    color: data.bookmarked ? context.emphasis.selected : null,
                  ),
                  tooltip: data.bookmarked
                      ? l10n.topicDetail_editBookmark
                      : l10n.common_addBookmark,
                ),
              IconButton(
                key: const ValueKey('bottom_menu_footer_close'),
                onPressed: widget.session.close,
                visualDensity: VisualDensity.compact,
                tooltip: l10n.common_close,
                icon: _RotatingCloseIcon(
                  progress: t,
                  restIcon: restIcon,
                  restColor: filter.hasActiveFilter
                      ? context.emphasis.accent
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

@immutable
class _MenuTileSpec {
  const _MenuTileSpec({
    this.key,
    required this.icon,
    required this.label,
    this.detail,
    this.checked = false,
    this.isToggle = false,
    this.enabled = true,
    this.onTap,
  });

  final Key? key;
  final IconData icon;
  final String label;
  final String? detail;
  final bool checked;
  final bool isToggle;
  final bool enabled;
  final VoidCallback? onTap;
}

class _BottomMenuTile extends StatelessWidget {
  const _BottomMenuTile({
    super.key,
    required this.spec,
    required this.radius,
    required this.height,
  });

  final _MenuTileSpec spec;
  final double radius;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final enabled = spec.enabled && spec.onTap != null;
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(radius),
    );
    final background = spec.checked
        ? context.emphasis.selected.withValues(alpha: isDark ? 0.20 : 0.14)
        : theme.colorScheme.onSurface.withValues(alpha: isDark ? 0.07 : 0.05);
    final foreground = spec.checked
        ? context.emphasis.selected
        : theme.colorScheme.onSurface;

    return Semantics(
      button: true,
      enabled: enabled,
      toggled: spec.isToggle ? spec.checked : null,
      label: spec.detail != null ? '${spec.label} ${spec.detail}' : spec.label,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: M3eElasticPress(
          enabled: enabled,
          selectionFeedback: spec.isToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            height: height,
            decoration: ShapeDecoration(color: background, shape: shape),
            child: InkWell(
              customBorder: shape,
              onTap: enabled ? spec.onTap : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      spec.icon,
                      size: 22,
                      fill: spec.checked ? 1 : 0,
                      color: foreground,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      spec.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: foreground,
                        fontWeight: spec.checked
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    if (spec.detail != null)
                      Text(
                        spec.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: foreground.withValues(alpha: 0.72),
                          height: 1.15,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterActionButton extends StatelessWidget {
  const _FooterActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(12),
    );
    final color = theme.colorScheme.onSurfaceVariant;
    final active = enabled && onTap != null;

    return Opacity(
      opacity: active ? 1.0 : 0.45,
      child: InkWell(
        customBorder: shape,
        onTap: active ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RotatingCloseIcon extends StatelessWidget {
  const _RotatingCloseIcon({
    required this.progress,
    required this.restIcon,
    this.restColor,
  });

  final double progress;
  final IconData restIcon;
  final Color? restColor;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: 1 - p,
          child: Transform.rotate(
            angle: (math.pi / 2) * p,
            child: Icon(restIcon, color: restColor),
          ),
        ),
        Opacity(
          opacity: p,
          child: Transform.rotate(
            angle: -(math.pi / 2) * (1 - p),
            child: const Icon(Symbols.close_rounded),
          ),
        ),
      ],
    );
  }
}

/// 面板外形：从底栏右侧操作组（[source]）原地向上向左连续变形为完整面板。
class _BottomMenuMorphClipper extends CustomClipper<Path> {
  const _BottomMenuMorphClipper({
    required this.source,
    required this.panelLeft,
    required this.panelBottom,
    required this.t,
    required this.topRadius,
    required this.bottomRadius,
  });

  final _MenuSourceGeometry? source;
  final double panelLeft;
  final double panelBottom;
  final double t;
  final double topRadius;
  final double bottomRadius;

  @override
  Path getClip(Size size) {
    final full = Offset.zero & size;
    final s = source;
    final Rect from;
    if (s == null) {
      final fallbackWidth = math.min(88.0, size.width);
      final fallbackHeight = math.min(
        TopicBottomBarMetrics.contentHeight,
        size.height,
      );
      from = Rect.fromLTWH(
        size.width - fallbackWidth,
        size.height - fallbackHeight,
        fallbackWidth,
        fallbackHeight,
      );
    } else {
      from = Rect.fromLTWH(
        s.left - panelLeft,
        size.height - (s.bottomGap - panelBottom) - s.height,
        s.width,
        s.height,
      );
    }
    final rect = Rect.lerp(from, full, t)!;
    final fromRadius = s == null ? from.height / 2 : s.height / 2;
    final top = Radius.circular(fromRadius + (topRadius - fromRadius) * t);
    final bottom = Radius.circular(
      fromRadius + (bottomRadius - fromRadius) * t,
    );
    return Path()..addRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: top,
        topRight: top,
        bottomLeft: bottom,
        bottomRight: bottom,
      ),
    );
  }

  @override
  bool shouldReclip(_BottomMenuMorphClipper old) =>
      old.source != source ||
      old.panelLeft != panelLeft ||
      old.panelBottom != panelBottom ||
      old.t != t ||
      old.topRadius != topRadius ||
      old.bottomRadius != bottomRadius;
}
