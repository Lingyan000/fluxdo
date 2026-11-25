part of 'metaverse_widget_library.dart';

/// 最新条目在前的时间线，适用于消息、日志与持续追加的记录。
/// 设计依据: docs/plugins/components.md 的时间线约定。
class _PluginTimelinePage extends StatefulWidget {
  const _PluginTimelinePage({
    required this.identity,
    required this.items,
    required this.itemKeys,
    required this.loading,
    required this.loadingMore,
    required this.hasMore,
    required this.error,
    required this.endRevision,
    this.header,
    this.footer,
    this.loadingPlaceholder,
    this.emptyTitle,
    this.moreLabel,
    this.onLoadMore,
    this.onRetry,
  });
  final String identity;
  final List<Widget> items;
  final List<String> itemKeys;
  final bool loading, loadingMore, hasMore;
  final String error;
  final int endRevision;
  final Widget? header, footer, loadingPlaceholder;
  final String? emptyTitle, moreLabel;
  final VoidCallback? onLoadMore, onRetry;

  @override
  State<_PluginTimelinePage> createState() => _PluginTimelinePageState();
}

class _PluginTimelinePageState extends State<_PluginTimelinePage> {
  final _scroll = ScrollController(
    keepScrollOffset: false,
    initialScrollOffset: -16,
  );
  static const _center = ValueKey('timeline-origin');
  String? _origin;
  bool _away = false;
  bool _requested = false;
  int _generation = 0;
  double _bottomPadding = 16;

  @override
  void initState() {
    super.initState();
    _origin = widget.itemKeys.firstOrNull;
    _scroll.addListener(_onPosition);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final padding =
        16 +
        (widget.footer == null ? MediaQuery.paddingOf(context).bottom : 0.0);
    if (_bottomPadding == padding) return;
    _bottomPadding = padding;
    if (!_scroll.hasClients || _scroll.position.extentBefore <= 80) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(-_bottomPadding);
      });
    }
  }

  void _onPosition() {
    if (!_scroll.hasClients) return;
    final away = _scroll.position.extentBefore > 80;
    if (_away != away) setState(() => _away = away);
  }

  bool _onScroll(ScrollNotification event) {
    // 仅用户向历史方向滑动才请求；布局更新不能自动连翻历史。
    final delta = switch (event) {
      ScrollUpdateNotification() => event.scrollDelta ?? 0,
      OverscrollNotification() => event.overscroll,
      _ => 0.0,
    };
    if (event.depth == 0 && delta > 0 && event.metrics.extentAfter < 160) {
      _loadMore();
    }
    return false;
  }

  void _loadMore() {
    if (_requested ||
        widget.loading ||
        widget.loadingMore ||
        !widget.hasMore ||
        widget.error.isNotEmpty ||
        widget.onLoadMore == null) {
      return;
    }
    _requested = true;
    widget.onLoadMore!();
  }

  Future<void> _latest({bool animate = true}) async {
    if (!_scroll.hasClients) return;
    if (animate && !MediaQuery.disableAnimationsOf(context)) {
      await _scroll.animateTo(
        _scroll.position.minScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    setState(() {
      _origin = widget.itemKeys.firstOrNull;
      _away = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(-_bottomPadding);
    });
  }

  @override
  void didUpdateWidget(_PluginTimelinePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged = oldWidget.identity != widget.identity;
    _bottomPadding =
        16 +
        (widget.footer == null ? MediaQuery.paddingOf(context).bottom : 0.0);
    if (identityChanged || widget.items.isEmpty) _away = false;
    final keysChanged =
        oldWidget.itemKeys.length != widget.itemKeys.length ||
        Iterable<int>.generate(widget.itemKeys.length)
            .any((i) => oldWidget.itemKeys[i] != widget.itemKeys[i]);
    if (identityChanged ||
        keysChanged ||
        oldWidget.loadingMore && !widget.loadingMore ||
        widget.error.isNotEmpty) {
      _requested = false;
    }
    if (!identityChanged &&
        !keysChanged &&
        oldWidget.endRevision == widget.endRevision) {
      return;
    }
    final generation = ++_generation;
    final atEnd = !_scroll.hasClients || _scroll.position.extentBefore <= 80;
    final follow =
        identityChanged || atEnd || oldWidget.endRevision != widget.endRevision;
    // 新内容在中心之前生长，历史在中心之后追加。保持中心不变即可保留
    // 布局坐标，不依赖新增数量、行高或离屏条目是否还在懒加载缓存中。
    final reset = follow || !widget.itemKeys.contains(_origin);
    if (!reset) return;
    _origin = widget.itemKeys.firstOrNull;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      _scroll.jumpTo(-_bottomPadding);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final validKeys =
        widget.itemKeys.length == widget.items.length &&
        widget.itemKeys.toSet().length == widget.items.length;
    final items = validKeys ? widget.items : const <Widget>[];
    final originIndex = items.isEmpty
        ? 0
        : math.max(0, widget.itemKeys.indexOf(_origin ?? ''));
    return _PluginPageLayout(
      loading: widget.loading,
      toolbar: items.isNotEmpty && widget.error.isNotEmpty
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?widget.header,
                Semantics(
                  liveRegion: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.error,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ),
                      if (widget.onRetry != null)
                        TextButton(
                          onPressed: widget.onRetry,
                          child: Text(context.l10n.common_retry),
                        ),
                    ],
                  ),
                ),
              ],
            )
          : widget.header,
      footer: widget.footer,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: items.isEmpty && !widget.loading
                    ? SingleChildScrollView(
                        primary: false,
                        padding: const EdgeInsets.all(16),
                        child: _PluginPageStatus(
                          error: widget.error,
                          emptyTitle: widget.emptyTitle,
                          onRetry: widget.onRetry,
                        ),
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: CustomScrollView(
                          controller: _scroll,
                          reverse: true,
                          center: _center,
                          physics: const AlwaysScrollableScrollPhysics(),
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          slivers: [
                            SliverToBoxAdapter(
                              child: SizedBox(height: _bottomPadding),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (_, index) => KeyedSubtree(
                                    key: ValueKey(
                                      widget.itemKeys[originIndex - 1 - index],
                                    ),
                                    child: items[originIndex - 1 - index],
                                  ),
                                  childCount: originIndex,
                                  findChildIndexCallback: (key) {
                                    if (key is! ValueKey<String>) return null;
                                    final index = widget.itemKeys.indexOf(
                                      key.value,
                                    );
                                    return index >= 0 && index < originIndex
                                        ? originIndex - 1 - index
                                        : null;
                                  },
                                ),
                              ),
                            ),
                            SliverPadding(
                              key: _center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (_, index) {
                                    final row = originIndex + index;
                                    if (row < items.length) {
                                      return KeyedSubtree(
                                        key: ValueKey(widget.itemKeys[row]),
                                        child: items[row],
                                      );
                                    }
                                    if (items.isEmpty) {
                                      return widget.loadingPlaceholder ??
                                          const Center(child: LoadingSpinner());
                                    }
                                    if (widget.loadingMore) {
                                      return const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Center(
                                          child: LoadingSpinner(size: 24),
                                        ),
                                      );
                                    }
                                    if (!widget.hasMore ||
                                        widget.onLoadMore == null) {
                                      return const SizedBox.shrink();
                                    }
                                    return Center(
                                      child: TextButton(
                                        onPressed:
                                            widget.loading ||
                                                widget.error.isNotEmpty
                                            ? null
                                            : _loadMore,
                                        child: Text(
                                          widget.moreLabel ??
                                              context.l10n.common_more,
                                        ),
                                      ),
                                    );
                                  },
                                  childCount: items.length - originIndex + 1,
                                  findChildIndexCallback: (key) {
                                    if (key is! ValueKey<String>) return null;
                                    final index = widget.itemKeys.indexOf(
                                      key.value,
                                    );
                                    return index >= originIndex
                                        ? index - originIndex
                                        : null;
                                  },
                                ),
                              ),
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 16),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
          if (_away)
            PositionedDirectional(
              end: 16,
              bottom: 12,
              child: FilledButton.tonalIcon(
                onPressed: _latest,
                icon: const Icon(Symbols.arrow_downward_rounded, size: 18),
                label: Text(context.l10n.metaverse_timelineLatest),
              ),
            ),
        ],
      ),
      children: const [],
    );
  }
}
