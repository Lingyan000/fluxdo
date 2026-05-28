// ignore_for_file: unnecessary_null_comparison

part of '../gesture_page_view.dart';

class GesturePageView extends StatefulWidget {
  /// Creates a scrollable list that works page by page from an explicit [List]
  /// of widgets.
  ///
  /// This constructor is appropriate for page views with a small number of
  /// children because constructing the [List] requires doing work for every
  /// child that could possibly be displayed in the page view, instead of just
  /// those children that are actually visible.
  ///
  /// Like other widgets in the framework, this widget expects that
  /// the [children] list will not be mutated after it has been passed in here.
  /// See the documentation at [SliverChildListDelegate.children] for more details.
  ///
  /// {@template flutter.widgets.PageView.allowImplicitScrolling}
  /// The [allowImplicitScrolling] parameter must not be null. If true, the
  /// [GesturePageView] will participate in accessibility scrolling more like a
  /// [ListView], where implicit scroll actions will move to the next page
  /// rather than into the contents of the [GesturePageView].
  /// {@endtemplate}
  GesturePageView({
    super.key,
    this.scrollDirection = Axis.horizontal,
    this.reverse = false,
    ExtendedPageController? controller,
    this.physics,
    this.pageSnapping = true,
    this.onPageChanged,
    List<Widget> children = const <Widget>[],
    this.dragStartBehavior = DragStartBehavior.start,
    this.allowImplicitScrolling = false,
    this.restorationId,
    this.clipBehavior = Clip.hardEdge,
    this.scrollBehavior,
    this.padEnds = true,
    this.preloadPagesCount = 0,
  }) : assert(allowImplicitScrolling != null),
       assert(clipBehavior != null),
       controller = controller ?? _defaultPageController,
       childrenDelegate = SliverChildListDelegate(children);

  /// Creates a scrollable list that works page by page using widgets that are
  /// created on demand.
  ///
  /// This constructor is appropriate for page views with a large (or infinite)
  /// number of children because the builder is called only for those children
  /// that are actually visible.
  ///
  /// Providing a non-null [itemCount] lets the [GesturePageView] compute the maximum
  /// scroll extent.
  ///
  /// [itemBuilder] will be called only with indices greater than or equal to
  /// zero and less than [itemCount].
  ///
  /// [PageView.builder] by default does not support child reordering. If
  /// you are planning to change child order at a later time, consider using
  /// [GesturePageView] or [PageView.custom].
  ///
  /// {@macro flutter.widgets.PageView.allowImplicitScrolling}
  GesturePageView.builder({
    super.key,
    this.scrollDirection = Axis.horizontal,
    this.reverse = false,
    ExtendedPageController? controller,
    this.physics,
    this.pageSnapping = true,
    this.onPageChanged,
    required IndexedWidgetBuilder itemBuilder,
    int? itemCount,
    this.dragStartBehavior = DragStartBehavior.start,
    this.allowImplicitScrolling = false,
    this.restorationId,
    this.clipBehavior = Clip.hardEdge,
    this.scrollBehavior,
    this.padEnds = true,
    this.preloadPagesCount = 0,
  }) : assert(allowImplicitScrolling != null),
       assert(clipBehavior != null),
       controller = controller ?? _defaultPageController,
       childrenDelegate = SliverChildBuilderDelegate(
         itemBuilder,
         childCount: itemCount,
       );

  /// Creates a scrollable list that works page by page with a custom child
  /// model.
  ///
  /// {@tool snippet}
  ///
  /// This [GesturePageView] uses a custom [SliverChildBuilderDelegate] to support child
  /// reordering.
  ///
  /// ```dart
  /// class MyPageView extends StatefulWidget {
  ///   const MyPageView({Key? key}) : super(key: key);
  ///
  ///   @override
  ///   State<MyPageView> createState() => _MyPageViewState();
  /// }
  ///
  /// class _MyPageViewState extends State<MyPageView> {
  ///   List<String> items = <String>['1', '2', '3', '4', '5'];
  ///
  ///   void _reverse() {
  ///     setState(() {
  ///       items = items.reversed.toList();
  ///     });
  ///   }
  ///
  ///   @override
  ///   Widget build(BuildContext context) {
  ///     return Scaffold(
  ///       body: SafeArea(
  ///         child: PageView.custom(
  ///           childrenDelegate: SliverChildBuilderDelegate(
  ///             (BuildContext context, int index) {
  ///               return KeepAlive(
  ///                 data: items[index],
  ///                 key: ValueKey<String>(items[index]),
  ///               );
  ///             },
  ///             childCount: items.length,
  ///             findChildIndexCallback: (Key key) {
  ///               final ValueKey<String> valueKey = key as ValueKey<String>;
  ///               final String data = valueKey.value;
  ///               return items.indexOf(data);
  ///             }
  ///           ),
  ///         ),
  ///       ),
  ///       bottomNavigationBar: BottomAppBar(
  ///         child: Row(
  ///           mainAxisAlignment: MainAxisAlignment.center,
  ///           children: <Widget>[
  ///             TextButton(
  ///               onPressed: () => _reverse(),
  ///               child: const Text('Reverse items'),
  ///             ),
  ///           ],
  ///         ),
  ///       ),
  ///     );
  ///   }
  /// }
  ///
  /// class KeepAlive extends StatefulWidget {
  ///   const KeepAlive({Key? key, required this.data}) : super(key: key);
  ///
  ///   final String data;
  ///
  ///   @override
  ///   State<KeepAlive> createState() => _KeepAliveState();
  /// }
  ///
  /// class _KeepAliveState extends State<KeepAlive> with AutomaticKeepAliveClientMixin{
  ///   @override
  ///   bool get wantKeepAlive => true;
  ///
  ///   @override
  ///   Widget build(BuildContext context) {
  ///     super.build(context);
  ///     return Text(widget.data);
  ///   }
  /// }
  /// ```
  /// {@end-tool}
  ///
  /// {@macro flutter.widgets.PageView.allowImplicitScrolling}
  GesturePageView.custom({
    super.key,
    this.scrollDirection = Axis.horizontal,
    this.reverse = false,
    ExtendedPageController? controller,
    this.physics,
    this.pageSnapping = true,
    this.onPageChanged,
    required this.childrenDelegate,
    this.dragStartBehavior = DragStartBehavior.start,
    this.allowImplicitScrolling = false,
    this.restorationId,
    this.clipBehavior = Clip.hardEdge,
    this.scrollBehavior,
    this.padEnds = true,
    this.preloadPagesCount = 0,
  }) : assert(childrenDelegate != null),
       assert(allowImplicitScrolling != null),
       assert(clipBehavior != null),
       controller = controller ?? _defaultPageController;

  /// Controls whether the widget's pages will respond to
  /// [RenderObject.showOnScreen], which will allow for implicit accessibility
  /// scrolling.
  ///
  /// With this flag set to false, when accessibility focus reaches the end of
  /// the current page and the user attempts to move it to the next element, the
  /// focus will traverse to the next widget outside of the page view.
  ///
  /// With this flag set to true, when accessibility focus reaches the end of
  /// the current page and user attempts to move it to the next element, focus
  /// will traverse to the next page in the page view.
  final bool allowImplicitScrolling;

  /// {@macro flutter.widgets.scrollable.restorationId}
  final String? restorationId;

  /// The axis along which the page view scrolls.
  ///
  /// Defaults to [Axis.horizontal].
  final Axis scrollDirection;

  /// Whether the page view scrolls in the reading direction.
  ///
  /// For example, if the reading direction is left-to-right and
  /// [scrollDirection] is [Axis.horizontal], then the page view scrolls from
  /// left to right when [reverse] is false and from right to left when
  /// [reverse] is true.
  ///
  /// Similarly, if [scrollDirection] is [Axis.vertical], then the page view
  /// scrolls from top to bottom when [reverse] is false and from bottom to top
  /// when [reverse] is true.
  ///
  /// Defaults to false.
  final bool reverse;

  /// An object that can be used to control the position to which this page
  /// view is scrolled.
  final ExtendedPageController controller;

  /// How the page view should respond to user input.
  ///
  /// For example, determines how the page view continues to animate after the
  /// user stops dragging the page view.
  ///
  /// The physics are modified to snap to page boundaries using
  /// [PageScrollPhysics] prior to being used.
  ///
  /// If an explicit [ScrollBehavior] is provided to [scrollBehavior], the
  /// [ScrollPhysics] provided by that behavior will take precedence after
  /// [physics].
  ///
  /// Defaults to matching platform conventions.
  final ScrollPhysics? physics;

  /// Set to false to disable page snapping, useful for custom scroll behavior.
  ///
  /// If the [padEnds] is false and [PageController.viewportFraction] < 1.0,
  /// the page will snap to the beginning of the viewport; otherwise, the page
  /// will snap to the center of the viewport.
  final bool pageSnapping;

  /// Called whenever the page in the center of the viewport changes.
  final ValueChanged<int>? onPageChanged;

  /// A delegate that provides the children for the [GesturePageView].
  ///
  /// The [PageView.custom] constructor lets you specify this delegate
  /// explicitly. The [GesturePageView] and [PageView.builder] constructors create a
  /// [childrenDelegate] that wraps the given [List] and [IndexedWidgetBuilder],
  /// respectively.
  final SliverChildDelegate childrenDelegate;

  /// {@macro flutter.widgets.scrollable.dragStartBehavior}
  final DragStartBehavior dragStartBehavior;

  /// {@macro flutter.material.Material.clipBehavior}
  ///
  /// Defaults to [Clip.hardEdge].
  final Clip clipBehavior;

  /// {@macro flutter.widgets.shadow.scrollBehavior}
  ///
  /// [ScrollBehavior]s also provide [ScrollPhysics]. If an explicit
  /// [ScrollPhysics] is provided in [physics], it will take precedence,
  /// followed by [scrollBehavior], and then the inherited ancestor
  /// [ScrollBehavior].
  ///
  /// The [ScrollBehavior] of the inherited [ScrollConfiguration] will be
  /// modified by default to not apply a [Scrollbar].
  final ScrollBehavior? scrollBehavior;

  /// Whether to add padding to both ends of the list.
  ///
  /// If this is set to true and [PageController.viewportFraction] < 1.0, padding will be added
  /// such that the first and last child slivers will be in the center of
  /// the viewport when scrolled all the way to the start or end, respectively.
  ///
  /// If [PageController.viewportFraction] >= 1.0, this property has no effect.
  ///
  /// This property defaults to true and must not be null.
  final bool padEnds;

  /// The count of pre-built pages
  final int preloadPagesCount;

  @override
  State<GesturePageView> createState() => _GesturePageViewState();
}

class _GesturePageViewState extends State<GesturePageView> {
  int _lastReportedPage = 0;

  @override
  void initState() {
    super.initState();
    _lastReportedPage = widget.controller.initialPage;
  }

  AxisDirection _getDirection(BuildContext context) {
    switch (widget.scrollDirection) {
      case Axis.horizontal:
        assert(debugCheckHasDirectionality(context));
        final TextDirection textDirection = Directionality.of(context);
        final AxisDirection axisDirection = textDirectionToAxisDirection(
          textDirection,
        );
        return widget.reverse
            ? flipAxisDirection(axisDirection)
            : axisDirection;
      case Axis.vertical:
        return widget.reverse ? AxisDirection.up : AxisDirection.down;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AxisDirection axisDirection = _getDirection(context);
    final ScrollPhysics physics = _ForceImplicitScrollPhysics(
      allowImplicitScrolling: widget.allowImplicitScrolling,
    ).applyTo(
      widget.pageSnapping
          ? _kPagePhysics.applyTo(
            widget.physics ?? widget.scrollBehavior?.getScrollPhysics(context),
          )
          : widget.physics ?? widget.scrollBehavior?.getScrollPhysics(context),
    );

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification.depth == 0 &&
            widget.onPageChanged != null &&
            notification is ScrollUpdateNotification) {
          final PageMetrics metrics = notification.metrics as PageMetrics;
          final int currentPage = metrics.page!.round();
          if (currentPage != _lastReportedPage) {
            _lastReportedPage = currentPage;
            widget.onPageChanged!(currentPage);
          }
        }
        return false;
      },
      child: _Scrollable(
        dragStartBehavior: widget.dragStartBehavior,
        axisDirection: axisDirection,
        controller: widget.controller,
        physics: physics,
        shouldIgnorePointerWhenScrolling:
            widget.controller.shouldIgnorePointerWhenScrolling,
        restorationId: widget.restorationId,
        scrollBehavior:
            widget.scrollBehavior ??
            ScrollConfiguration.of(context).copyWith(scrollbars: false),
        viewportBuilder: (BuildContext context, ViewportOffset position) {
          final double cacheExtent;
          if (widget.preloadPagesCount > 0) {
            cacheExtent = widget.preloadPagesCount.toDouble();
          } else if (widget.allowImplicitScrolling) {
            cacheExtent = 1.0;
          } else {
            cacheExtent = 0.0;
          }
          return Viewport(
            // TODO(dnfield): we should provide a way to set cacheExtent
            // independent of implicit scrolling:
            // https://github.com/flutter/flutter/issues/45632
            scrollCacheExtent: ScrollCacheExtent.viewport(cacheExtent),
            axisDirection: axisDirection,
            offset: position,
            clipBehavior: widget.clipBehavior,
            slivers: <Widget>[
              ExtendedSliverFillViewport(
                viewportFraction: widget.controller.viewportFraction,
                delegate: widget.childrenDelegate,
                padEnds: widget.padEnds,
                pageSpacing: widget.controller.pageSpacing,
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder description) {
    super.debugFillProperties(description);
    description.add(
      EnumProperty<Axis>('scrollDirection', widget.scrollDirection),
    );
    description.add(
      FlagProperty('reverse', value: widget.reverse, ifTrue: 'reversed'),
    );
    description.add(
      DiagnosticsProperty<ExtendedPageController>(
        'controller',
        widget.controller,
        showName: false,
      ),
    );
    description.add(
      DiagnosticsProperty<ScrollPhysics>(
        'physics',
        widget.physics,
        showName: false,
      ),
    );
    description.add(
      FlagProperty(
        'pageSnapping',
        value: widget.pageSnapping,
        ifFalse: 'snapping disabled',
      ),
    );
    description.add(
      FlagProperty(
        'allowImplicitScrolling',
        value: widget.allowImplicitScrolling,
        ifTrue: 'allow implicit scrolling',
      ),
    );
  }
}

class _ForceImplicitScrollPhysics extends ScrollPhysics {
  const _ForceImplicitScrollPhysics({
    required this.allowImplicitScrolling,
    super.parent,
  }) : assert(allowImplicitScrolling != null);

  @override
  _ForceImplicitScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _ForceImplicitScrollPhysics(
      allowImplicitScrolling: allowImplicitScrolling,
      parent: buildParent(ancestor),
    );
  }

  @override
  final bool allowImplicitScrolling;
}

class _Scrollable extends Scrollable {
  const _Scrollable({
    super.axisDirection,
    super.controller,
    super.physics,
    required super.viewportBuilder,
    super.dragStartBehavior,
    super.restorationId,
    super.scrollBehavior,
    this.shouldIgnorePointerWhenScrolling = true,
  });
  final bool shouldIgnorePointerWhenScrolling;
  @override
  _ExtendedScrollableState createState() => _ExtendedScrollableState();
}

class _ExtendedScrollableState extends ScrollableState {
  @override
  void setIgnorePointer(bool value) {
    final _Scrollable scrollable = widget as _Scrollable;
    if (scrollable.shouldIgnorePointerWhenScrolling) {
      super.setIgnorePointer(value);
    }
  }
}
