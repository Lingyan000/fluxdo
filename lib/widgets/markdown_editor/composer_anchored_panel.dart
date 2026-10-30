import 'dart:math' as math;
import 'dart:ui' show lerpDouble, SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composer_object_surface.dart';

/// The panel is measured before painting. Both its position and its reveal use
/// that same measured rectangle, including when it flips above the trigger.
Future<T?> showComposerAnchoredPanel<T>({
  required BuildContext context,
  required Rect globalAnchor,
  required WidgetBuilder builder,
  double width = 280,
  double maxHeight = 520,
  bool fitBesideAnchor = false,
  Rect? globalViewport,
  bool atPointer = false,
  bool requestFocus = true,
}) async {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay?.context.findRenderObject();
  if (overlay is! RenderBox) return null;
  Rect local(Rect rect) => Rect.fromPoints(
    overlay.globalToLocal(rect.topLeft),
    overlay.globalToLocal(rect.bottomRight),
  );
  final route = _ComposerPanelRoute<T>(
    anchor: local(globalAnchor),
    viewport: globalViewport == null ? null : local(globalViewport),
    width: width,
    maxHeight: maxHeight,
    fitBesideAnchor: fitBesideAnchor,
    atPointer: atPointer,
    requestFocus: requestFocus,
    builder: builder,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    reduceMotion: MediaQuery.disableAnimationsOf(context),
    barrierLabel: MaterialLocalizations.of(context).menuDismissLabel,
  );
  final value = await navigator.push<T>(route);
  // Keep the originating control pressed until the panel has folded back.
  await route.completed;
  return value;
}

class _ComposerPanelRoute<T> extends PopupRoute<T> {
  _ComposerPanelRoute({
    required this.anchor,
    required this.viewport,
    required this.width,
    required this.maxHeight,
    required this.fitBesideAnchor,
    required this.atPointer,
    required this.builder,
    required this.themes,
    required this.reduceMotion,
    required this.barrierLabel,
    required bool requestFocus,
  }) : super(requestFocus: requestFocus);

  final Rect anchor;
  final Rect? viewport;
  final double width;
  final double maxHeight;
  final bool fitBesideAnchor;
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  final bool atPointer;
  final WidgetBuilder builder;
  final CapturedThemes themes;
  final bool reduceMotion;
  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Color? get barrierColor => null;
  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 220);
  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        child: FocusTraversalGroup(
          child: ComposerAnchoredSurface(
            anchor: anchor,
            viewport: viewport,
            width: width,
            maxHeight: maxHeight,
            fitBesideAnchor: fitBesideAnchor,
            atPointer: atPointer,
            animation: animation,
            reduceMotion: reduceMotion,
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                key: const ValueKey('composer-anchored-panel'),
                padding: const EdgeInsets.all(6),
                child: Builder(builder: builder),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Shared measured surface for route menus and nonmodal editing suggestions.
/// Coordinates belong to the containing overlay; the content owns its scrolling.
class ComposerAnchoredSurface extends StatelessWidget {
  const ComposerAnchoredSurface({
    super.key,
    required this.anchor,
    required this.animation,
    required this.child,
    this.viewport,
    this.width = 320,
    this.maxHeight = 440,
    this.fitBesideAnchor = true,
    this.atPointer = false,
    this.reduceMotion = false,
  });
  final Rect anchor;
  final Rect? viewport;
  final Animation<double> animation;
  final Widget child;
  final double width;
  final double maxHeight;
  final bool fitBesideAnchor;
  final bool atPointer;
  final bool reduceMotion;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final size = constraints.biggest;
      final safe = Rect.fromLTRB(
        media.viewPadding.left + 8,
        math.max(media.viewPadding.top, viewport?.top ?? 0) + 8,
        size.width - media.viewPadding.right - 8,
        math.min(
              viewport?.bottom ?? size.height,
              size.height -
                  math.max(media.viewInsets.bottom, media.viewPadding.bottom),
            ) -
            8,
      );
      if (safe.isEmpty) return const SizedBox.shrink();
      return Flow(
        delegate: _PanelReveal(
          animation: animation,
          anchor: anchor,
          viewport: safe,
          width: math.min(width, safe.width),
          maxHeight: math.min(
            maxHeight,
            fitBesideAnchor
                ? math.max(
                    208,
                    math.max(
                      safe.bottom - anchor.bottom - 6,
                      anchor.top - safe.top - 6,
                    ),
                  )
                : safe.height,
          ),
          atPointer: atPointer,
          reduceMotion: reduceMotion,
        ),
        children: [
          ComposerObjectSurface(
            radius: 12,
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              role: SemanticsRole.menu,
              child: child,
            ),
          ),
        ],
      );
    },
  );
}

class _PanelReveal extends FlowDelegate {
  _PanelReveal({
    required this.animation,
    required this.anchor,
    required this.viewport,
    required this.width,
    required this.maxHeight,
    required this.atPointer,
    required this.reduceMotion,
  }) : super(repaint: animation);
  final Animation<double> animation;
  final Rect anchor;
  final Rect viewport;
  final double width;
  final double maxHeight;
  final bool atPointer;
  final bool reduceMotion;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: math.min(maxHeight, viewport.height),
      );

  @override
  void paintChildren(FlowPaintingContext context) {
    final size = context.getChildSize(0);
    if (size == null || size.isEmpty) return;
    final left =
        (anchor.left + size.width <= viewport.right
                ? anchor.left
                : anchor.right - size.width)
            .clamp(viewport.left, viewport.right - size.width);
    final below = anchor.bottom + 6;
    final above = anchor.top - 6 - size.height;
    final top =
        (atPointer
                ? anchor.top
                : below + size.height <= viewport.bottom
                ? below
                : above >= viewport.top
                ? above
                : below)
            .clamp(viewport.top, viewport.bottom - size.height);
    final target = Offset(left, top) & size;
    final t = reduceMotion
        ? 1.0
        : (animation.status == AnimationStatus.reverse
                  ? Curves.easeInOutCubic
                  : Curves.easeOutCubic)
              .transform(animation.value);
    // A point context menu starts small at the pointer. Button menus unfold
    // from the button's actual footprint rather than an estimated menu pivot.
    final source = anchor.isEmpty
        ? Rect.fromCenter(center: anchor.center, width: 8, height: 8)
        : anchor;
    final rect = Rect.lerp(source, target, t)!;
    context.paintChild(
      0,
      transform: Matrix4.identity()
        ..translateByDouble(rect.left, rect.top, 0, 1)
        ..scaleByDouble(
          rect.width / size.width,
          rect.height / size.height,
          1,
          1,
        ),
      opacity: reduceMotion ? 1 : lerpDouble(0, 1, (t * 2.5).clamp(0, 1))!,
    );
  }

  @override
  bool shouldRepaint(_PanelReveal old) =>
      old.anchor != anchor ||
      old.viewport != viewport ||
      old.width != width ||
      old.maxHeight != maxHeight ||
      old.atPointer != atPointer ||
      old.reduceMotion != reduceMotion ||
      old.animation != animation;
}
