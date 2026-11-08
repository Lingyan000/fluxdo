import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import 'mini_app_gallery_page.dart';
import 'mini_app_refresh_logo.dart';
import 'mini_app_sheet_controller.dart';

/// Wraps the whole home scaffold, including navigation and floating controls.
/// The community is one foreground surface; the directory is the second floor.
class HomeMiniAppsLayer extends StatefulWidget {
  const HomeMiniAppsLayer({
    super.key,
    required this.child,
    this.gallery,
    this.enabled = true,
  });
  final Widget child;
  final Widget? gallery;
  final bool enabled;
  static HomeMiniAppsLayerState of(BuildContext context) =>
      context.findAncestorStateOfType<HomeMiniAppsLayerState>()!;
  @override
  State<HomeMiniAppsLayer> createState() => HomeMiniAppsLayerState();
}

class HomeMiniAppsLayerState extends State<HomeMiniAppsLayer>
    with SingleTickerProviderStateMixin {
  late final _sheet = MiniAppSheetController(this);
  ModalRoute<dynamic>? _route;
  LocalHistoryEntry? _history;
  bool _disposing = false, _closing = false;
  RefreshRevealHandle? _refreshHandle, _resumedDrag;

  @override
  void initState() {
    super.initState();
    _sheet.addListener(_syncHistory);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(HomeMiniAppsLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _resumedDrag?.cancelResumedDrag();
      _resumedDrag = _refreshHandle = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.enabled) _sheet.reset();
      });
    }
  }

  // Match the category drawer: the layer owns a local history entry, not a
  // competing PopScope. The root's double-back exit guard never sees this pop.
  void _syncHistory() {
    if (_disposing) return;
    if (isOpen && _history == null && _route != null) {
      _history = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          _history = null;
          if (_disposing || !isOpen) return;
          if (!_closing) close();
          // Consume repeated backs until the foreground has settled home.
          _syncHistory();
        },
      );
      _route!.addLocalHistoryEntry(_history!);
    } else if (!isOpen) {
      _closing = false;
      final history = _history;
      _history = null;
      history?.remove();
    }
  }

  Widget? _gallery;
  bool? _galleryActive;
  Widget _galleryChild() {
    if (widget.gallery != null) return widget.gallery!;
    if (_galleryActive != _sheet.galleryActive) {
      _galleryActive = _sheet.galleryActive;
      _gallery = MiniAppGalleryPage(onClose: close, active: _galleryActive!);
    }
    return _gallery!;
  }

  bool get isOpen => _sheet.isOpen;
  double get offset => _sheet.offset;
  Future<void> open() => widget.enabled ? _sheet.open() : Future<void>.value();
  void close() {
    FocusScope.of(context).unfocus();
    _closing = true;
    _sheet.close();
  }

  bool _resumeRefreshDrag() {
    final handle = _refreshHandle;
    if (handle == null ||
        !handle.canResumeDrag ||
        _sheet.offset > handle.resumeExtent) {
      return false;
    }
    final offset = _sheet.offset;
    _resumedDrag = handle;
    _sheet.resumePull();
    handle.beginResumedDrag(offset);
    return true;
  }

  void _updateSurfaceDrag(double delta) {
    // 从全开的广场向上收起时只关闭。回到刷新区再向下，才转换为刷新意图。
    if (_resumedDrag == null && delta > 0) _resumeRefreshDrag();
    final handle = _resumedDrag;
    if (handle != null) {
      handle.updateResumedDrag(delta);
    } else {
      _sheet.updateCloseDrag(delta);
    }
  }

  void _endSurfaceDrag(double velocity) {
    final handle = _resumedDrag;
    _resumedDrag = null;
    if (handle != null) {
      if (handle.canResumeDrag) {
        handle.endResumedDrag(velocity);
      } else {
        // 首页切换标签或刷新组件被移除时，也必须释放前景。
        _sheet.close();
      }
    } else {
      _sheet.endCloseDrag(velocity);
    }
  }

  void _cancelSurfaceDrag() {
    final handle = _resumedDrag;
    _resumedDrag = null;
    if (handle != null) {
      if (handle.canResumeDrag) {
        handle.cancelResumedDrag();
      } else {
        _sheet.close();
      }
    } else {
      _sheet.cancelCloseDrag();
    }
  }

  Widget _surfaceGesture({
    Key? key,
    bool enabled = true,
    bool holdOnDown = true,
    required Widget child,
  }) => GestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    dragStartBehavior: DragStartBehavior.down,
    onVerticalDragDown: enabled && holdOnDown
        ? (_) => _sheet.holdMotion()
        : null,
    onVerticalDragStart: !enabled
        ? null
        : (_) {
            FocusScope.of(context).unfocus();
            _closing = false;
            _sheet.beginCloseDrag();
          },
    onVerticalDragUpdate: !enabled
        ? null
        : (d) => _updateSurfaceDrag(d.delta.dy),
    onVerticalDragEnd: !enabled
        ? null
        : (d) => _endSurfaceDrag(d.primaryVelocity ?? 0),
    onVerticalDragCancel: enabled ? _cancelSurfaceDrag : null,
    child: child,
  );

  @override
  void dispose() {
    _disposing = true;
    _history?.remove();
    _sheet.removeListener(_syncHistory);
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final feedbackExtent = 80 + MediaQuery.textScalerOf(context).scale(36);
    final returnExtent = 64 + bottomInset;
    // The gallery Scaffold already avoids the keyboard. Reserve only the part
    // of the home strip still above it, instead of adding both bottom insets.
    // Keep the foreground's resting position fixed while the IME animates.
    final galleryBottomGap =
        (returnExtent - MediaQuery.viewInsetsOf(context).bottom).clamp(
          0.0,
          returnExtent,
        );
    _sheet.reduceMotion = MediaQuery.disableAnimationsOf(context);
    _sheet.expressive = M3eFlags.of(context).enabled;
    _sheet.refreshExtent = topInset + feedbackExtent;
    return NotificationListener<RefreshRevealNotification>(
      onNotification: (event) {
        if (widget.enabled) {
          if (event.handle != null) _refreshHandle = event.handle;
          _sheet.reveal(event);
        }
        return true;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final nextExtent = (constraints.maxHeight - returnExtent)
              .clamp(1.0, double.infinity)
              .toDouble();
          if (isOpen && nextExtent != _sheet.extent) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _sheet.resize(nextExtent);
            });
          } else if (!isOpen) {
            _sheet.extent = nextExtent;
          }
          return ListenableBuilder(
            listenable: _sheet,
            child: RepaintBoundary(child: widget.child),
            builder: (context, home) {
              final y = widget.enabled ? _sheet.offset : 0.0;
              final galleryOpacity = widget.enabled
                  ? _sheet.galleryOpacity
                  : 0.0;
              final expansion = _sheet.galleryExpansion;
              final feedbackOpacity = _sheet.feedbackOpacity;
              final returnOpacity = Curves.easeOut.transform(
                ((y / _sheet.extent - .65) / .35).clamp(0, 1),
              );
              final corner =
                  28 * Curves.easeOutCubic.transform((y / 180).clamp(0, 1));
              return CallbackShortcuts(
                bindings: {
                  if (isOpen)
                    const SingleActivator(LogicalKeyboardKey.escape): close,
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: y > 0 ? theme.colorScheme.surfaceContainerLow : null,
                  ),
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_sheet.visited)
                          Positioned.fill(
                            child: IgnorePointer(
                              ignoring: !isOpen,
                              child: ExcludeSemantics(
                                excluding: !isOpen,
                                child: ExcludeFocus(
                                  excluding: !isOpen,
                                  child: _surfaceGesture(
                                    holdOnDown: false,
                                    key: const ValueKey(
                                      'mini-app-close-gesture',
                                    ),
                                    // 静止时目录列表自己滚动，页头和返回条拖动前景。
                                    child: Opacity(
                                      opacity: galleryOpacity,
                                      child: Transform.translate(
                                        key: const ValueKey(
                                          'mini-app-gallery-parallax',
                                        ),
                                        offset: Offset(
                                          0,
                                          _sheet.reduceMotion
                                              ? 0
                                              : 24 * (1 - expansion),
                                        ),
                                        child: Transform.scale(
                                          key: const ValueKey(
                                            'mini-app-gallery-scale',
                                          ),
                                          scale: _sheet.reduceMotion
                                              ? 1
                                              : .94 + .06 * expansion,
                                          alignment: Alignment.topCenter,
                                          child: DecoratedBox(
                                            key: const ValueKey(
                                              'mini-app-gallery-tint',
                                            ),
                                            decoration: BoxDecoration(
                                              color: theme
                                                  .colorScheme
                                                  .surfaceContainerLow
                                                  .withValues(
                                                    alpha:
                                                        .60 * (1 - expansion),
                                                  ),
                                            ),
                                            position:
                                                DecorationPosition.foreground,
                                            child: ColoredBox(
                                              key: const ValueKey(
                                                'mini-app-gallery-surface',
                                              ),
                                              color: theme.colorScheme.surface,
                                              child: Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: galleryBottomGap,
                                                ),
                                                child: Semantics(
                                                  container: true,
                                                  explicitChildNodes: true,
                                                  child: TickerMode(
                                                    enabled:
                                                        _sheet.galleryActive,
                                                    child: RepaintBoundary(
                                                      child: _galleryChild(),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (y > 0 && feedbackOpacity > 0)
                          Positioned(
                            top: (y - feedbackExtent).clamp(
                              topInset,
                              double.infinity,
                            ),
                            left: 0,
                            right: 0,
                            height: (y - topInset).clamp(0, feedbackExtent),
                            child: IgnorePointer(
                              child: Opacity(
                                opacity: feedbackOpacity,
                                child: _PullFeedback(
                                  sheet: _sheet,
                                  extent: feedbackExtent,
                                ),
                              ),
                            ),
                          ),
                        Transform.translate(
                          key: const ValueKey('mini-app-community-sheet'),
                          offset: Offset(0, y),
                          // 手势范围跟随可见前景，不能覆盖背后已露出的广场。
                          child: _surfaceGesture(
                            key: const ValueKey('mini-app-motion-gesture'),
                            enabled: isOpen || _resumedDrag != null,
                            child: DecoratedBox(
                              decoration: ShapeDecoration(
                                shape: RoundedSuperellipseBorder(
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(corner),
                                  ),
                                ),
                                shadows: [
                                  BoxShadow(
                                    color: theme.colorScheme.shadow.withValues(
                                      alpha: .10 * (y / 80).clamp(0, 1),
                                    ),
                                    blurRadius: 24,
                                    offset: const Offset(0, -4),
                                  ),
                                ],
                              ),
                              child: ClipRSuperellipse(
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(corner),
                                ),
                                child: Material(
                                  color: y > 0
                                      ? theme.colorScheme.surfaceContainerHigh
                                      : Colors.transparent,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Opacity(
                                        opacity: 1 - returnOpacity,
                                        child: IgnorePointer(
                                          ignoring: isOpen,
                                          child: ExcludeSemantics(
                                            excluding: isOpen,
                                            child: ExcludeFocus(
                                              excluding: isOpen,
                                              child: home!,
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (isOpen)
                                        Positioned(
                                          top: 0,
                                          left: 0,
                                          right: 0,
                                          height: returnExtent,
                                          child: Opacity(
                                            opacity: returnOpacity,
                                            child: IgnorePointer(
                                              // 返回条尚未显露时不能留下隐形点击区域。
                                              ignoring: returnOpacity < .5,
                                              child: InkWell(
                                                key: const ValueKey(
                                                  'mini-app-return-home',
                                                ),
                                                onTap: close,
                                                child: Padding(
                                                  padding: EdgeInsets.only(
                                                    bottom: bottomInset,
                                                  ),
                                                  child: Center(
                                                    child: Text(
                                                      context
                                                          .l10n
                                                          .miniApp_backToCommunity,
                                                      style: theme
                                                          .textTheme
                                                          .titleSmall
                                                          ?.copyWith(
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _PullFeedback extends StatelessWidget {
  const _PullFeedback({required this.sheet, required this.extent});
  final MiniAppSheetController sheet;
  final double extent;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final title = sheet.refreshing
        ? l.miniApp_refreshing
        : sheet.armed
        ? l.miniApp_releaseOpen
        : sheet.refreshArmed
        ? l.miniApp_releaseRefresh
        : l.miniApp_pull;
    return ClipRect(
      child: OverflowBox(
        minHeight: extent,
        maxHeight: extent,
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MiniAppRefreshLogo(
                progress: sheet.offset / sheet.refreshExtent,
                refreshing: sheet.refreshing,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                key: const ValueKey('mini-app-pull-label'),
                style: theme.textTheme.labelLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (sheet.refreshArmed && !sheet.armed && !sheet.refreshing) ...[
                const SizedBox(height: 2),
                Text(
                  l.miniApp_keepPulling,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
