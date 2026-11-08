import 'dart:ui' show ImageFilter;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/browser_navigation.dart';
import '../../services/browser_tabs.dart';

class BrowserTabOverview extends StatelessWidget {
  const BrowserTabOverview({
    super.key,
    required this.visible,
    required this.tabs,
    required this.blurEnabled,
    required this.onDismiss,
    required this.onRestore,
    required this.onCloseTab,
    required this.onCloseAll,
    this.iconBuilder,
    this.subtitleBuilder,
    this.animation,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });
  final bool visible;
  final List<BrowserTabSession> tabs;
  final bool blurEnabled;
  final VoidCallback onDismiss, onCloseAll;
  final ValueChanged<BrowserTabSession> onRestore, onCloseTab;
  final Widget Function(BuildContext, BrowserTabSession, double)? iconBuilder;
  final String Function(BuildContext, BrowserTabSession)? subtitleBuilder;
  final Animation<double>? animation;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragCancelCallback? onDragCancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget frame(BuildContext context, double value, Widget? child) =>
        value == 0
        ? const SizedBox.shrink()
        : Offstage(
            offstage: value == 0,
            child: IgnorePointer(
              ignoring: !visible,
              child: ExcludeSemantics(
                excluding: !visible,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onTap: onDismiss,
                      child: blurEnabled
                          ? BackdropFilter(
                              filter: ImageFilter.blur(
                                sigmaX: 10 * value,
                                sigmaY: 10 * value,
                              ),
                              child: ColoredBox(
                                color: colors.scrim.withValues(
                                  alpha: .32 * value,
                                ),
                              ),
                            )
                          : ColoredBox(
                              color: colors.scrim.withValues(
                                alpha: .32 * value,
                              ),
                            ),
                    ),
                    SafeArea(
                      minimum: const EdgeInsets.all(16),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 960,
                            maxHeight: 800,
                          ),
                          child: Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(
                                0,
                                (animation == null
                                        ? 28
                                        : MediaQuery.sizeOf(context).height -
                                              100) *
                                    (1 - value),
                              ),
                              child: Material(
                                key: const ValueKey('browser-overview-panel'),
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(28),
                                clipBehavior: Clip.antiAlias,
                                child: Column(
                                  children: [
                                    GestureDetector(
                                      key: const ValueKey(
                                        'browser-overview-drag-area',
                                      ),
                                      behavior: HitTestBehavior.opaque,
                                      onVerticalDragStart: onDragStart,
                                      onVerticalDragUpdate: onDragUpdate,
                                      onVerticalDragEnd: onDragEnd,
                                      onVerticalDragCancel: onDragCancel,
                                      child: Stack(
                                        children: [
                                          Padding(
                                            padding: EdgeInsets.fromLTRB(
                                              20,
                                              onDragStart == null ? 8 : 16,
                                              8,
                                              0,
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    context
                                                        .l10n
                                                        .webview_minimizedPages,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium,
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip:
                                                      context.l10n.common_close,
                                                  onPressed: onDismiss,
                                                  icon: const Icon(
                                                    Symbols.close_rounded,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (onDragStart != null)
                                            Positioned(
                                              top: 6,
                                              left: 0,
                                              right: 0,
                                              child: Center(
                                                child: Container(
                                                  width: 32,
                                                  height: 4,
                                                  decoration: BoxDecoration(
                                                    color: colors
                                                        .onSurfaceVariant
                                                        .withValues(alpha: .42),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          2,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        20,
                                        0,
                                        12,
                                        8,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              context.l10n
                                                  .webview_minimizedCount(
                                                    tabs.length,
                                                  ),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: tabs.isEmpty
                                                ? null
                                                : onCloseAll,
                                            child: Text(
                                              context.l10n.webview_closeAll,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final largeText =
                                              MediaQuery.textScalerOf(context)
                                                  .scale(14) >
                                              18;
                                          final columns =
                                              constraints.maxWidth >= 840
                                              ? 3
                                              : constraints.maxWidth >= 340 &&
                                                    !largeText
                                              ? 2
                                              : 1;
                                          final width =
                                              (constraints.maxWidth -
                                                  32 -
                                                  12 * (columns - 1)) /
                                              columns;
                                          final previewHeight = (width * .82)
                                              .clamp(120.0, 210.0);
                                          final textHeight =
                                              MediaQuery.textScalerOf(context)
                                                      .scale(14) *
                                                  2.5 +
                                              28;
                                          return GridView.builder(
                                            key: const ValueKey(
                                              'browser-overview-grid',
                                            ),
                                            padding: const EdgeInsets.fromLTRB(
                                              16,
                                              0,
                                              16,
                                              16,
                                            ),
                                            gridDelegate:
                                                SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: columns,
                                                  crossAxisSpacing: 12,
                                                  mainAxisSpacing: 12,
                                                  mainAxisExtent:
                                                      previewHeight +
                                                      textHeight,
                                                ),
                                            itemCount: tabs.length,
                                            itemBuilder: (context, index) =>
                                                _card(
                                                  context,
                                                  tabs[tabs.length - 1 - index],
                                                  previewHeight,
                                                ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
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
          );
    if (animation case final progress?) {
      return AnimatedBuilder(
        animation: progress,
        builder: (context, child) => frame(context, progress.value, child),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 1 : 0),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: frame,
    );
  }

  Widget _card(
    BuildContext context,
    BrowserTabSession tab,
    double previewHeight,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final host = browserDisplayHost(tab.url);
    final title = tab.title.isNotEmpty
        ? tab.title
        : host.isNotEmpty
        ? host
        : context.l10n.webview_browser;
    Widget placeholder() => ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Symbols.language_rounded,
          size: 48,
          color: colors.onSurfaceVariant.withValues(alpha: .45),
        ),
      ),
    );
    return Dismissible(
      key: ObjectKey(tab),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onCloseTab(tab),
      child: Material(
        key: ValueKey(tab),
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onRestore(tab),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: previewHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeSemantics(
                      child: tab.preview == null
                          ? placeholder()
                          : Image.memory(
                              tab.preview!,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => placeholder(),
                            ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: IconButton.filledTonal(
                        tooltip: context.l10n.common_close,
                        style: IconButton.styleFrom(
                          backgroundColor: colors.surface.withValues(
                            alpha: .94,
                          ),
                        ),
                        onPressed: () => onCloseTab(tab),
                        icon: const Icon(Symbols.close_rounded, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      iconBuilder?.call(context, tab, 22) ??
                          Icon(
                            Symbols.language_rounded,
                            size: 22,
                            color: colors.primary,
                          ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitleBuilder?.call(context, tab) ?? host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
